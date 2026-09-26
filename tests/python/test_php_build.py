"""Linux PHP packages carry the host libraries that distributions do not all install."""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from runtime_packages.php import bundle_host_libraries


class PhpBuildTests(unittest.TestCase):
    def test_libcrypt_travels_in_the_installed_extensions_with_its_notice(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, host = Path(temporary) / "root", Path(temporary) / "host"
            for directory in [root / "extensions", root / "license", host]:
                directory.mkdir(parents=True)
            (root / "php-cli").write_bytes(b"\x7fELF cli")
            (root / "extensions/xdebug.so").write_bytes(b"\x7fELF xdebug")
            (host / "libcrypt.so.1.1.0").write_bytes(b"\x7fELF libxcrypt")
            (host / "libcrypt.so.1").symlink_to("libcrypt.so.1.1.0")
            (host / "copyright").write_text("libxcrypt notice")
            needed = {"php-cli": "libcrypt.so.1\nlibc.so.6\n", "xdebug.so": "libc.so.6\n"}

            def run(arguments):
                if arguments[0] == "patchelf":
                    return needed[Path(arguments[-1]).name]
                self.assertEqual(arguments, ["gcc", "-print-file-name=libcrypt.so.1"])
                return f"{host / 'libcrypt.so.1'}\n"

            with (
                patch("runtime_packages.php.run", side_effect=run),
                patch.dict(
                    "runtime_packages.php.HOST_ELF", {"libcrypt.so.1": ("libxcrypt", host / "copyright")}
                ),
            ):
                bundle_host_libraries(root)
            library = root / "extensions/libcrypt.so.1"
            self.assertFalse(library.is_symlink())
            self.assertEqual(library.read_bytes(), b"\x7fELF libxcrypt")
            self.assertEqual((root / "license/libxcrypt.copyright").read_text(), "libxcrypt notice")

    def test_packages_without_host_dependencies_stay_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for directory in [root / "extensions", root / "license"]:
                directory.mkdir()
            (root / "php-cli").write_bytes(b"\x7fELF cli")
            with patch("runtime_packages.php.run", return_value="libc.so.6\nlibm.so.6\n"):
                bundle_host_libraries(root)
            self.assertEqual(
                sorted(path.name for path in root.rglob("*")), ["extensions", "license", "php-cli"]
            )


if __name__ == "__main__":
    unittest.main()
