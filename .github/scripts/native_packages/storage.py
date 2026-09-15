"""Publish successful content-addressed artifacts and merge metadata separately."""

import base64
import shutil
import subprocess
import tempfile
from pathlib import Path

from .common import file_digest, read_json, write_json
from .planning import merge_results


class Store:
    def __init__(self, bucket, endpoint):
        if not bucket or not endpoint:
            raise ValueError("R2_BUCKET_NAME and R2_ENDPOINT are required")
        self.bucket, self.endpoint = bucket, endpoint

    def invoke(self, arguments):
        return subprocess.run(
            ["aws", *arguments, "--endpoint-url", self.endpoint], capture_output=True, text=True
        )

    def fetch_metadata(self, targets, directory):
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
                    if "(NoSuchKey)" not in result.stderr and "(404)" not in result.stderr:
                        raise RuntimeError(f"Cannot read {filename}: {result.stderr.strip()}")
                    write_json(downloaded, {})
                metadata = read_json(downloaded)
                if not isinstance(metadata, dict):
                    raise ValueError(f"Invalid metadata object: {filename}")
                downloaded.replace(destination)
            shutil.copyfile(destination, destination.with_suffix(".json.orig"))

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
                ]
            )
            if result.returncode:
                raise RuntimeError(f"Metadata upload failed: {result.stderr.strip()}")
