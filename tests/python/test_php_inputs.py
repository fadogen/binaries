"""PHP builds must observe all source inputs and keep their exact planned release."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.common import write_json
from runtime_packages.php import (
    check_pinned_sources,
    download_arguments,
    download_environment,
    source_snapshot,
    supported_branches,
)


class PhpInputTests(unittest.TestCase):
    def test_php_download_uses_full_version_and_official_pinned_source(self):
        package = {
            "version": "8.5.10",
            "extensions": ["curl"],
            "shared_extensions": ["xdebug"],
            "components": [
                {"name": "php-src", "url": "https://www.php.net/distributions/php-8.5.10.tar.xz"},
                {"name": "xdebug", "url": "https://xdebug.org/files/xdebug-3.5.3.tgz"},
                {"name": "spc", "url": "https://github.com/crazywhalecc/static-php-cli/releases/spc.tar.gz"},
            ],
        }
        arguments = download_arguments("/test/spc", package)
        self.assertIn("--with-php=8.5.10", arguments)
        self.assertIn("--custom-url=php-src:https://www.php.net/distributions/php-8.5.10.tar.xz", arguments)
        self.assertIn("--custom-url=xdebug:https://xdebug.org/files/xdebug-3.5.3.tgz", arguments)
        self.assertEqual(sum(argument.startswith("--custom-url=") for argument in arguments), 2)
        self.assertIn("--ignore-cache-sources", arguments)
        self.assertIn("--prefer-pre-built", arguments)
        self.assertIn("--without-suggestions", arguments)
        self.assertIn("--shallow-clone", arguments)

    def test_spc_downloads_give_up_on_unreachable_hosts_before_the_step_timeout(self):
        with tempfile.TemporaryDirectory() as configuration:
            environment = download_environment({"os": "linux"}, configuration)
            self.assertEqual(environment["CURL_HOME"], configuration)
            self.assertEqual(environment["SPC_LIBC"], "glibc")
            self.assertEqual((Path(configuration) / ".curlrc").read_text(), "connect-timeout = 20\n")

    def test_downloaded_pinned_sources_must_match_their_planned_bytes(self):
        package = {
            "components": [
                {"name": "php-src", "sha256": "a" * 64},
                {"name": "xdebug", "sha256": "b" * 64},
                {"name": "spc", "sha256": "c" * 64},
            ]
        }
        planned = [
            {"name": "php-src", "sha256": "a" * 64},
            {"name": "xdebug", "sha256": "b" * 64},
            {"name": "libxml2", "sha256": "d" * 64},
        ]
        check_pinned_sources(package, planned)
        for sources in [
            [planned[0], {"name": "xdebug", "sha256": "e" * 64}, planned[2]],
            [planned[0], planned[2]],
        ]:
            with self.subTest(sources=sources), self.assertRaisesRegex(ValueError, "xdebug"):
                check_pinned_sources(package, sources)

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
