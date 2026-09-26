"""Upstream source selection rejects malformed, incompatible and unverified inputs."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from runtime_packages.sources import composer_release, stable_release, windows_php_source


class SourceTests(unittest.TestCase):
    def test_composer_uses_latest_stable_not_lts_or_preview(self):
        versions = {
            "stable": [
                {"version": "2.2.30", "path": "/download/2.2.30/composer.phar", "lts": True},
                {"version": "2.10.3", "path": "/download/2.10.3/composer.phar"},
            ],
            "preview": [{"version": "3.0.0-beta1"}],
        }
        self.assertEqual(composer_release(versions)["version"], "2.10.3")

    def test_composer_unexpected_url_cannot_redirect_downloads(self):
        with self.assertRaises(ValueError):
            composer_release({"stable": [{"version": "2.10.3", "path": "https://other.test/code"}]})

    def test_github_release_must_be_stable_and_numeric(self):
        self.assertEqual(stable_release({"tag_name": "v30.2", "draft": False, "prerelease": False}), "30.2")
        for value in ["30.2-beta1", "../bad", None]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                stable_release({"tag_name": value})
        with self.assertRaises(ValueError):
            stable_release({"tag_name": "v30.2", "prerelease": True})

    def test_windows_php_uses_manifest_url_checksum_and_abi(self):
        archive = {"path": "php-8.5.10-nts-Win32-vs17-x64.zip", "sha256": "a" * 64}
        releases = {"8.5": {"version": "8.5.10", "nts-vs17-x64": {"zip": archive}}}
        source = windows_php_source(releases, "8.5")
        self.assertEqual(source["sha256"], "a" * 64)
        self.assertEqual(source["abi"], "vs17")
        self.assertTrue(source["url"].endswith(archive["path"]))

    def test_windows_missing_checksum_or_ambiguous_abi_is_an_error(self):
        bad = {"8.5": {"version": "8.5.10", "nts-vs17-x64": {"zip": {"path": "php.zip"}}}}
        with self.assertRaises(ValueError):
            windows_php_source(bad, "8.5")


if __name__ == "__main__":
    unittest.main()
