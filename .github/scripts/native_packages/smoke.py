"""Exercise a re-extracted runtime with the application's native command contract."""

import platform
import re
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

from .common import file_digest, run, write_json
from .relocate import SYSTEM_ELF, binary_files


def require(condition, message="Runtime result differs from the expected value"):
    if not condition:
        raise RuntimeError(message)


def check_linux_bindings(root, output):
    root = Path(root).resolve()
    if "not found" in output:
        raise ValueError("An ELF runtime dependency is missing: " + output)
    bindings = []
    for line in output.splitlines():
        match = re.search(r"(?:=>\s+|^\s*)(/.*?)\s+\(0x[0-9a-f]+\)", line)
        if match is None:
            continue
        path = Path(match[1]).resolve()
        if not path.is_relative_to(root):
            system = any(path.is_relative_to(base) for base in ["/lib", "/lib64", "/usr/lib", "/usr/lib64"])
            if not system or path.name not in SYSTEM_ELF:
                raise ValueError(f"ELF dependency is outside the package/system contract: {path}")
        bindings.append(str(path))
    return bindings


def verify_linux_libraries(root, evidence):
    records = []
    for path in binary_files(root, {b"\x7fELF"}):
        output = run(["ldd", path], env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        bindings = check_linux_bindings(root, output)
        records.append({"path": str(path.relative_to(root)), "libraries": bindings})
    write_json(evidence / "elf-libraries.json", records)


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def process_command(arguments):
    if platform.system() == "Darwin":
        policy = '(version 1)(allow default)(deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local") (subpath "/Users/Shared/Fadogen"))'
        return ["/usr/bin/sandbox-exec", "-p", policy, *map(str, arguments)]
    return list(map(str, arguments))


class Instance:
    def __init__(self, package, root, scratch, evidence, index):
        self.service = package["service"]
        self.root, self.scratch = root, scratch
        self.data = scratch / f"data {index}"
        self.data.mkdir()
        self.evidence = evidence / f"instance-{index}"
        self.evidence.mkdir(parents=True)
        self.port, self.tls_port = free_port(), free_port()
        self.marker = f"instance-{index}"
        self.process = None
        self.counter = 0
        self.environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(scratch),
            "LC_ALL": "C",
            "TMPDIR": str(scratch),
        }
        if self.service == "postgresql":
            self.environment["PGHOSTADDR"] = "127.0.0.1"
        self.cert = scratch / "cert.pem"
        self.key = scratch / "key.pem"
        self.database = "postgres" if self.service == "postgresql" else None

    def command(self, arguments, *, check=True, content=None, environment=None, label="command"):
        self.counter += 1
        stem = self.evidence / f"{self.counter:03d}-{label}"
        write_json(stem.with_suffix(".argv.json"), list(map(str, arguments)))
        result = subprocess.run(
            process_command(arguments),
            capture_output=True,
            text=True,
            input=content,
            env=self.environment | (environment or {}),
            cwd=self.scratch,
            timeout=60,
        )
        stem.with_suffix(".stdout").write_text(result.stdout)
        stem.with_suffix(".stderr").write_text(result.stderr)
        if check and result.returncode:
            raise RuntimeError(f"{self.service}: {label} failed: {result.stderr[-1500:]}")
        return result

    def client(self, executable=None, *, trusted=True):
        if self.service == "postgresql":
            return [
                self.root / "bin" / (executable or "psql"),
                "-h",
                "localhost",
                "-p",
                str(self.port),
                "-U",
                "root",
            ]
        if self.service in {"redis", "valkey"}:
            return [
                self.root / "bin" / f"{self.service}-cli",
                "-h",
                "127.0.0.1",
                "-p",
                str(self.tls_port),
                "--tls",
                "--cacert",
                self.cert if trusted else self.scratch / "other-cert.pem",
                "--raw",
                "-e",
            ]
        name = executable or ("mariadb" if self.service == "mariadb" else "mysql")
        arguments = [
            self.root / "bin" / name,
            "--no-defaults",
            "--default-character-set=utf8mb4",
            "--protocol=TCP",
            "--host=127.0.0.1",
            "--port=" + str(self.port),
            "--user=root",
        ]
        ca = self.cert if trusted else self.scratch / "other-cert.pem"
        arguments += (
            ["--ssl-verify-server-cert", "--ssl-ca=" + str(ca)]
            if self.service == "mariadb"
            else ["--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=" + str(ca)]
        )
        return arguments

    def query(self, sql, *, check=True, trusted=True):
        if self.service == "postgresql":
            env = {
                "PGSSLMODE": "verify-full",
                "PGSSLROOTCERT": str(self.cert if trusted else self.scratch / "other-cert.pem"),
            }
            args = [*self.client(), "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-d", self.database, "-c", sql]
            return self.command(args, check=check, environment=env, label="sql")
        return self.command(
            [*self.client(trusted=trusted), "--batch", "--skip-column-names", "-e", sql],
            check=check,
            label="sql",
        )

    def initialize(self):
        if self.service == "postgresql":
            self.command(
                [
                    self.root / "bin/initdb",
                    "-D",
                    self.data,
                    "-U",
                    "root",
                    "--auth-local=trust",
                    "--auth-host=trust",
                    "--locale=C",
                    "--encoding=UTF8",
                ],
                label="initialize",
            )
        elif self.service == "mariadb":
            self.command(
                [
                    self.root / "scripts/mariadb-install-db",
                    "--datadir=" + str(self.data),
                    "--basedir=" + str(self.root),
                    "--auth-root-authentication-method=normal",
                ],
                label="initialize",
            )
        elif self.service == "mysql":
            self.command(
                [self.root / "bin/mysqld", "--initialize-insecure", "--datadir=" + str(self.data)],
                label="initialize",
            )

    def start(self):
        if self.service == "postgresql":
            args = [
                self.root / "bin/postgres",
                "-D",
                self.data,
                "-p",
                str(self.port),
                "-h",
                "127.0.0.1",
                "-k",
                self.data,
                "-c",
                "ssl=on",
                "-c",
                "ssl_cert_file=" + str(self.cert),
                "-c",
                "ssl_key_file=" + str(self.key),
            ]
        elif self.service in {"mariadb", "mysql"}:
            executable = "mariadbd" if self.service == "mariadb" else "mysqld"
            args = [
                self.root / "bin" / executable,
                "--datadir=" + str(self.data),
                "--port=" + str(self.port),
                "--bind-address=127.0.0.1",
                "--ssl-ca=" + str(self.cert),
                "--ssl-cert=" + str(self.cert),
                "--ssl-key=" + str(self.key),
                "--require-secure-transport=ON",
            ]
        else:
            args = [
                self.root / "bin" / f"{self.service}-server",
                "--port",
                str(self.port),
                "--dir",
                self.data,
                "--bind",
                "127.0.0.1",
                "--appendonly",
                "yes",
                "--tls-port",
                str(self.tls_port),
                "--tls-cert-file",
                self.cert,
                "--tls-key-file",
                self.key,
                "--tls-ca-cert-file",
                self.cert,
                "--tls-auth-clients",
                "no",
            ]
            if self.service == "redis":
                modules = {path.name: path for path in (self.root / "lib").rglob("*.so")}
                for name in ["redisbloom.so", "redisearch.so", "redistimeseries.so", "rejson.so"]:
                    if name not in modules:
                        raise ValueError(f"Missing promised Redis module: {name}")
                    args += ["--loadmodule", modules[name]]
        self.counter += 1
        log = self.evidence / f"{self.counter:03d}-server.log"
        write_json(log.with_suffix(".argv.json"), list(map(str, args)))
        with log.open("wb") as output:
            self.process = subprocess.Popen(
                process_command(args),
                stdout=output,
                stderr=subprocess.STDOUT,
                cwd=self.data,
                env=self.environment,
            )
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"{self.service} exited during startup: {log.read_text()[-2000:]}")
            result = self.ping(check=False)
            if result.returncode == 0:
                return
            time.sleep(0.15)
        raise RuntimeError(f"{self.service} did not become ready: {log}")

    def ping(self, *, check=True, trusted=True):
        if self.service in {"redis", "valkey"}:
            return self.command([*self.client(trusted=trusted), "PING"], check=check, label="ping")
        return self.query("SELECT 1", check=check, trusted=trusted)

    def create_data(self):
        if self.service in {"redis", "valkey"}:
            self.command([*self.client(), "SET", "qualification", self.marker])
            self.command([*self.client(), "EVAL", "return 40 + 2", "0"])
            if self.service == "redis":
                for command in [
                    ["JSON.SET", "json", "$", '{"answer":42}'],
                    ["BF.ADD", "bloom", "value"],
                    ["TS.CREATE", "series"],
                    ["TS.ADD", "series", "1", "42"],
                    ["FT.CREATE", "search", "SCHEMA", "title", "TEXT"],
                ]:
                    self.command([*self.client(), *command])
                require("42" in self.command([*self.client(), "JSON.GET", "json"]).stdout)
            self.command([*self.client(), "SAVE"])
        else:
            self.query("CREATE DATABASE qualification")
            if self.service == "postgresql":
                self.database = "qualification"
                self.query(f"CREATE TABLE marker(value text); INSERT INTO marker VALUES ('{self.marker}')")
                self.query(
                    "CREATE EXTENSION hstore; CREATE EXTENSION pgcrypto; SELECT encode(digest('fadogen','sha256'),'hex')"
                )
                self.query("CREATE EXTENSION plperl; CREATE EXTENSION plperlu")
                self.query("CREATE FUNCTION answer() RETURNS integer LANGUAGE plperl AS $$ return 42; $$")
                require(self.query("SELECT answer()").stdout.strip() == "42")
                if platform.system() == "Darwin":
                    self.query("CREATE EXTENSION pltcl; CREATE EXTENSION pltclu")
                    self.query(
                        "CREATE FUNCTION tcl_answer() RETURNS integer LANGUAGE pltcl AS $$ return 42 $$"
                    )
                    require(self.query("SELECT tcl_answer()").stdout.strip() == "42")
            else:
                self.query(
                    f"CREATE TABLE qualification.marker(value VARCHAR(80)) ENGINE=InnoDB; INSERT INTO qualification.marker VALUES ('{self.marker}')"
                )
                if self.service == "mariadb":
                    self.query(
                        "INSTALL SONAME 'ha_mroonga'; CREATE TABLE qualification.mroonga(id INT PRIMARY KEY, value TEXT, "
                        "FULLTEXT INDEX(value) COMMENT 'tokenizer \"TokenMecab\"') ENGINE=Mroonga; "
                        "INSERT INTO qualification.mroonga VALUES (1,'test')"
                    )
                    if (self.root / "lib/plugin/ha_rocksdb.so").exists():
                        self.query(
                            "INSTALL SONAME 'ha_rocksdb'; CREATE TABLE qualification.rocks(id INT PRIMARY KEY, value VARCHAR(80)) ENGINE=RocksDB; INSERT INTO qualification.rocks VALUES (1,'test')"
                        )
            self.backup_restore()
        if self.ping(check=False, trusted=False).returncode == 0:
            raise RuntimeError("An unrelated certificate authority was accepted")
        self.verify_data()

    def backup_restore(self):
        if self.service == "postgresql":
            env = {"PGSSLMODE": "verify-full", "PGSSLROOTCERT": str(self.cert)}
            backup = self.command(
                [*self.client("pg_dump"), "qualification"], environment=env, label="dump"
            ).stdout
            self.query("CREATE DATABASE restored")
            self.command(
                [*self.client(), "-X", "-v", "ON_ERROR_STOP=1", "-d", "restored"],
                content=backup,
                environment=env,
                label="restore",
            )
        else:
            tool = "mariadb-dump" if self.service == "mariadb" else "mysqldump"
            options = ["--set-gtid-purged=OFF"] if self.service == "mysql" else []
            backup = self.command(
                [*self.client(tool), "--single-transaction", *options, "qualification"], label="dump"
            ).stdout
            self.query("CREATE DATABASE restored")
            self.command([*self.client(), "restored"], content=backup, label="restore")
        (self.evidence / "backup.sql").write_text(backup)

    def verify_data(self):
        if self.service in {"redis", "valkey"}:
            require(self.command([*self.client(), "GET", "qualification"]).stdout.strip() == self.marker)
            if self.service == "redis":
                require("42" in self.command([*self.client(), "JSON.GET", "json"]).stdout)
            return
        if self.service == "postgresql":
            for database in ["qualification", "restored"]:
                self.database = database
                require(self.query("SELECT value FROM marker").stdout.strip() == self.marker)
                require(self.query("SELECT answer()").stdout.strip() == "42")
                if platform.system() == "Darwin":
                    require(self.query("SELECT tcl_answer()").stdout.strip() == "42")
            self.database = "qualification"
        else:
            for database in ["qualification", "restored"]:
                require(self.query(f"SELECT value FROM {database}.marker").stdout.strip() == self.marker)
                if self.service == "mariadb":
                    require(self.query(f"SELECT value FROM {database}.mroonga").stdout.strip() == "test")
                    require(
                        self.query(
                            f"SELECT COUNT(*) FROM {database}.mroonga WHERE MATCH(value) AGAINST ('test')"
                        ).stdout.strip()
                        == "1"
                    )
                    if (self.root / "lib/plugin/ha_rocksdb.so").exists():
                        require(self.query(f"SELECT value FROM {database}.rocks").stdout.strip() == "test")
            paths = self.query("SELECT @@socket,@@plugin_dir").stdout.strip().split("\t")
            require(paths[0] == str(self.data / f"{self.service}.sock"))
            require(Path(paths[1]).resolve().is_relative_to(self.root))

    def stop(self):
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=25)
            except subprocess.TimeoutExpired as error:
                self.process.kill()
                self.process.wait(timeout=10)
                raise RuntimeError(f"{self.service} required a forced shutdown") from error
        if self.process.returncode not in {0, -15}:
            raise RuntimeError(f"{self.service} exited {self.process.returncode}")
        self.process = None


