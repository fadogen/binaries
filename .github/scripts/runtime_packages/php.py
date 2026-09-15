"""Compile PHP from frozen sources, reusing SPC's upstream dependency recipes."""

import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from urllib.request import urlopen

from native_packages.archive import create_archive
from native_packages.common import digest, file_digest, read_json, run, write_json
from native_packages.download import Downloader
from native_packages.planning import archive_name, fingerprint, identity, validate_receipt
from native_packages.relocate import MACHO, binary_files, sign_macho

from .sources import SourceCache, get_json, request, windows_php_source


def php_packager_digest():
    folder = Path(__file__).parent
    return digest(
        {
            name: file_digest(path)
            for name, path in {
                "php.py": folder / "php.py",
                "archive.py": folder.parent / "native_packages/archive.py",
                "download.py": folder.parent / "native_packages/download.py",
                "common.py": folder.parent / "native_packages/common.py",
                "relocate.py": folder.parent / "native_packages/relocate.py",
                "entitlements": folder.parent / "entitlements-php.plist",
            }.items()
        }
    )


def supported_branches(document, configured):
    supported = document.get("8", {}).get("supported_versions")
    if (
        not isinstance(supported, list)
        or not supported
        or not all(isinstance(item, str) and re.fullmatch(r"[0-9]+\.[0-9]+", item) for item in supported)
    ):
        raise ValueError("PHP.net did not return a valid supported-version list")
    selected = [version for version in configured if version in supported]
    if not selected:
        raise ValueError("No configured PHP branch is maintained; review the support policy")
    return selected


def latest_pecl(name):
    with urlopen(request(f"https://pecl.php.net/rest/r/{name}/stable.txt"), timeout=60) as response:
        version = response.read().decode().strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version):
        raise ValueError(f"Invalid stable PECL release for {name}")
    return version


def php_plan(config, targets, cache):
    branches = supported_branches(
        get_json("https://www.php.net/releases/index.php?json"), config["supported"]
    )
    windows = get_json("https://windows.php.net/downloads/releases/releases.json")
    cache = SourceCache(cache)
    xdebug, redis = latest_pecl("xdebug"), latest_pecl("redis")
    packages = []
    for major in branches:
        release = get_json(f"https://www.php.net/releases/index.php?json&version={major}")
        version = release["version"]
        if not re.fullmatch(re.escape(major) + r"\.[0-9]+", version):
            raise ValueError("PHP.net returned a release outside the requested branch")
        source = next(row for row in release["source"] if row["filename"] == f"php-{version}.tar.xz")
        if not re.fullmatch(r"[a-f0-9]{64}", source.get("sha256", "")):
            raise ValueError("PHP.net did not provide a source checksum")
        for target in targets:
            package = {
                "service": "php",
                "major": major,
                "version": version,
                "releaseDate": release["date"],
                "os": target["os"],
                "arch": target["arch"],
                "runner": target["runner"],
                "packager": php_packager_digest(),
            }
            if target["os"] == "windows":
                php = windows_php_source(windows, major)
                package.update(
                    engine="vendor", version=php["version"], runner="windows-2025", xdebug=xdebug, redis=redis
                )
                package["releaseDate"] = windows[major][f"nts-{php['abi']}-x64"]["mtime"]
                abi = php["abi"]
                xdebug_url = f"https://xdebug.org/files/php_xdebug-{xdebug}-{major}-nts-{abi}-x86_64.dll"
                redis_url = f"https://downloads.php.net/~windows/pecl/releases/redis/{redis}/php_redis-{redis}-{major}-nts-{abi}-x64.zip"
                # Missing extensions are a failed plan, never a silently reduced package.
                package["components"] = [
                    php,
                    {"name": "xdebug", "version": xdebug, **cache.source(xdebug_url)},
                    {"name": "redis", "version": redis, **cache.source(redis_url)},
                ]
            else:
                os_name = "macos" if target["os"] == "darwin" else "linux"
                arch = "aarch64" if target["arch"] == "arm64" else "x86_64"
                tool = config["spc"]["assets"][f"spc-{os_name}-{arch}.tar.gz"]
                package.update(
                    engine="spc",
                    extensions=config["extensions"],
                    shared_extensions=config["shared_extensions"],
                )
                package["components"] = [
                    {
                        "name": "php-src",
                        "version": version,
                        "url": f"https://www.php.net/distributions/{source['filename']}",
                        "sha256": source["sha256"],
                    },
                    {"name": "spc", "version": config["spc"]["version"], **tool},
                    {
                        "name": "recipe",
                        "sha256": digest(
                            {
                                "extensions": config["extensions"],
                                "shared_extensions": config["shared_extensions"],
                            }
                        ),
                    },
                ]
            package["deps"] = fingerprint(package)
            package["id"] = identity(package)
            package["filename"] = archive_name(package, package["deps"])
            packages.append(package)
    return {"packages": packages, "supported": branches, "tools": ["php"]}


