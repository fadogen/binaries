"""Functional checks against final archives extracted into unrelated paths with spaces."""

import base64
import hashlib
import hmac
import json
import os
import platform
import shutil
import socket
import struct
import subprocess
import tarfile
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from native_packages.common import file_digest, write_json
from native_packages.planning import validate_receipt
from native_packages.smoke import free_port, process_command, require, verify_linux_libraries


class Harness:
    def __init__(self, root, scratch, evidence, *, native=True):
        self.root, self.scratch, self.evidence = root, scratch, evidence
        self.native, self.counter = native, 0
        self.environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(scratch),
            "TMPDIR": str(scratch),
            "LC_ALL": "C",
        }
        if os.name == "nt":
            self.environment.update({key: os.environ[key] for key in ["SystemRoot", "WINDIR"]})
            self.environment["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")
            self.environment.update(TEMP=str(scratch), TMP=str(scratch))
        self.processes, self.logs = [], []

    def argv(self, arguments):
        return process_command(arguments) if self.native else list(map(str, arguments))

    def command(self, arguments, *, env=None, input=None):
        self.counter += 1
        result = subprocess.run(
            self.argv(arguments),
            cwd=self.scratch,
            env=self.environment | (env or {}),
            capture_output=True,
            text=True,
            input=input,
            timeout=90,
        )
        write_json(
            self.evidence / f"command-{self.counter}.json",
            {
                "argv": list(map(str, arguments)),
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            },
        )
        require(result.returncode == 0, result.stderr[-2000:])
        return result.stdout

    def start(self, arguments, *, env=None, cwd=None):
        log = (self.evidence / f"server-{len(self.logs)}.log").open("w")
        self.logs.append(log)
        process = subprocess.Popen(
            self.argv(arguments),
            cwd=cwd or self.scratch,
            env=self.environment | (env or {}),
            stdout=log,
            stderr=log,
        )
        self.processes.append(process)
        return process

    def stop(self, process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
                raise RuntimeError("Runtime failed to stop gracefully") from None

    def close(self):
        failures = []
        try:
            for process in self.processes:
                try:
                    self.stop(process)
                except RuntimeError as error:
                    failures.append(error)
        finally:
            for log in self.logs:
                log.close()
        if failures:
            raise ExceptionGroup("Runtimes failed to stop", failures)


def http(url, *, method="GET", document=None, headers=None):
    content = json.dumps(document).encode() if document is not None else None
    request = Request(
        url, data=content, method=method, headers={"Content-Type": "application/json", **(headers or {})}
    )
    with urlopen(request, timeout=10) as response:
        return json.load(response)


def wait_ready(process, check):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        require(process.poll() is None, "Server exited before becoming ready")
        try:
            result = check()
            if result:
                return result
        except (URLError, OSError, ValueError):
            pass
        time.sleep(0.2)
    raise RuntimeError("Server did not become ready")


def typesense(harness, package):
    executable = harness.root / "typesense-server"
    data = harness.scratch / "search data"
    data.mkdir()
    port = free_port()
    url = f"http://127.0.0.1:{port}"
    headers = {"X-TYPESENSE-API-KEY": "qualification-key"}
    args = [
        executable,
        "--data-dir",
        data,
        "--api-key=qualification-key",
        "--api-address=127.0.0.1",
        f"--api-port={port}",
    ]
    for iteration in range(2):
        process = harness.start(args)
        wait_ready(process, lambda: http(url + "/health").get("ok"))
        require(http(url + "/debug", headers=headers)["version"] == package["version"])
        if iteration == 0:
            http(
                url + "/collections",
                method="POST",
                headers=headers,
                document={"name": "books", "fields": [{"name": "title", "type": "string"}]},
            )
            http(
                url + "/collections/books/documents",
                method="POST",
                headers=headers,
                document={"id": "1", "title": "Fadogen relocation"},
            )
        found = http(url + "/collections/books/documents/search?q=relocation&query_by=title", headers=headers)
        require(found["found"] == 1 and found["hits"][0]["document"]["id"] == "1")
        harness.stop(process)


def garage(harness, package):
    executable = harness.root / "garage"
    require(package["version"] in harness.command([executable, "--version"]))
    port, rpc, admin = free_port(), free_port(), free_port()
    config = harness.scratch / "garage.toml"
    config.write_text(
        f'metadata_dir = "{harness.scratch}/meta"\ndata_dir = "{harness.scratch}/data"\n'
        f'db_engine = "sqlite"\nreplication_factor = 1\nrpc_secret = "{"a" * 64}"\n'
        f'rpc_bind_addr = "127.0.0.1:{rpc}"\nrpc_public_addr = "127.0.0.1:{rpc}"\n'
        f'[s3_api]\ns3_region = "garage"\napi_bind_addr = "127.0.0.1:{port}"\n'
        f'[admin]\napi_bind_addr = "127.0.0.1:{admin}"\n'
    )
    key, secret = "GK" + "1" * 32, "2" * 64
    environment = {
        "GARAGE_DEFAULT_ACCESS_KEY": key,
        "GARAGE_DEFAULT_SECRET_KEY": secret,
        "GARAGE_DEFAULT_BUCKET": "qualification",
    }
    marker = harness.scratch / "object.txt"
    marker.write_text("Fadogen relocated object\n")
    curl = [
        "/usr/bin/curl",
        "--fail",
        "--silent",
        "--show-error",
        "--max-time",
        "15",
        "--aws-sigv4",
        "aws:amz:garage:s3",
        "--user",
        f"{key}:{secret}",
    ]
    for iteration in range(2):
        process = harness.start(
            [executable, "-c", config, "server", "--single-node", "--default-bucket"], env=environment
        )
        wait_ready(process, lambda: urlopen(f"http://127.0.0.1:{admin}/health", timeout=2).close() or True)
        if iteration == 0:
            harness.command(
                [*curl, "--upload-file", marker, f"http://127.0.0.1:{port}/qualification/object.txt"]
            )
        content = harness.command([*curl, f"http://127.0.0.1:{port}/qualification/object.txt"])
        require(content == marker.read_text(), "Garage lost its S3 object after restart")
        harness.command([executable, "-c", config, "status"])
        harness.stop(process)


def composer(harness, package):
    php = os.environ.get("PHP_BINARY") or shutil.which("php")
    require(php, "PHP is required to qualify Composer")
    executable = harness.root / "composer"
    require(package["version"] in harness.command([php, executable, "--version"]))
    (harness.scratch / "composer.json").write_text(
        json.dumps(
            {
                "name": "fadogen/qualification",
                "description": "Package qualification",
                "license": "MIT",
                "require": {},
            }
        )
    )
    harness.command([php, executable, "validate", "--strict", "--no-check-publish"])
    harness.command(
        [php, executable, "install", "--no-interaction", "--no-plugins", "--no-scripts"],
        env={"COMPOSER_DISABLE_NETWORK": "1"},
    )


def sshpass(harness, package):
    executable = harness.root / "sshpass"
    require(package["version"] in harness.command([executable, "-V"]))
    # Exercise the controlling terminal and password prompt without an SSH
    # server, network access, or a real password.
    script = harness.scratch / "password prompt.sh"
    script.write_text(
        '#!/bin/sh\nstty -echo </dev/tty\nprintf "Password: " >/dev/tty\nread -r answer </dev/tty\n'
        '[ "$answer" = "qualification-password" ] && printf accepted\n'
    )
    script.chmod(0o755)
    require(
        "accepted"
        in harness.command([executable, "-e", "/bin/sh", script], env={"SSHPASS": "qualification-password"})
    )


def websocket(port):
    stream = socket.create_connection(("127.0.0.1", port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    stream.sendall(
        (
            f"GET /app/laravel-fadogen?protocol=7&client=js&version=8.4.0&flash=false HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    response = b""
    while not response.endswith(b"\r\n\r\n"):
        chunk = stream.recv(1)
        if not chunk:
            stream.close()
            raise ValueError("WebSocket closed before completing its upgrade")
        response += chunk
        require(len(response) < 16384, "Invalid WebSocket upgrade")
    require(b"101 Switching Protocols" in response, response.decode())
    expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
    )
    require(expected in response, "Invalid WebSocket accept key")
    return stream


def receive_frame(stream):
    def read(size):
        result = b""
        while len(result) < size:
            chunk = stream.recv(size - len(result))
            require(chunk, "WebSocket closed unexpectedly")
            result += chunk
        return result

    header = read(2)
    length = header[1] & 127
    if length == 126:
        length = struct.unpack("!H", read(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read(8))[0]
    require(header[0] & 15 == 1 and length < 65536, "Unexpected WebSocket frame")
    return json.loads(read(length))


def send_frame(stream, document):
    payload, mask = json.dumps(document).encode(), os.urandom(4)
    header = (
        bytes([0x81, 0x80 | len(payload)])
        if len(payload) < 126
        else bytes([0x81, 0xFE]) + struct.pack("!H", len(payload))
    )
    stream.sendall(header + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))


def reverb(harness, package):
    php = os.environ.get("PHP_BINARY") or shutil.which("php")
    require(php, "PHP is required to qualify Reverb")
    port = free_port()
    for _ in range(2):
        process = harness.start(
            [php, harness.root / "artisan", "reverb:start", "--host=127.0.0.1", f"--port={port}"],
            cwd=harness.root,
        )
        stream = wait_ready(process, lambda: websocket(port))
        with stream:
            require(receive_frame(stream)["event"] == "pusher:connection_established")
            send_frame(stream, {"event": "pusher:subscribe", "data": {"channel": "qualification"}})
            require(receive_frame(stream)["event"] == "pusher_internal:subscription_succeeded")
            body = json.dumps({"name": "probe", "channels": ["qualification"], "data": "relocated"}).encode()
            query = urlencode(
                {
                    "auth_key": "laravel-fadogen",
                    "auth_timestamp": str(int(time.time())),
                    "auth_version": "1.0",
                    "body_md5": hashlib.md5(body).hexdigest(),
                }
            )
            signature = hmac.new(
                b"secret", f"POST\n/apps/1001/events\n{query}".encode(), hashlib.sha256
            ).hexdigest()
            request = Request(
                f"http://127.0.0.1:{port}/apps/1001/events?{query}&auth_signature={signature}",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            with urlopen(request, timeout=10):
                pass
            require(receive_frame(stream)["event"] == "probe", "Reverb did not broadcast the event")
        harness.stop(process)


CHECKS = {
    "composer": composer,
    "garage": garage,
    "typesense": typesense,
    "sshpass": sshpass,
    "reverb": reverb,
}


def verify(package, receipt, output):
    validate_receipt(package, receipt, verified=False)
    output = Path(output).resolve()
    archive = output / receipt["filename"]
    require(file_digest(archive) == receipt["sha256"], "Final archive checksum mismatch")
    evidence = output / f"{package['id']}-evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    native = package["os"] != "any"
    with tempfile.TemporaryDirectory(prefix="Fadogen runtime qualification ") as temporary:
        scratch = Path(temporary)
        root = scratch / "first location"
        root.mkdir()
        if package["os"] == "windows":
            with zipfile.ZipFile(archive) as compressed:
                prefix = f"php-{package['version']}/"
                for member in compressed.namelist():
                    require(
                        member.startswith(prefix)
                        and ".." not in Path(member).parts
                        and "\\" not in member
                        and ":" not in member,
                        "Unsafe Windows PHP archive member",
                    )
                compressed.extractall(root)
            root = root / f"php-{package['version']}"
        else:
            with tarfile.open(archive) as compressed:
                compressed.extractall(root, filter="data")
        root = root.rename(scratch / "relocated runtime with spaces")
        harness = Harness(root, scratch, evidence, native=native)
        try:
            if native and platform.system() == "Linux":
                verify_linux_libraries(root, evidence)
            if package["service"] == "php":
                from .php_smoke import php

                php(harness, package)
            else:
                CHECKS[package["service"]](harness, package)
        finally:
            harness.close()
    require(file_digest(archive) == receipt["sha256"], "Archive changed during qualification")
    write_json(evidence / "result.json", {"passed": True, "sha256": receipt["sha256"], "relocated": True})
    return receipt | {"verified_sha256": receipt["sha256"]}