def certificates(scratch):
    config = scratch / "openssl.cnf"
    config.write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=localhost\n[extensions]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=critical,CA:TRUE\n"
    )
    for prefix in ["", "other-"]:
        result = subprocess.run(
            [
                "/usr/bin/openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-keyout",
                str(scratch / (prefix + "key.pem")),
                "-out",
                str(scratch / (prefix + "cert.pem")),
                "-config",
                str(config),
            ],
            capture_output=True,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.decode())
        (scratch / (prefix + "key.pem")).chmod(0o600)


def verify(package, archive, evidence):
    archive, evidence = Path(archive).resolve(), Path(evidence).resolve()
    if file_digest(archive) != package["sha256"]:
        raise ValueError("Archive changed before qualification")
    evidence.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="run-", dir=evidence))
    with tempfile.TemporaryDirectory(prefix="fadogen proof ", dir="/tmp") as directory:
        scratch = Path(directory).resolve()
        extracted = scratch / "first extraction"
        extracted.mkdir()
        with tarfile.open(archive) as source:
            source.extractall(extracted, filter="data")
        root = scratch / "relocated package é with spaces"
        (extracted / f"{package['service']}-{package['version']}").rename(root)
        extracted.rmdir()
        if platform.system() == "Linux":
            verify_linux_libraries(root, evidence)
        certificates(scratch)
        instances = [Instance(package, root, scratch, evidence, index) for index in range(2)]
        try:
            for instance in instances:
                instance.initialize()
                instance.start()
                instance.create_data()
            for index, instance in enumerate(instances):
                instance.stop()
                instances[1 - index].verify_data()
                instance.start()
                instance.verify_data()
                instances[1 - index].verify_data()
        finally:
            original_error = sys.exception()
            errors = []
            for instance in reversed(instances):
                try:
                    instance.stop()
                except RuntimeError as error:
                    errors.append(str(error))
            if errors:
                if original_error is not None:
                    original_error.add_note("Cleanup: " + "; ".join(errors))
                else:
                    raise RuntimeError("; ".join(errors))
    if file_digest(archive) != package["sha256"]:
        raise ValueError("Archive changed during qualification")
    report = {
        "archive_sha256": package["sha256"],
        "os": platform.system(),
        "arch": platform.machine(),
        "platform": platform.platform(),
        "verifier": file_digest(__file__),
        "tests": [
            "relocation-with-spaces",
            "initialization",
            "TLS",
            "unrelated-CA-rejected",
            "data-persistence",
            "two-instances",
            "restart",
        ],
        "homebrew_access": "denied by sandbox-exec"
        if platform.system() == "Darwin"
        else "all ELF dependencies checked against package/system allowlist",
        "pass": True,
    }
    write_json(evidence / "result.json", report)
    return report
