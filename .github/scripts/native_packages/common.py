"""Shared serialization, hashing and command execution."""

import hashlib
import json
import subprocess
import time
from http.client import IncompleteRead
from pathlib import Path
from urllib.error import HTTPError, URLError


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def file_digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def run(arguments, **kwargs):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{arguments[0]} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout


def retry_network(operation, attempts=3):
    """Retry interrupted transfers, rate limits and temporary upstream failures."""
    for attempt in range(attempts):
        try:
            return operation()
        except (URLError, ConnectionError, TimeoutError, IncompleteRead) as error:
            if isinstance(error, HTTPError) and error.code != 429 and error.code < 500:
                raise
            if attempt == attempts - 1:
                raise
            time.sleep(2**attempt)
