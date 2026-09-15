"""R2 failures cannot turn existing publication metadata into an empty catalog."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.storage import Store


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.store = Store("test-bucket", "https://storage.example.test")

    @patch("native_packages.storage.subprocess.run")
    def test_missing_metadata_starts_an_empty_catalog(self, invoke):
        invoke.return_value = subprocess.CompletedProcess([], 1, "", "An error occurred (NoSuchKey)")
        self.store.fetch_metadata(["linux-arm64"], self.directory)
        self.assertEqual((self.directory / "metadata-services-linux-arm64.json").read_text().strip(), "{}")

    @patch("native_packages.storage.subprocess.run")
    def test_access_failure_does_not_replace_the_existing_catalog(self, invoke):
        path = self.directory / "metadata-services-linux-arm64.json"
        path.write_text('{"keep": {}}')
        invoke.return_value = subprocess.CompletedProcess([], 1, "", "An error occurred (AccessDenied)")
        with self.assertRaises(RuntimeError):
            self.store.fetch_metadata(["linux-arm64"], self.directory)
        self.assertEqual(path.read_text(), '{"keep": {}}')

    @patch("native_packages.storage.subprocess.run")
    def test_unmodified_metadata_is_not_uploaded(self, invoke):
        path = self.directory / "metadata-services-linux-arm64.json"
        path.write_text("{}\n")
        path.with_suffix(".json.orig").write_text("{}\n")
        self.store.publish_metadata(self.directory)
        invoke.assert_not_called()


if __name__ == "__main__":
    unittest.main()
