"""Assemble a native runtime from the exact bottles listed in a plan."""

import platform
import tempfile
from pathlib import Path

from .archive import create_archive, extract_bottle
from .common import digest, file_digest, write_json
from .download import Downloader
from .launchers import install_launcher, patch_mariadb_installer
from .layout import expose_service, relative_link, repair_links, trim_keg
from .planning import archive_name
from .relocate import relocate_elf, relocate_macho, sign_macho


def packager_digest():
    folder = Path(__file__).parent
    names = ["archive.py", "build.py", "common.py", "download.py", "launchers.py", "layout.py", "relocate.py"]
    return digest({name: file_digest(folder / name) for name in names})


def assemble(package, root, cache, *, signing_identity="-", keychain=None):
    current_os = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system())
    current_arch = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x86_64"}.get(platform.machine())
    if (current_os, current_arch) != (package["os"], package["arch"]):
        raise ValueError("Packaging must run on the target OS and architecture")
    if package["packager"] != packager_digest():
        raise ValueError("The packager changed after the plan was produced")
    root.mkdir()
    downloader = Downloader(cache)
    locations = {}
    for component in package["components"]:
        bottle = downloader.fetch(component["url"], component["sha256"])
        keg = extract_bottle(bottle, root / "Cellar", component)
        trim_keg(keg)
        locations[component["name"]] = keg
        relative_link(root / "opt" / component["name"], keg)
    keg = locations[package["formula"]]
    expose_service(root, package["service"], package["formula"], keg)
    if package["service"] in {"mariadb", "mysql"}:
        executable = "mariadbd" if package["service"] == "mariadb" else "mysqld"
        install_launcher(root, root / "bin" / executable, keg / "bin" / executable, package["service"])
    if package["service"] == "mariadb":
        patch_mariadb_installer(keg / "bin/mariadb-install-db")
    repair_links(root, locations)
    if package["os"] == "darwin":
        relocation = relocate_macho(root, locations)
        sign_macho(root, signing_identity, keychain)
    else:
        relocation = relocate_elf(root, locations, package["arch"])
    if not relocation:
        raise ValueError("The package contains no native executable")
    write_json(
        root / "PROVENANCE.json",
        {
            "service": package["service"],
            "version": package["version"],
            "inputs": package["components"],
            "deps": package["deps"],
            "packager": package["packager"],
            "relocation": relocation,
            "repository": "https://github.com/fadogen/binaries",
            "modifications": "Dynamic library paths and runtime layout; SQL launchers; MariaDB installer path quoting.",
        },
    )


def build(package, output, cache, *, signing_identity="-", keychain=None):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="packaging-", dir=output) as temporary:
        tree = Path(temporary) / "runtime"
        assemble(package, tree, cache, signing_identity=signing_identity, keychain=keychain)
        destination = output / package["filename"]
        create_archive(tree, destination, f"{package['service']}-{package['version']}")
    checksum = file_digest(destination)
    filename = archive_name(package, checksum)
    destination = destination.rename(output / filename)
    return {**package, "filename": filename, "sha256": checksum, "bytes": destination.stat().st_size}
