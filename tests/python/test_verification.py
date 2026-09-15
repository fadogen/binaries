"""Reject packages that borrow libraries or mislabel Windows source archives."""

import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.smoke import check_linux_bindings
from native_packages.vendor import verify_windows


class VerificationTests(unittest.TestCase):
    def test_linux_resolution_allows_only_package_and_explicit_system_libraries(self):
        root = Path("/tmp/package with spaces")
        bindings = check_linux_bindings(
            root,
            "libssl.so.3 => /tmp/package with spaces/lib/libssl.so.3 (0x123)\nlibc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x456)\nlinux-vdso.so.1 (0x789)",
        )
        self.assertEqual(len(bindings), 2)
        for output in [
            "libssl.so.3 => not found",
            "libssl.so.3 => /usr/lib/libssl.so.3 (0x123)",
            "libc.so.6 => /home/linuxbrew/.linuxbrew/lib/libc.so.6 (0x123)",
        ]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                check_linux_bindings(root, output)

    def test_windows_source_zip_cannot_pass_for_native_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "redis.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("redis-8.10.1/README.md", "source")
            with self.assertRaisesRegex(ValueError, "executable"):
                verify_windows({"service": "redis", "version": "8.10.1"}, archive)

    def test_windows_pe_must_target_x64(self):
        with tempfile.TemporaryDirectory() as directory:
            for machine in [0x8664, 0xAA64]:
                archive = Path(directory) / f"{machine}.zip"
                header = bytearray(90)
                header[:2] = b"MZ"
                struct.pack_into("<I", header, 0x3C, 64)
                header[64:68] = b"PE\0\0"
                struct.pack_into("<H", header, 68, machine)
                with zipfile.ZipFile(archive, "w") as output:
                    for name in ["redis-server.exe", "redis-cli.exe"]:
                        output.writestr("redis-8.10.1/" + name, header)
                if machine == 0x8664:
                    self.assertEqual(
                        verify_windows({"service": "redis", "version": "8.10.1"}, archive)["tests"],
                        ["zip-integrity", "required-PE-x64-executables"],
                    )
                else:
                    with self.assertRaisesRegex(ValueError, "x64"):
                        verify_windows({"service": "redis", "version": "8.10.1"}, archive)
