"""Content-addressed downloads, verified again before every use."""

import json
import re
import shutil
import tempfile
from pathlib import Path
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

from .common import file_digest


class Downloader:
    def __init__(self, cache):
        self.cache = Path(cache)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.tokens = {}

    def fetch(self, url, checksum):
        if not re.fullmatch(r"[a-f0-9]{64}", checksum):
            raise ValueError("A SHA-256 checksum is required for every bottle")
        destination = self.cache / (checksum + ".tar.gz")
        if destination.exists() and file_digest(destination) == checksum:
            return destination
        destination.unlink(missing_ok=True)
        headers = {"User-Agent": "Fadogen-Binaries"}
        parsed = urlparse(url)
        if parsed.hostname == "ghcr.io":
            match = re.fullmatch(
                r"/v2/(homebrew/core/[a-z0-9+._-]+(?:/[a-z0-9+._-]+)*)/blobs/sha256:([a-f0-9]{64})",
                parsed.path,
            )
            if not match or match[2] != checksum:
                raise ValueError("Bottle URL does not match the planned checksum")
            repository = match[1]
            if repository not in self.tokens:
                query = urlencode({"service": "ghcr.io", "scope": f"repository:{repository}:pull"})
                with urlopen("https://ghcr.io/token?" + query, timeout=60) as response:
                    self.tokens[repository] = json.load(response)["token"]
            headers["Authorization"] = "Bearer " + self.tokens[repository]
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=self.cache, delete=False) as output:
                temporary = Path(output.name)
                with urlopen(Request(url, headers=headers), timeout=120) as response:
                    shutil.copyfileobj(response, output, length=1024 * 1024)
            if file_digest(temporary) != checksum:
                raise ValueError(f"Checksum mismatch for {url}")
            temporary.replace(destination)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        return destination
