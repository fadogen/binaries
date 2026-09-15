#!/usr/bin/env python3
"""Plan, repackage, qualify and publish application runtimes."""

import argparse
import json
import os
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from native_packages.common import read_json, write_json
from native_packages.storage import Store
from runtime_packages.build import build
from runtime_packages.catalogues import catalogue_name, selected_packages
from runtime_packages.php import (
    build_native,
    build_windows,
    php_plan,
    prepare,
    resolved_package,
    validate_php_receipt,
)
from runtime_packages.planning import plan
from runtime_packages.smoke import verify
from runtime_packages.sources import SourceCache
from runtime_packages.storage import reconcile


def store():
    return Store(os.environ.get("R2_BUCKET_NAME"), os.environ.get("R2_ENDPOINT"))


def output(name, value):
    if path := os.environ.get("GITHUB_OUTPUT"):
        with open(path, "a") as stream:
            stream.write(f"{name}={value}\n")


def metadata(packages, directory, *, remote):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    names = sorted({catalogue_name(package) for package in packages})
    if remote:
        store().fetch_catalogues(names, directory)
    else:
        for name in names:
            request = Request(f"https://binaries.fadogen.app/{name}", headers={"User-Agent": "Fadogen/0.1.0"})
            try:
                with urlopen(request, timeout=60) as response:
                    document = json.load(response)
            except HTTPError as error:
                if error.code != 404:
                    raise
                document = {}
            if not isinstance(document, dict):
                raise ValueError(f"Invalid public catalogue: {name}")
            write_json(directory / name, document)
    return {name: read_json(directory / name) for name in names}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    resolve = commands.add_parser("plan")
    resolve.add_argument("--config", default=".github/config/runtimes.json")
    resolve.add_argument("--output", default="runtime-plan.json")
    resolve.add_argument("--metadata", default="metadata/runtimes")
    resolve.add_argument("--cache", default=".cache/runtimes")
    resolve.add_argument("--tools", nargs="+")
    resolve.add_argument("--force", action="store_true")
    resolve.add_argument("--remote", action="store_true")
    resolve.add_argument("--php", action="store_true", help="Plan the separately compiled PHP catalogue")
    for command in ["prepare", "build", "verify", "publish-archive", "publish-metadata"]:
        action = commands.add_parser(command)
        action.add_argument("--plan", default="runtime-plan.json")
        action.add_argument("--output", default="dist/runtimes")
        if command != "publish-metadata":
            action.add_argument("--id", required=True)
        if command in ["build", "prepare"]:
            action.add_argument("--cache", default=".cache/runtimes")
            action.add_argument("--workspace", default=".cache/php-build")
        if command == "build":
            action.add_argument("--signing-identity", default="-")
            action.add_argument("--keychain")
    args = parser.parse_args()
    if args.command == "plan":
        if args.php:
            if args.tools:
                parser.error("--php cannot be combined with --tools")
            document = php_plan(
                read_json(".github/config/php.json"),
                read_json(".github/config/services.json")["targets"],
                args.cache,
            )
        else:
            config = read_json(args.config)
            document = {
                "packages": plan(config, args.cache, tools=args.tools),
                "tools": args.tools or config["tools"],
            }
        packages = document["packages"]
        catalogues = metadata(packages, args.metadata, remote=args.remote)
        selected = selected_packages(packages, catalogues, force=args.force)
        # SPC resolves current dependency releases on the target platform. Native
        # jobs prepare sources first and skip compilation when their hashes match.
        if args.php:
            selected = [row for row in packages if row["engine"] == "spc" or row in selected]
        write_json(args.output, document | {"catalogues": catalogues, "force": args.force})
        SourceCache(args.cache).prune(packages)
        output(
            "matrix",
            json.dumps(
                {
                    "include": [
                        {key: row[key] for key in ["id", "service", "os", "arch", "runner", "engine"]}
                        for row in selected
                    ]
                }
            ),
        )
        output("should-build", str(bool(selected)).lower())
        print(
            json.dumps(
                {"packages": len(packages), "selected": len(selected), "ids": [row["id"] for row in selected]}
            )
        )
        return
    document, directory = read_json(args.plan), Path(args.output)
    packages = document["packages"]
    if args.command == "publish-metadata":
        receipts = [read_json(path) for path in sorted(directory.glob("*.json"))]
        print(json.dumps(reconcile(store(), packages, receipts, tools=document["tools"])))
        return
    matches = [row for row in packages if row["id"] == args.id]
    if len(matches) != 1:
        raise ValueError("Package is missing from the frozen plan")
    package = matches[0]
    path = directory / f"{args.id}.json"
    inputs = directory / "inputs" / f"{args.id}.json"
    if args.command == "prepare":
        if package["engine"] == "spc":
            prepared = prepare(package, args.workspace, args.cache)
            write_json(inputs, prepared)
            changed = selected_packages([prepared], document["catalogues"], force=document["force"])
            output("should-build", str(bool(changed)).lower())
        else:
            output("should-build", "true")
        return
    if args.command == "build":
        if package["service"] == "php":
            if package["engine"] == "spc":
                prepared = read_json(inputs)
                expected = resolved_package(package, prepared["sources"])
                if prepared != expected:
                    raise ValueError("Prepared PHP inputs differ from the frozen plan")
                result = build_native(
                    prepared,
                    args.workspace,
                    directory,
                    signing_identity=args.signing_identity,
                    keychain=args.keychain,
                )
            else:
                result = build_windows(package, directory, args.cache)
        else:
            result = build(
                package, directory, args.cache, signing_identity=args.signing_identity, keychain=args.keychain
            )
        write_json(path, result)
    else:
        result = read_json(path)
        if package["service"] == "php":
            package = validate_php_receipt(package, result, verified=args.command != "verify")
        if args.command == "verify":
            result = verify(package, result, directory)
            write_json(path, result)
            output("archive", str((directory / result["filename"]).resolve()))
        else:
            store().publish_archive(package, result, directory / result["filename"])


if __name__ == "__main__":
    main()
