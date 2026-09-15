"""Repackage sources without changing the application's extraction contract."""

import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from native_packages.archive import create_archive
from native_packages.build import assemble
from native_packages.build import packager_digest as native_packager_digest
from native_packages.common import file_digest, read_json, write_json
from native_packages.download import Downloader
from native_packages.layout import relative_link
from native_packages.planning import archive_name
from native_packages.relocate import relocate_elf, relocate_macho, sign_macho

from .planning import packager_digest


def extract(source, destination):
    with tarfile.open(source) as archive:
        archive.extractall(destination, filter="data")


def assemble_runtime(package, root, cache, *, signing_identity="-", keychain=None):
    if package["packager"] != packager_digest():
        raise ValueError("Runtime packager changed after planning")
    if package["engine"] == "homebrew":
        assemble(
            package | {"packager": native_packager_digest()},
            root,
            cache,
            signing_identity=signing_identity,
            keychain=keychain,
        )
        relative_link(root / package["service"], root / "bin" / package["service"])
        return
    root.mkdir()
    component = package["components"][0]
    source = Downloader(cache).fetch(component["url"], component["sha256"])
    if package["engine"] == "phar":
        shutil.copyfile(source, root / "composer")
        (root / "composer").chmod(0o755)
    elif package["engine"] == "vendor":
        extract(source, root)
        executable = root / "typesense-server"
        if not executable.is_file():
            raise ValueError("Typesense archive has no root executable")
        executable.chmod(0o755)
        if package["os"] == "darwin":
            relocate_macho(root, {})
            sign_macho(root, signing_identity, keychain)
        else:
            relocate_elf(root, {}, package["arch"])
    elif package["engine"] == "composer":
        tool = next(row for row in package["components"] if row["name"] == "composer")
        composer = Downloader(cache).fetch(tool["url"], tool["sha256"])
        php = os.environ.get("PHP_BINARY") or shutil.which("php")
        if php is None:
            raise RuntimeError("PHP is required to install Reverb's locked dependencies")
        with tempfile.TemporaryDirectory() as temporary:
            extracted = Path(temporary)
            extract(source, extracted)
            directories = list(extracted.iterdir())
            if len(directories) != 1 or not directories[0].is_dir():
                raise ValueError("Reverb source archive has an unexpected root")
            app = directories[0]
            before = file_digest(app / "composer.lock")
            subprocess.run(
                [
                    php,
                    composer,
                    "install",
                    "--no-dev",
                    "--prefer-dist",
                    "--no-interaction",
                    "--optimize-autoloader",
                ],
                cwd=app,
                check=True,
            )
            subprocess.run([php, composer, "audit", "--locked", "--no-dev"], cwd=app, check=True)
            if file_digest(app / "composer.lock") != before:
                raise ValueError("Composer changed the committed dependency lock")
            for name in [
                "app",
                "bootstrap",
                "config",
                "routes",
                "storage",
                "vendor",
                "artisan",
                "composer.json",
                "composer.lock",
                "LICENSE",
            ]:
                path = app / name
                if path.is_dir():
                    shutil.copytree(path, root / name)
                else:
                    shutil.copyfile(path, root / name)
            # Only the checked-in public local defaults are distributed. No build
            # key, database, private environment or generated configuration cache is copied.
            for file in (root / "bootstrap/cache").glob("*.php"):
                file.unlink()
            example = app / ".env.example"
            if example.exists():
                defaults = example.read_text().replace("APP_DEBUG=true", "APP_DEBUG=false")
                defaults = defaults.replace("CACHE_STORE=database", "CACHE_STORE=array")
                defaults = defaults.replace("SESSION_DRIVER=database", "SESSION_DRIVER=array")
                (root / ".env").write_text(defaults)
    else:
        raise ValueError(f"Unknown runtime engine: {package['engine']}")


def build(package, output, cache, *, signing_identity="-", keychain=None):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        tree = Path(temporary) / "runtime"
        assemble_runtime(package, tree, cache, signing_identity=signing_identity, keychain=keychain)
        provenance = tree / "PROVENANCE.json"
        write_json(
            provenance,
            {
                **(read_json(provenance) if provenance.exists() else {}),
                "service": package["service"],
                "version": package["version"],
                "inputs": package["components"],
                "deps": package["deps"],
                "packager": package["packager"],
                "repository": "https://github.com/fadogen/binaries",
            },
        )
        archive = output / package["filename"]
        create_archive(tree, archive, ".")
    checksum = file_digest(archive)
    archive = archive.rename(output / archive_name(package, checksum))
    return package | {"filename": archive.name, "sha256": checksum, "bytes": archive.stat().st_size}
