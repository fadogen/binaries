"""Exercise FastCGI framing and the final PHP package contract without PHP installed."""

import socket
import struct
import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from runtime_packages.php_smoke import fastcgi_request, required_extensions


class PhpQualificationTests(unittest.TestCase):
    def test_fastcgi_executes_the_requested_script_and_collects_split_stdout(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        received = []

        def serve():
            with listener, listener.accept()[0] as stream:
                while True:
                    header = stream.recv(8, socket.MSG_WAITALL)
                    _, kind, request, length, padding, _ = struct.unpack("!BBHHBB", header)
                    received.append((kind, stream.recv(length, socket.MSG_WAITALL) if length else b""))
                    if padding:
                        stream.recv(padding, socket.MSG_WAITALL)
                    if kind == 5 and not length:
                        break
                for kind, content in [
                    (6, b"Content-Type: application/json\r\n\r\n"),
                    (6, b'{"ok":true}'),
                    (3, b"\0" * 8),
                ]:
                    stream.sendall(struct.pack("!BBHHBB", 1, kind, request, len(content), 0, 0) + content)

        server = threading.Thread(target=serve, daemon=True)
        server.start()
        try:
            result = fastcgi_request(listener.getsockname()[1], "/folder with spaces/check.php")
            self.assertEqual(result, {"ok": True})
            self.assertTrue(any(b"/folder with spaces/check.php" in content for _, content in received))
        finally:
            server.join(timeout=5)
        self.assertFalse(server.is_alive())

    def test_compile_options_are_mapped_to_actual_loaded_module_names(self):
        self.assertEqual(
            required_extensions(["mbregex", "mbstring", "opcache", "pdo_sqlsrv"]),
            {"mbstring", "zend opcache", "pdo_sqlsrv"},
        )


if __name__ == "__main__":
    unittest.main()
