#!/usr/bin/env python3
"""Plan, package and publish service metadata without compiling engines."""

import argparse
import json
import os
import sys
from pathlib import Path

from native_packages.build import build, packager_digest
from native_packages.common import digest, file_digest, read_json, write_json
from native_packages.homebrew import FormulaAPI, Unavailable
from native_packages.planning import (
    fingerprint,
    identity,
    make_matrix,
    merge_results,
    prune_metadata,
    validate_receipt,
)
from native_packages.smoke import verify
from native_packages.storage import Store
from native_packages.vendor import build_windows, verify_windows

CONFIG = Path(__file__).resolve().parent.parent / "config/services.json"


def load_metadata(folder):
    return {
        path.stem.removeprefix("metadata-services-"): read_json(path)
        for path in Path(folder).glob("metadata-services-*.json")
    }


def plan(args):
    config = read_json(CONFIG)
    documents = None
    if args.api_directory:
        documents = {path.stem: read_json(path) for path in Path(args.api_directory).glob("*.json")}
    api = FormulaAPI(documents=documents)
    packages, unavailable = [], []
    for service, majors in config["services"].items():
        if args.services and service not in args.services:
            continue
        for major in majors:
            if args.majors and major not in args.majors:
                continue
            try:
                formula = api.resolve(service, major)
            except Unavailable as error:
                unavailable.append({"service": service, "major": major, "reason": str(error)})
                continue
            for target in config["targets"]:
                if args.native_only and target["engine"] != "homebrew":
                    continue
                if args.os and target["os"] != args.os:
                    continue
                if args.arch and target["arch"] != args.arch:
                    continue
                if service in target.get("exclude", []):
                    continue
                package = {key: target[key] for key in ["os", "arch", "runner", "engine"]}
                package.update(
                    service=service,
                    major=major,
                    version=formula["versions"]["stable"],
                    formula=formula["name"],
                )
                try:
                    package["components"] = (
                        api.closure(formula["name"], target["tags"]) if target["engine"] == "homebrew" else []
                    )
                except Unavailable as error:
                    unavailable.append({"id": identity(package), "reason": str(error)})
                    continue
                package["packager"] = (
                    packager_digest()
                    if target["engine"] == "homebrew"
                    else digest(
                        {
                            str(path.name): file_digest(path)
                            for path in [
                                CONFIG.parent.parent / "scripts/services-windows-downloader.sh",
                                CONFIG.parent.parent / "scripts/native_packages/vendor.py",
                            ]
                        }
                    )
                )
                package["deps"] = fingerprint(package)
                package["id"] = identity(package)
                suffix = "tar.gz" if target["engine"] == "homebrew" else "zip"
                revision = f"-{package['deps'][:16]}" if package["deps"] else ""
                package["filename"] = (
                    f"{service}-{package['version']}{revision}-{target['os']}-{target['arch']}.{suffix}"
                )
                packages.append(package)
    selected = make_matrix(packages, load_metadata(args.metadata), force=args.force)
    document = {
        "schema": 1,
        "packages": packages,
        "unavailable": unavailable,
        "selected": [row["id"] for row in selected],
    }
    write_json(args.output, document)
    matrix = [
        {key: row[key] for key in ["id", "service", "version", "os", "arch", "runner", "engine"]}
        for row in selected
    ]
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write("matrix=" + json.dumps({"include": matrix}, separators=(",", ":")) + "\n")
            output.write("should-build=" + str(bool(matrix)).lower() + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
            summary.write(
                f"Planned: {len(packages)}. Selected: {len(selected)}. Unavailable: {len(unavailable)}.\n"
            )
            for entry in unavailable:
                summary.write(f"- Unavailable: {entry}\n")
    print(
        json.dumps(
            {"planned": len(packages), "selected": len(selected), "unavailable": unavailable}, indent=2
        )
    )


def selected_package(args):
    packages = read_json(args.plan)["packages"]
    matching = [package for package in packages if package["id"] == args.id]
    if len(matching) != 1:
        raise ValueError(f"Package not found in plan: {args.id}")
    return matching[0]


def package_command(args):
    package = selected_package(args)
    if package["engine"] == "homebrew":
        result = build(
            package, args.output, args.cache, signing_identity=args.signing_identity, keychain=args.keychain
        )
    else:
        result = build_windows(package, args.output)
    write_json(Path(args.output) / (args.id + ".json"), result)
    print(json.dumps({key: result[key] for key in ["id", "filename", "sha256", "bytes"]}, indent=2))


def verify_command(args):
    package = selected_package(args)
    receipt_path = Path(args.output) / (args.id + ".json")
    receipt = read_json(receipt_path)
    validate_receipt(package, receipt, verified=False)
    archive = Path(args.output) / receipt["filename"]
    if file_digest(archive) != receipt["sha256"]:
        raise ValueError("Archive changed before verification")
    if package["engine"] == "homebrew":
        report = verify(receipt, archive, Path(args.output) / (args.id + "-evidence"))
    else:
        report = verify_windows(package, archive)
        write_json(Path(args.output) / (args.id + "-evidence") / "result.json", report)
    receipt["verified_sha256"] = report["archive_sha256"]
    receipt["qualification"] = report
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write("archive=" + str(archive) + "\n")
    write_json(receipt_path, receipt)
    print(json.dumps(report, indent=2))


def update_metadata(args):
    """Write a local preview; publication always reads a fresh remote catalogue."""
    before = load_metadata(args.metadata)
    after = prune_metadata(
        merge_results(before, read_receipts(args.receipts), read_json(args.plan)["packages"]),
        read_json(CONFIG),
    )
    for target in before.keys() - after.keys():
        (Path(args.metadata) / f"metadata-services-{target}.json").unlink()
    for target, metadata in after.items():
        if metadata != before.get(target):
            write_json(Path(args.metadata) / f"metadata-services-{target}.json", metadata)


def read_receipts(directory):
    directory = Path(directory)
    if not directory.is_dir():
        raise ValueError(f"Receipt directory does not exist: {directory}")
    return [read_json(path) for path in sorted(directory.glob("*.json"))]


def publish_metadata(args):
    report = store().reconcile_metadata(
        read_json(CONFIG), read_json(args.plan)["packages"], read_receipts(args.receipts)
    )
    print(json.dumps(report, indent=2))


def store():
    return Store(os.environ.get("R2_BUCKET_NAME"), os.environ.get("R2_ENDPOINT"))


def fetch_metadata(args):
    targets = [f"{target['os']}-{target['arch']}" for target in read_json(CONFIG)["targets"]]
    store().fetch_metadata(targets, args.metadata)


def publish_archive(args):
    package = selected_package(args)
    receipt = read_json(Path(args.output) / (args.id + ".json"))
    store().publish_archive(package, receipt, Path(args.output) / receipt["filename"])


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan")
    planning.add_argument("--output", default="package-plan.json")
    planning.add_argument("--metadata", default=".")
    planning.add_argument("--api-directory")
    planning.add_argument("--native-only", action="store_true")
    planning.add_argument("--services", nargs="*")
    planning.add_argument("--majors", nargs="*")
    planning.add_argument("--os", choices=["darwin", "linux", "windows"])
    planning.add_argument("--arch", choices=["arm64", "x86_64"])
    planning.add_argument("--force", nargs="*", default=[])
    planning.set_defaults(handler=plan)
    packaging = commands.add_parser("build")
    packaging.add_argument("--plan", required=True)
    packaging.add_argument("--id", required=True)
    packaging.add_argument("--output", default="dist")
    packaging.add_argument("--cache", default=".cache/bottles")
    packaging.add_argument("--signing-identity", default="-")
    packaging.add_argument("--keychain")
    packaging.set_defaults(handler=package_command)
    verification = commands.add_parser("verify")
    verification.add_argument("--plan", required=True)
    verification.add_argument("--id", required=True)
    verification.add_argument("--output", default="dist")
    verification.set_defaults(handler=verify_command)
    metadata = commands.add_parser(
        "update-metadata",
        help="Preview the reconciled catalogue locally without publishing or deleting remote objects",
    )
    metadata.add_argument("--plan", required=True)
    metadata.add_argument("--receipts", required=True)
    metadata.add_argument("--metadata", default=".")
    metadata.set_defaults(handler=update_metadata)
    fetch = commands.add_parser("fetch-metadata")
    fetch.add_argument("--metadata", default="metadata")
    fetch.set_defaults(handler=fetch_metadata)
    upload = commands.add_parser("publish-archive")
    upload.add_argument("--plan", required=True)
    upload.add_argument("--id", required=True)
    upload.add_argument("--output", default="dist")
    upload.set_defaults(handler=publish_archive)
    publish = commands.add_parser("publish-metadata")
    publish.add_argument("--plan", required=True)
    publish.add_argument("--receipts", required=True)
    publish.set_defaults(handler=publish_metadata)
    return result


if __name__ == "__main__":
    arguments = parser().parse_args()
    try:
        arguments.handler(arguments)
    except (ValueError, RuntimeError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
