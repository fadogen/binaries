"""Extract verified bottles and emit deterministic application archives."""

import gzip
import tarfile
from pathlib import Path, PurePosixPath

from .layout import runtime_files


def extract_bottle(source, cellar, component):
    cellar = Path(cellar)
    cellar.mkdir(parents=True, exist_ok=True)
    version = component["version"]
    if component.get("revision", 0):
        version += f"_{component['revision']}"
    expected = PurePosixPath(component["name"], version)
    with tarfile.open(source) as archive:
        members = archive.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if path == PurePosixPath(component["name"]) and member.isdir():
                continue
            if not path.is_relative_to(expected):
                raise ValueError(f"Unexpected bottle version or root: {member.name}; expected {expected}")

        def runtime_filter(member, destination):
            path = PurePosixPath(member.name)
            if path.is_relative_to(expected) and not runtime_files(path.relative_to(expected), component):
                return None
            return tarfile.data_filter(member, destination)

        archive.extractall(cellar, members=members, filter=runtime_filter)
    keg = cellar / expected
    if not keg.is_dir():
        raise ValueError(f"Bottle has no keg: {expected}")
    return keg


def create_archive(tree, destination, name):
    tree, destination = Path(tree), Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with (
        destination.open("wb") as raw,
        gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0, compresslevel=9) as compressed,
    ):
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for path in [tree, *sorted(tree.rglob("*"))]:
                info = archive.gettarinfo(
                    str(path), arcname=str(PurePosixPath(name) / path.relative_to(tree))
                )
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                if info.isfile():
                    with path.open("rb") as content:
                        archive.addfile(info, content)
                else:
                    archive.addfile(info)
