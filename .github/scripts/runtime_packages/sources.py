"""Resolve official upstream objects; builders consume only the frozen URLs and hashes."""

import json
import os
import re
import shutil
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from native_packages.common import digest, file_digest, read_json, retry_network, write_json
from native_packages.homebrew import version_key


def request(url, *, headers=None):
    headers = {"User-Agent": "Fadogen-Binaries", **(headers or {})}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if urlparse(url).hostname == "api.github.com" and token:
        headers["Authorization"] = f"Bearer {token}"
    return Request(url, headers=headers)


def get_json(url):
    def download():
        with urlopen(request(url), timeout=60) as response:
            return json.load(response)

    return retry_network(download)


def composer_release(document):
    versions = [row for row in document["stable"] if not row.get("lts")]
    release = max(versions, key=lambda row: version_key(row["version"]))
    if release.get("path") != f"/download/{release['version']}/composer.phar":
        raise ValueError("Unexpected Composer download path")
    return release


def stable_release(document):
    if document.get("draft") or document.get("prerelease"):
        raise ValueError("Upstream release is not stable")
    version = document.get("tag_name")
    if not isinstance(version, str):
        raise ValueError("Missing upstream version")
    version = version.removeprefix("v")
    version_key(version)
    return version


def windows_php_source(document, major):
    release = document[major]
    version = release["version"]
    version_key(version)
    if not version.startswith(major + "."):
        raise ValueError("PHP Windows release differs from its branch")
    variants = [key for key in release if re.fullmatch(r"nts-vs[0-9]+-x64", key)]
    if len(variants) != 1:
        raise ValueError("Missing or ambiguous PHP Windows NTS x64 build")
    abi = variants[0].split("-")[1]
    archive = release[variants[0]]["zip"]
    expected = f"php-{version}-nts-Win32-{abi}-x64.zip"
    if archive.get("path") != expected or not re.fullmatch(r"[a-f0-9]{64}", archive.get("sha256", "")):
        raise ValueError("Invalid Windows PHP archive path or checksum")
    return {
        "name": "php",
        "version": version,
        "abi": abi,
        "sha256": archive["sha256"],
        "url": "https://windows.php.net/downloads/releases/" + expected,
    }


class SourceCache:
    """Conditional HTTP cache whose stored bytes are rehashed before reuse."""

    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)

    def source(self, url, *, expected=None):
        if urlparse(url).scheme != "https":
            raise ValueError("Upstream downloads require HTTPS")
        key = digest(url)
        index = self.directory / f"{key}.json"
        previous = read_json(index) if index.exists() else {}
        checksum = previous.get("sha256", "")
        content = self.directory / f"{checksum}.tar.gz" if re.fullmatch(r"[a-f0-9]{64}", checksum) else None
        valid = content is not None and content.is_file() and checksum == file_digest(content)
        headers = {}
        if valid and previous.get("etag"):
            headers["If-None-Match"] = previous["etag"]

        def download():
            temporary = index.with_suffix(".part")
            try:
                with urlopen(request(url, headers=headers), timeout=120) as response:
                    with temporary.open("wb") as destination:
                        shutil.copyfileobj(response, destination)
                    checksum = file_digest(temporary)
                    if expected is not None and checksum != expected:
                        raise ValueError(f"Upstream checksum mismatch: {url}")
                    temporary.replace(self.directory / f"{checksum}.tar.gz")
                    write_json(index, {"etag": response.headers.get("ETag"), "sha256": checksum})
            except HTTPError as error:
                try:
                    if error.code != 304 or not valid:
                        raise
                finally:
                    error.close()
            finally:
                temporary.unlink(missing_ok=True)

        retry_network(download)
        checksum = read_json(index)["sha256"]
        content = self.directory / f"{checksum}.tar.gz"
        if file_digest(content) != checksum:
            raise ValueError("Source cache changed during resolution")
        if expected is not None and checksum != expected:
            raise ValueError(f"Cached upstream checksum mismatch: {url}")
        return {"url": url, "sha256": checksum}

    def prune(self, packages):
        retained = set()
        for package in packages:
            for source in package["components"]:
                if "url" in source:
                    retained.update([f"{digest(source['url'])}.json", f"{source['sha256']}.tar.gz"])
        for path in self.directory.iterdir():
            if re.fullmatch(r"[a-f0-9]{64}\.(?:json|tar\.gz)", path.name) and path.name not in retained:
                path.unlink()
