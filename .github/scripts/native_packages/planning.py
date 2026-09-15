"""One frozen input plan shared by packaging and metadata publication."""

import re
from copy import deepcopy

from .common import digest


def fingerprint(package):
    inputs = {
        key: package[key]
        for key in ["service", "major", "version", "os", "arch", "engine", "formula", "packager"]
        if key in package
    }
    # A tap commit changes for unrelated formulae. Only bottle bytes and runtime
    # selection affect the package; provenance remains in the full frozen plan.
    inputs["components"] = [
        {
            key: component[key]
            for key in ["name", "version", "revision", "tag", "sha256", "role"]
            if key in component
        }
        for component in package["components"]
    ]
    return digest(inputs)


def identity(package):
    return f"{package['service']}-{package['major']}-{package['os']}-{package['arch']}"


def archive_name(package, checksum):
    extension = "zip" if package["os"] == "windows" else "tar.gz"
    return (
        f"{package['service']}-{package['version']}-{checksum}-{package['os']}-{package['arch']}.{extension}"
    )


def make_matrix(packages, metadata, *, force=()):
    matrix = []
    for package in packages:
        previous = (
            metadata.get(f"{package['os']}-{package['arch']}", {})
            .get(package["service"], {})
            .get(package["major"], {})
        )
        forced = package["service"] in force or f"{package['service']}@{package['major']}" in force
        if forced or previous.get("latest") != package["version"] or previous.get("deps") != package["deps"]:
            matrix.append(package)
    return matrix


def validate_receipt(package, result, *, verified=True):
    key = identity(package)
    for field in ["service", "major", "version", "os", "arch", "deps", "packager", "components"]:
        if result.get(field) != package.get(field):
            raise ValueError(f"Receipt differs from the frozen plan: {key} ({field})")
    if not re.fullmatch(r"[a-f0-9]{64}", result.get("sha256", "")):
        raise ValueError(f"Invalid archive checksum: {key}")
    if result.get("filename") != archive_name(package, result["sha256"]):
        raise ValueError(f"Archive filename does not identify its content: {key}")
    if verified and result.get("verified_sha256") != result["sha256"]:
        raise ValueError(f"Archive bytes have not been verified: {key}")


def merge_results(metadata, results, packages):
    expected = {identity(package): package for package in packages}
    merged = deepcopy(metadata)
    seen = set()
    for result in results:
        key = identity(result)
        package = expected.get(key)
        if key in seen or package is None:
            raise ValueError(f"Unexpected or duplicate package receipt: {key}")
        validate_receipt(package, result)
        target = merged.setdefault(f"{result['os']}-{result['arch']}", {})
        target.setdefault(result["service"], {})[result["major"]] = {
            "latest": result["version"],
            "sha256": result["sha256"],
            "filename": result["filename"],
            "deps": result["deps"],
        }
        seen.add(key)
    return merged
