"""Execute the packaged PHP CLI and FPM/CGI, including their shared extensions."""

import json
import socket
import struct

from native_packages.smoke import free_port, require

from .smoke import wait_ready


def required_extensions(extensions):
    aliases = {"mbregex": "mbstring", "opcache": "zend opcache"}
    return {aliases.get(name, name).lower() for name in extensions}


def fastcgi_request(port, script):
    def record(kind, content):
        return struct.pack("!BBHHBB", 1, kind, 1, len(content), 0, 0) + content

    def encoded_length(length):
        return bytes([length]) if length < 128 else struct.pack("!I", length | 0x80000000)

    parameters = b""
    for name, value in {
        "REQUEST_METHOD": "GET",
        "SCRIPT_FILENAME": str(script),
        "SERVER_PROTOCOL": "HTTP/1.1",
        "GATEWAY_INTERFACE": "CGI/1.1",
    }.items():
        name, value = name.encode(), value.encode()
        parameters += encoded_length(len(name)) + encoded_length(len(value)) + name + value
    with socket.create_connection(("127.0.0.1", port), timeout=10) as stream:
        stream.sendall(
            record(1, struct.pack("!HB5x", 1, 0)) + record(4, parameters) + record(4, b"") + record(5, b"")
        )

        def read(size):
            data = b""
            while len(data) < size:
                chunk = stream.recv(size - len(data))
                require(chunk, "FPM closed before finishing the response")
                data += chunk
            return data

        stdout, stderr = b"", b""
        while True:
            version, kind, request, length, padding, _ = struct.unpack("!BBHHBB", read(8))
            require(version == 1 and request == 1, "Unexpected FastCGI response")
            content = read(length)
            read(padding)
            if kind == 6:
                stdout += content
            elif kind == 7:
                stderr += content
            elif kind == 3:
                require(content == b"\0" * 8 and not stderr, "FPM request failed: " + stderr.decode())
                break
            require(len(stdout) + len(stderr) < 1_000_000, "Unbounded FPM response")
    return parse_cgi(stdout.decode())


def parse_cgi(response):
    headers, separator, content = response.partition("\r\n\r\n")
    if not separator:
        headers, separator, content = response.partition("\n\n")
    require(separator and "Status: 500" not in headers, "Invalid CGI response: " + response[-2000:])
    return json.loads(content)


WINDOWS_EXTENSIONS = [
    "bz2",
    "curl",
    "dba",
    "enchant",
    "exif",
    "ffi",
    "fileinfo",
    "ftp",
    "gd",
    "gettext",
    "gmp",
    "intl",
    "ldap",
    "mbstring",
    "mysqli",
    "odbc",
    "openssl",
    "pdo_mysql",
    "pdo_odbc",
    "pdo_pgsql",
    "pdo_sqlite",
    "pgsql",
    "redis",
    "shmop",
    "soap",
    "sockets",
    "sodium",
    "sqlite3",
    "sysvshm",
    "tidy",
    "xsl",
    "zip",
]


def php(harness, package):
    windows = package["os"] == "windows"
    extension_dir = harness.root / ("ext" if windows else "extensions")
    options = ["-n", "-d", f"extension_dir={extension_dir}", "-d", "display_errors=stderr"]
    if windows:
        for extension in WINDOWS_EXTENSIONS:
            options += ["-d", f"extension={extension}"]
    options += ["-d", "zend_extension=xdebug"]
    cli = harness.root / ("php-cli.exe" if windows else "php-cli")
    probe = harness.scratch / "probe.php"
    probe.write_text(
        """<?php
header('Content-Type: application/json');
$database = new PDO('sqlite:"""
        + (harness.scratch / "persistent.sqlite").as_posix()
        + """');
$database->exec('CREATE TABLE IF NOT EXISTS proof (value TEXT)');
if (!$database->query('SELECT COUNT(*) FROM proof')->fetchColumn()) {
    $database->exec("INSERT INTO proof VALUES ('relocated')");
}
echo json_encode([
    'version' => PHP_VERSION,
    'extensions' => array_map('strtolower', get_loaded_extensions()),
    'xdebug' => phpversion('xdebug'),
    'redis' => phpversion('redis'),
    'database' => $database->query('SELECT value FROM proof')->fetchColumn(),
    'intl' => Normalizer::normalize("e\\u{0301}"),
    'sodium' => strlen(sodium_crypto_generichash('qualification')),
    'image' => imagepng(imagecreatetruecolor(2, 2), __DIR__.'/image.png'),
], JSON_THROW_ON_ERROR);
"""
    )
    expected = required_extensions(WINDOWS_EXTENSIONS if windows else package["extensions"]) | {"xdebug"}

    def check(result):
        require(result["version"] == package["version"], "PHP runtime version differs from the plan")
        missing = expected - set(result["extensions"])
        require(not missing, f"Missing loaded PHP extensions: {sorted(missing)}")
        require(
            result["database"] == "relocated"
            and result["intl"] == "é"
            and result["sodium"] == 32
            and result["image"]
        )
        for extension in ["xdebug", "redis"]:
            if extension in package:
                require(result[extension] == package[extension], f"Wrong {extension} version")

    check(json.loads(harness.command([cli, *options, probe])))
    if windows:
        for _ in range(2):
            response = harness.command(
                [harness.root / "php-cgi.exe", *options],
                env={
                    "REDIRECT_STATUS": "1",
                    "REQUEST_METHOD": "GET",
                    "SCRIPT_FILENAME": str(probe),
                },
            )
            check(parse_cgi(response))
    else:
        port = free_port()
        config = harness.scratch / "php-fpm.conf"
        config.write_text(
            "[global]\ndaemonize = no\nerror_log = /dev/stderr\n[qualification]\n"
            f"listen = 127.0.0.1:{port}\npm = static\npm.max_children = 1\ncatch_workers_output = yes\n"
        )
        for _ in range(2):
            process = harness.start([harness.root / "php-fpm", *options, "--fpm-config", config])
            result = wait_ready(process, lambda: fastcgi_request(port, probe))
            check(result)
            harness.stop(process)
