"""PHP builds must observe all source inputs and keep their exact planned release."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.common import write_json
from runtime_packages.php import download_arguments, source_snapshot, supported_branches


class PhpInputTests(unittest.TestCase):
    def test_php_download_uses_full_version_and_official_pinned_source(self):
        package = {
            "version": "8.5.10",
            "extensions": ["curl"],
            "shared_extensions": ["xdebug"],
            "components": [{"name": "php-src", "url": "https://www.php.net/distributions/php-8.5.10.tar.xz"}],
        }
        arguments = download_arguments("/test/spc", package)
        self.assertIn("--with-php=8.5.10", arguments)
        self.assertIn("--custom-url=php-src:https://www.php.net/distributions/php-8.5.10.tar.xz", arguments)
        self.assertIn("--ignore-cache-sources", arguments)
        self.assertIn("--prefer-pre-built", arguments)
        self.assertIn("--without-suggestions", arguments)
        self.assertIn("--no-alt", arguments)

    def test_invalid_upstream_support_cannot_retire_every_php_version(self):
        for response in [{}, {"8": {}}, {"8": {"supported_versions": []}}]:
            with self.subTest(response=response), self.assertRaises(ValueError):
                supported_branches(response, ["8.3", "8.4", "8.5"])
        self.assertEqual(
            supported_branches({"8": {"supported_versions": ["8.4", "8.5"]}}, ["8.3", "8.4", "8.5"]),
            ["8.4", "8.5"],
        )

    def test_source_byte_changes_are_detected_but_timestamps_are_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            downloads = Path(temporary)
            source = downloads / "sodium.tar.gz"
            source.write_bytes(b"old source")
            write_json(
                downloads / ".lock.json", {"libsodium": {"source_type": "archive", "filename": source.name}}
            )
            first = source_snapshot(downloads)
            source.touch()
            self.assertEqual(source_snapshot(downloads), first)
            source.write_bytes(b"patched source")
            self.assertNotEqual(source_snapshot(downloads), first)

    def test_source_lock_cannot_read_outside_downloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            downloads = Path(temporary)
            write_json(
                downloads / ".lock.json", {"php-src": {"source_type": "archive", "filename": "../private"}}
            )
            with self.assertRaises(ValueError):
                source_snapshot(downloads)


if __name__ == "__main__":
    unittest.main()
