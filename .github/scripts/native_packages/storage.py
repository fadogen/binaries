"""Publish service catalogues before removing their unreferenced package archives."""

import base64
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .common import file_digest, read_json, write_json
from .planning import merge_results, prune_metadata

SERVICE_ARCHIVE = re.compile(
    r"(?:mariadb|mysql|postgresql|redis|valkey)-[0-9]+(?:\.[0-9]+)+"
    r"(?:-(?:[a-f0-9]{16}|[a-f0-9]{64}))?"
    r"-(?:(?:darwin|linux)-(?:arm64|x86_64)\.tar\.gz|windows-(?:arm64|x86_64)\.zip)"
)
SERVICE_CATALOGUE = re.compile(r"metadata-services-(?:darwin|linux|windows)-(?:arm64|x86_64)\.json")


def archive_references(metadata):
    references = set()
    for target, catalogue in metadata.items():
        for service, versions in catalogue.items():
            for major, version in versions.items():
                if (
                    not isinstance(version, dict)
                    or not isinstance(version.get("filename"), str)
                    or not version["filename"]
                ):
                    raise ValueError(f"Invalid archive reference: {target}/{service}/{major}")
                references.add(version["filename"])
    return references


class Store:
    def __init__(self, bucket, endpoint):
        if not bucket or not endpoint:
            raise ValueError("R2_BUCKET_NAME and R2_ENDPOINT are required")
        self.bucket, self.endpoint = bucket, endpoint

    def invoke(self, arguments):
        return subprocess.run(
            ["aws", *arguments, "--endpoint-url", self.endpoint], capture_output=True, text=True
        )

    def fetch_metadata(self, targets, directory, *, require_existing=False):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        for target in targets:
            filename = f"metadata-services-{target}.json"
            destination = directory / filename
            with tempfile.TemporaryDirectory(dir=directory) as temporary:
                downloaded = Path(temporary) / filename
                result = self.invoke(
                    ["s3api", "get-object", "--bucket", self.bucket, "--key", filename, str(downloaded)]
                )
                if result.returncode:
                    if require_existing or (
                        "(NoSuchKey)" not in result.stderr and "(404)" not in result.stderr
                    ):
                        raise RuntimeError(f"Cannot read {filename}: {result.stderr.strip()}")
                    write_json(downloaded, {})
                metadata = read_json(downloaded)
                if not isinstance(metadata, dict):
                    raise ValueError(f"Invalid metadata object: {filename}")
                downloaded.replace(destination)
            original = destination.with_suffix(".json.orig")
            if result.returncode:
                original.unlink(missing_ok=True)
            else:
                shutil.copyfile(destination, original)

    def publish_archive(self, package, receipt, archive):
        merge_results({}, [receipt], [package])
        if file_digest(archive) != receipt["sha256"]:
            raise ValueError("Archive changed after verification")
        checksum = base64.b64encode(bytes.fromhex(receipt["sha256"])).decode()
        result = self.invoke(
            [
                "s3api",
                "put-object",
                "--bucket",
                self.bucket,
                "--key",
                receipt["filename"],
                "--body",
                str(archive),
                "--checksum-algorithm",
                "SHA256",
                "--checksum-sha256",
                checksum,
            ]
        )
        if result.returncode:
            raise RuntimeError(f"Archive upload failed: {result.stderr.strip()}")

    def publish_metadata(self, directory):
        for path in sorted(Path(directory).glob("metadata-services-*.json")):
            original = path.with_suffix(".json.orig")
            if original.exists() and read_json(original) == read_json(path):
                continue
            result = self.invoke(
                [
                    "s3api",
                    "put-object",
                    "--bucket",
                    self.bucket,
                    "--key",
                    path.name,
                    "--body",
                    str(path),
                    "--content-type",
                    "application/json",
                    "--cache-control",
                    "no-cache",
                ]
            )
            if result.returncode:
                raise RuntimeError(f"Metadata upload failed: {result.stderr.strip()}")

    def reconcile_metadata(self, config, packages, results):
        """Reconcile the complete remote catalogue, then delete only unreferenced service objects."""
        targets = [f"{target['os']}-{target['arch']}" for target in config["targets"]]
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fetch_metadata(targets, directory)
            before = {target: read_json(directory / f"metadata-services-{target}.json") for target in targets}
            after = prune_metadata(merge_results(before, results, packages), config)
            references = archive_references(after)
            for target, metadata in after.items():
                write_json(directory / f"metadata-services-{target}.json", metadata)
            self.publish_metadata(directory)

            keys = self.list_keys()
            self.fetch_metadata(targets, directory, require_existing=True)
            observed = {
                target: read_json(directory / f"metadata-services-{target}.json") for target in targets
            }
            if observed != after:
                raise RuntimeError("Remote service catalogues changed after publication; cleanup refused")
            current_catalogues = {f"metadata-services-{target}.json" for target in targets}
            if not current_catalogues.issubset(keys):
                raise RuntimeError("Current service catalogues are missing from the object listing")
            if not references.issubset(keys):
                raise RuntimeError("Published service catalogues reference missing archives; cleanup refused")

            retired_catalogues = sorted(
                key for key in keys - current_catalogues if SERVICE_CATALOGUE.fullmatch(key)
            )
            obsolete_archives = sorted(key for key in keys - references if SERVICE_ARCHIVE.fullmatch(key))
            # Remove retired references first. A partial catalogue deletion must
            # fail before any archive can be removed.
            self.delete_keys(retired_catalogues)
            self.delete_keys(obsolete_archives)
        return {
            "catalogues": len(targets),
            "deleted_catalogues": len(retired_catalogues),
            "deleted_archives": len(obsolete_archives),
        }

    def list_keys(self):
        keys, tokens = set(), set()
        token = None
        while True:
            arguments = [
                "s3api",
                "list-objects-v2",
                "--bucket",
                self.bucket,
                "--no-paginate",
                "--output",
                "json",
            ]
            if token:
                arguments.extend(["--continuation-token", token])
            result = self.invoke(arguments)
            if result.returncode:
                raise RuntimeError(f"Object listing failed: {result.stderr.strip()}")
            response = json.loads(result.stdout)
            if not isinstance(response, dict) or not isinstance(response.get("IsTruncated"), bool):
                raise ValueError("Invalid object listing response")
            contents = response.get("Contents", [])
            if not isinstance(contents, list):
                raise ValueError("Invalid object listing contents")
            for item in contents:
                if not isinstance(item, dict) or not isinstance(item.get("Key"), str):
                    raise ValueError("Invalid object key in listing")
                keys.add(item["Key"])
            if not response["IsTruncated"]:
                return keys
            token = response.get("NextContinuationToken")
            if not isinstance(token, str) or not token or token in tokens:
                raise ValueError("Missing or repeated object listing continuation token")
            tokens.add(token)

    def delete_keys(self, keys):
        for offset in range(0, len(keys), 1000):
            with tempfile.TemporaryDirectory() as temporary:
                request = Path(temporary) / "delete.json"
                write_json(
                    request,
                    {"Objects": [{"Key": key} for key in keys[offset : offset + 1000]]},
                )
                result = self.invoke(
                    [
                        "s3api",
                        "delete-objects",
                        "--bucket",
                        self.bucket,
                        "--delete",
                        f"file://{request}",
                        "--output",
                        "json",
                    ]
                )
            if result.returncode:
                raise RuntimeError(f"Object deletion failed: {result.stderr.strip()}")
            response = json.loads(result.stdout)
            if not isinstance(response, dict):
                raise ValueError("Invalid object deletion response")
            if response.get("Errors"):
                raise RuntimeError(f"Object deletion failed: {json.dumps(response['Errors'])}")