def download_arguments(spc, package):
    source = next(item for item in package["components"] if item["name"] == "php-src")
    return [
        str(spc),
        "download",
        f"--with-php={package['version']}",
        "--for-extensions=" + ",".join(package["extensions"] + package["shared_extensions"]),
        "--custom-url=php-src:" + source["url"],
        "--prefer-pre-built",
        "--ignore-cache-sources",
        "--without-suggestions",
        "--no-alt",
        "--retry=2",
    ]


def source_snapshot(downloads):
    downloads = Path(downloads).resolve()
    lock = read_json(downloads / ".lock.json")
    if not isinstance(lock, dict) or not lock:
        raise ValueError("SPC did not produce a source lock")
    sources = []
    for name, entry in sorted(lock.items()):
        source = (downloads / entry.get("filename", entry.get("dirname", ""))).resolve()
        if not source.is_relative_to(downloads) or source == downloads:
            raise ValueError("SPC source lock points outside its downloads directory")
        if entry["source_type"] == "archive":
            checksum = file_digest(source)
        elif entry["source_type"] == "git":
            if run(
                [
                    "git",
                    "-C",
                    source,
                    "status",
                    "--porcelain",
                    "--untracked-files=all",
                    "--ignore-submodules=none",
                ]
            ).strip():
                raise ValueError("SPC Git source differs from its committed tree")
            checksum = digest({"commit": run(["git", "-C", source, "rev-parse", "HEAD"]).strip()})
        else:
            raise ValueError("SPC source must be an archive or a committed Git tree")
        sources.append({"name": name, "sha256": checksum})
    return sources


def resolved_package(package, sources):
    if not sources or not isinstance(sources, list):
        raise ValueError("Missing PHP source snapshot")
    names = set()
    for source in sources:
        name = source.get("name")
        if (
            not isinstance(name, str)
            or name in names
            or not re.fullmatch(r"[a-f0-9]{64}", source.get("sha256", ""))
        ):
            raise ValueError("Invalid or duplicate PHP source fingerprint")
        names.add(name)
    return package | {"sources": sources, "deps": digest({"base": fingerprint(package), "sources": sources})}


def environment(package):
    result = dict(os.environ)
    if result.get("GH_TOKEN"):
        result["GITHUB_TOKEN"] = result["GH_TOKEN"]
    result["SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS"] = ""
    if package["os"] == "linux":
        result["SPC_LIBC"] = "glibc"
    return result


