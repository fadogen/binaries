"""Relocate dynamic dependencies and reject unresolved non-system libraries."""

import os
import re
from pathlib import Path

from .common import file_digest, run
from .layout import dependency_target

MACHO = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
SYSTEM_ELF = {
    "libc.so.6",
    "libm.so.6",
    "libpthread.so.0",
    "libdl.so.2",
    "librt.so.1",
    "libresolv.so.2",
    "libutil.so.1",
    "libgcc_s.so.1",
    "libstdc++.so.6",
    "ld-linux-x86-64.so.2",
    "ld-linux-aarch64.so.1",
}


def binary_files(root, magic):
    seen = set()
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        stat = path.stat()
        key = (stat.st_dev, stat.st_ino)
        if key in seen:
            continue
        with path.open("rb") as stream:
            header = stream.read(8)
        if header[:4] not in magic:
            continue
        if header[:4] == b"\xca\xfe\xba\xbe" and int.from_bytes(header[4:8], "big") > 32:
            continue
        seen.add(key)
        yield path


def library_index(root):
    index = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and (".so" in path.name or path.name.endswith(".dylib")):
            index.setdefault(path.name, set()).add(path.resolve())
    return index


def unique_library(index, name):
    candidates = index.get(name, set())
    if not candidates:
        raise ValueError(f"Missing bundled library: {name}")
    if len(candidates) > 1:
        checksums = {file_digest(path) for path in candidates}
        if len(checksums) != 1:
            raise ValueError(f"Ambiguous bundled library: {name}")
    return sorted(candidates)[0]


def relocate_macho(root, locations):
    index = library_index(root)
    records = []
    for path in binary_files(root, MACHO):
        references = [
            line.strip().split(" (compatibility version", 1)[0]
            for line in run(["otool", "-L", path]).splitlines()[1:]
            if line.startswith("\t")
        ]
        identities = run(["otool", "-D", path]).splitlines()[1:]
        arguments, changes = ["install_name_tool"], []
        for reference in references:
            if reference in identities:
                arguments.extend(["-id", "@rpath/" + str(path.relative_to(root))])
                continue
            if reference.startswith(("/usr/lib/", "/System/Library/")):
                continue
            target = dependency_target(reference, locations)
            if target is None:
                if reference.startswith("@loader_path/"):
                    target = (path.parent / reference.removeprefix("@loader_path/")).resolve()
                elif reference.startswith("@rpath/"):
                    target = unique_library(index, Path(reference).name)
                else:
                    raise ValueError(f"Unresolved Mach-O reference: {path}: {reference}")
            if not target.exists() or not target.resolve().is_relative_to(root):
                raise ValueError(f"Mach-O dependency leaves package: {path}: {reference}")
            replacement = "@loader_path/" + os.path.relpath(target, path.parent)
            arguments.extend(["-change", reference, replacement])
            changes.append([reference, replacement])
        details = run(["otool", "-l", path])
        for rpath in re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset", details):
            arguments.extend(["-delete_rpath", rpath])
        path.chmod(path.stat().st_mode | 0o200)
        if len(arguments) > 1:
            run([*arguments, path])
        records.append({"path": str(path.relative_to(root)), "changes": changes})
    return records


def sign_macho(root, identity="-", keychain=None):
    paths = list(binary_files(root, MACHO))
    for path in paths:
        arguments = ["codesign", "--force", "--sign", identity]
        if identity == "-":
            arguments.append("--timestamp=none")
        else:
            arguments.extend(["--timestamp", "--options", "runtime"])
        if keychain is not None:
            arguments.extend(["--keychain", keychain])
        run([*arguments, path])
    for path in paths:
        run(["codesign", "--verify", "--strict", path])
    return len(paths)


def relocate_elf(root, locations, arch):
    index = library_index(root)
    interpreter = {"arm64": "/lib/ld-linux-aarch64.so.1", "x86_64": "/lib64/ld-linux-x86-64.so.2"}[arch]
    records = []
    for path in binary_files(root, {b"\x7fELF"}):
        needed = run(["patchelf", "--print-needed", path]).splitlines()
        directories, changes = set(), []
        for reference in needed:
            if reference in SYSTEM_ELF:
                continue
            target = dependency_target(reference, locations)
            if target is None:
                target = unique_library(index, reference)
            directories.add(target.parent)
            if "/" in reference:
                run(["patchelf", "--replace-needed", reference, target.name, path])
                changes.append([reference, target.name])
        rpaths = ["$ORIGIN/" + os.path.relpath(directory, path.parent) for directory in sorted(directories)]
        path.chmod(path.stat().st_mode | 0o200)
        run(["patchelf", "--set-rpath", ":".join(rpaths), path])
        # Shared objects have no PT_INTERP; the ELF program headers distinguish them.
        details = run(["readelf", "-l", path])
        if re.search(r"^\s*INTERP\s", details, re.MULTILINE):
            run(["patchelf", "--set-interpreter", interpreter, path])
        records.append({"path": str(path.relative_to(root)), "rpath": rpaths, "changes": changes})
    return records
