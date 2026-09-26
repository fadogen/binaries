"""Publish verified runtime receipts and retire only unreferenced runtime objects."""

import re
import tempfile
from pathlib import Path

from native_packages.common import read_json, write_json

from .catalogues import catalogue_name, merge_catalogues


def references(catalogues):
    result = set()

    def visit(record):
        if not isinstance(record, dict):
            raise ValueError("Invalid runtime catalogue")
        if "latest" in record or "version" in record:
            filename = record.get("filename")
            if not isinstance(filename, str) or Path(filename).name != filename:
                raise ValueError("Invalid runtime archive reference")
            result.add(filename)
        else:
            for value in record.values():
                visit(value)

    for catalogue in catalogues.values():
        visit(catalogue)
    return result


def reconcile(store, packages, receipts, *, tools):
    if not packages or not tools or {package["service"] for package in packages} != set(tools):
        raise ValueError("Cleanup requires a complete, nonempty runtime plan")
    names = sorted({catalogue_name(package) for package in packages})
    pattern = "(?:" + "|".join(re.escape(tool) for tool in tools) + ")"
    archives = re.compile(
        pattern + r"-[0-9]+(?:\.[0-9]+)*(?:-[a-f0-9]{64})?"
        r"(?:-(?:darwin|linux|windows|any)-(?:arm64|x86_64|any))?\.(?:tar\.gz|zip)"
    )
    catalogues = re.compile(r"metadata-" + pattern + r"(?:-(?:darwin|linux|windows)-(?:arm64|x86_64))?\.json")
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        store.fetch_catalogues(names, directory)
        before = {name: read_json(directory / name) for name in names}
        after = merge_catalogues(before, receipts, packages)
        referenced = references(after)
        keys = store.list_keys()
        if not referenced.issubset(keys):
            raise RuntimeError("Runtime catalogue references missing archives; publication refused")
        for name, catalogue in after.items():
            write_json(directory / name, catalogue)
        store.publish_metadata(directory, pattern="metadata-*.json")
        store.fetch_catalogues(names, directory, require_existing=True)
        if {name: read_json(directory / name) for name in names} != after:
            raise RuntimeError("Runtime catalogues changed after publication; cleanup refused")
        retired = sorted(key for key in keys - set(names) if catalogues.fullmatch(key))
        obsolete = sorted(key for key in keys - referenced if archives.fullmatch(key))
        store.delete_keys(retired)
        store.delete_keys(obsolete)
    return {"catalogues": len(names), "deleted_catalogues": len(retired), "deleted_archives": len(obsolete)}