def prepare(package, workspace, cache):
    if package["packager"] != php_packager_digest():
        raise ValueError("PHP recipe changed after planning")
    workspace = Path(workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    tool = next(row for row in package["components"] if row["name"] == "spc")
    archive = Downloader(cache).fetch(tool["url"], tool["sha256"])
    with tarfile.open(archive) as tar:
        if tar.getnames() != ["spc"]:
            raise ValueError("SPC release archive has an unexpected layout")
        tar.extractall(workspace, filter="data")
    spc = workspace / "spc"
    require_version = run([spc, "--version"])
    if tool["version"] not in require_version:
        raise ValueError("SPC version differs from its pinned release")
    subprocess.run(download_arguments(spc, package), cwd=workspace, env=environment(package), check=True)
    sources = source_snapshot(workspace / "downloads")
    actual = next(row["sha256"] for row in sources if row["name"] == "php-src")
    expected = next(row["sha256"] for row in package["components"] if row["name"] == "php-src")
    if actual != expected:
        raise ValueError("Downloaded PHP source differs from PHP.net's planned checksum")
    return resolved_package(package, sources)


def build_native(package, workspace, output, *, signing_identity="-", keychain=None):
    if package["packager"] != php_packager_digest():
        raise ValueError("PHP packager changed after planning")
    workspace, output = Path(workspace).resolve(), Path(output).resolve()
    if source_snapshot(workspace / "downloads") != package["sources"]:
        raise ValueError("PHP source bytes changed after preparation")
    spc = workspace / "spc"
    env = environment(package)
    # System changes are confined to disposable GitHub runners. Local qualification
    # never installs compiler prerequisites implicitly.
    doctor = [spc, "doctor"]
    if os.environ.get("GITHUB_ACTIONS") == "true":
        doctor.append("--auto-fix")
    subprocess.run(doctor, cwd=workspace, env=env, check=True)
    subprocess.run(
        [
            spc,
            "build",
            ",".join(package["extensions"]),
            "--build-cli",
            "--build-fpm",
            "--build-shared=" + ",".join(package["shared_extensions"]),
        ],
        cwd=workspace,
        env=env,
        check=True,
    )
    subprocess.run(
        [
            spc,
            "dump-license",
            "--for-extensions=" + ",".join(package["extensions"] + package["shared_extensions"]),
        ],
        cwd=workspace,
        env=env,
        check=True,
    )
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        root = Path(temporary)
        for old, new in [("php", "php-cli"), ("php-fpm", "php-fpm")]:
            shutil.copy2(workspace / "buildroot/bin" / old, root / new)
        extensions = root / "extensions"
        extensions.mkdir()
        for source in sorted((workspace / "buildroot").rglob("*.so")):
            destination = extensions / source.name
            if destination.exists():
                raise ValueError(f"Duplicate PHP extension filename: {source.name}")
            shutil.copy2(source, destination)
        for name in package["shared_extensions"]:
            if not (extensions / f"{name}.so").is_file():
                raise ValueError(f"Missing shared PHP extension: {name}")
        shutil.copytree(workspace / "buildroot/license", root / "license")
        write_json(root / "PROVENANCE.json", package)
        if package["os"] == "darwin":
            sign_macho(root, signing_identity, keychain)
            entitlements = Path(__file__).parent.parent / "entitlements-php.plist"
            for binary in [root / "php-cli", root / "php-fpm"]:
                arguments = [
                    "codesign",
                    "--force",
                    "--sign",
                    signing_identity,
                    "--entitlements",
                    entitlements,
                ]
                arguments += (
                    ["--timestamp=none"]
                    if signing_identity == "-"
                    else ["--timestamp", "--options", "runtime"]
                )
                if keychain:
                    arguments += ["--keychain", keychain]
                run([*arguments, binary])
            for binary in binary_files(root, MACHO):
                run(["codesign", "--verify", "--strict", binary])
        archive = output / package["filename"]
        create_archive(root, archive, ".")
    return finish_archive(package, archive)


def finish_archive(package, archive):
    checksum = file_digest(archive)
    archive = archive.rename(archive.parent / archive_name(package, checksum))
    return package | {"filename": archive.name, "sha256": checksum, "bytes": archive.stat().st_size}


def build_windows(package, output, cache):
    if package["packager"] != php_packager_digest():
        raise ValueError("PHP packager changed after planning")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    downloader = Downloader(cache)
    sources = {item["name"]: downloader.fetch(item["url"], item["sha256"]) for item in package["components"]}
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        root = Path(temporary) / f"php-{package['version']}"
        with zipfile.ZipFile(sources["php"]) as archive:
            for member in archive.infolist():
                path = PurePosixPath(member.filename)
                if (
                    path.is_absolute()
                    or ".." in path.parts
                    or "\\" in member.filename
                    or ":" in member.filename
                ):
                    raise ValueError("Windows PHP archive escapes its root")
            archive.extractall(root)
        if not (root / "php.exe").is_file() or not (root / "php-cgi.exe").is_file():
            raise ValueError("Windows PHP archive is missing CLI or CGI")
        (root / "php.exe").rename(root / "php-cli.exe")
        shutil.rmtree(root / "dev", ignore_errors=False)
        shutil.copyfile(sources["xdebug"], root / "ext/php_xdebug.dll")
        with zipfile.ZipFile(sources["redis"]) as archive:
            matches = [name for name in archive.namelist() if Path(name).name == "php_redis.dll"]
            if len(matches) != 1:
                raise ValueError("Redis extension archive must contain exactly one DLL")
            (root / "ext/php_redis.dll").write_bytes(archive.read(matches[0]))
        write_json(root / "PROVENANCE.json", package)
        archive = output / package["filename"]
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zipped:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    info = zipfile.ZipInfo(
                        str(path.relative_to(root.parent)).replace("\\", "/"), (1980, 1, 1, 0, 0, 0)
                    )
                    info.compress_type = zipfile.ZIP_DEFLATED
                    zipped.writestr(info, path.read_bytes())
    return finish_archive(package, archive)


def validate_php_receipt(base, receipt, *, verified=True):
    expected = resolved_package(base, receipt.get("sources")) if base["engine"] == "spc" else base
    validate_receipt(expected, receipt, verified=verified)
    return expected
