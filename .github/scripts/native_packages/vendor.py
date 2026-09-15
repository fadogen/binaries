"""Keep the existing Windows vendor source, with explicit structural validation."""

import struct
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from .common import file_digest, run
from .planning import archive_name

EXECUTABLES = {
    "mariadb": ["bin/mariadbd.exe", "bin/mariadb.exe", "bin/mysql_install_db.exe"],
    "mysql": ["bin/mysqld.exe", "bin/mysql.exe"],
    "postgresql": ["bin/postgres.exe", "bin/initdb.exe", "bin/psql.exe"],
    "redis": ["redis-server.exe", "redis-cli.exe"],
}


def verify_windows(package, archive):
    prefix = PurePosixPath(f"{package['service']}-{package['version']}")
    with zipfile.ZipFile(archive) as source:
        for name in source.namelist():
            path = PurePosixPath(name)
            if not path.is_relative_to(prefix) or ".." in path.parts or "\\" in name:
                raise ValueError(f"Unsafe Windows archive member: {name}")
        if source.testzip() is not None:
            raise ValueError("Corrupt Windows archive")
        for executable in EXECUTABLES[package["service"]]:
            path = str(prefix / executable)
            if path not in source.namelist():
                raise ValueError(f"Missing native executable: {path}")
            with source.open(path) as stream:
                header = stream.read(64)
                if len(header) < 64 or header[:2] != b"MZ":
                    raise ValueError(f"Not a PE executable: {path}")
                offset = struct.unpack_from("<I", header, 0x3C)[0]
                stream.seek(offset)
                pe = stream.read(6)
                if pe[:4] != b"PE\0\0" or pe[4:] != struct.pack("<H", 0x8664):
                    raise ValueError(f"Not a Windows x64 executable: {path}")
    return {
        "archive_sha256": file_digest(archive),
        "pass": True,
        "tests": ["zip-integrity", "required-PE-x64-executables"],
        "level": "structural-only",
    }


def build_windows(package, output):
    script = Path(__file__).resolve().parent.parent / "services-windows-downloader.sh"
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vendor-", dir=output) as directory:
        run(["bash", script, package["service"], package["version"]], cwd=directory)
        source = Path(directory) / f"{package['service']}-{package['version']}-windows-x86_64.zip"
        checksum = file_digest(source)
        name = archive_name(package, checksum)
        source.rename(output / name)
    return {**package, "filename": name, "sha256": checksum, "bytes": (output / name).stat().st_size}
