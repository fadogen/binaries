"""The shared transport never turns a failed read into a new runtime catalogue."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from runtime_packages.catalogues import catalogue_name, merge_catalogues
from runtime_packages.storage import reconcile
from test_runtime_catalogues import package, receipt
from test_storage import MemoryStore


class RuntimeStorageTests(unittest.TestCase):
    def test_publish_keeps_failed_target_and_deletes_only_retired_runtime_archives(self):
        mac = package("garage", os="darwin", arch="arm64")
        linux = package("garage", os="linux", arch="arm64")
        old = "garage-2.3.0-darwin-arm64.tar.gz"
        keep = "garage-2.3.0-linux-arm64.tar.gz"
        store = MemoryStore(
            {
                catalogue_name(mac): json.dumps({"latest": "2.3.0", "filename": old}),
                catalogue_name(linux): json.dumps({"latest": "2.3.0", "filename": keep}),
                old: "old",
                keep: "keep",
                receipt(mac)["filename"]: "new",
                "garage-notes.tar.gz": "notes",
                "postgresql-18.0-darwin-arm64.tar.gz": "other service",
            }
        )
        reconcile(store, [mac, linux], [receipt(mac)], tools=["garage"])
        self.assertNotIn(old, store.objects)
        self.assertIn(keep, store.objects)
        self.assertIn("garage-notes.tar.gz", store.objects)
        self.assertIn("postgresql-18.0-darwin-arm64.tar.gz", store.objects)

    def test_failed_readback_never_deletes_old_archives(self):
        row = package()
        name = catalogue_name(row)
        store = MemoryStore({name: "{}", "composer-2.10.2.tar.gz": "old", receipt(row)["filename"]: "new"})
        store.get_failures[(name, 2)] = "(AccessDenied)"
        with self.assertRaises(RuntimeError):
            reconcile(store, [row], [receipt(row)], tools=["composer"])
        self.assertEqual(store.deleted_batches, [])

    def test_missing_uploaded_archive_prevents_metadata_switch(self):
        row = package()
        store = MemoryStore({catalogue_name(row): "{}"})
        with self.assertRaisesRegex(RuntimeError, "missing"):
            reconcile(store, [row], [receipt(row)], tools=["composer"])
        self.assertFalse(any(call[1] == "put-object" for call in store.calls))

    def test_unchanged_catalogue_has_no_upload(self):
        row = package()
        after = merge_catalogues({}, [receipt(row)], [row])
        store = MemoryStore(
            {catalogue_name(row): json.dumps(after[catalogue_name(row)]), receipt(row)["filename"]: "archive"}
        )
        reconcile(store, [row], [], tools=["composer"])
        self.assertFalse(any(call[1] == "put-object" for call in store.calls))

    def test_access_denied_preserves_local_catalogue(self):
        name = "metadata-composer.json"
        store = MemoryStore({name: '{"latest":"2.10.2"}'})
        store.get_failures[(name, 1)] = "(AccessDenied)"
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / name
            destination.write_text('{"keep":true}')
            with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
                store.fetch_catalogues([name], temporary)
            self.assertEqual(destination.read_text(), '{"keep":true}')

    def test_only_missing_key_creates_an_empty_catalogue(self):
        store = MemoryStore({})
        name = "metadata-reverb.json"
        with tempfile.TemporaryDirectory() as temporary:
            store.fetch_catalogues([name], temporary)
            self.assertEqual((Path(temporary) / name).read_text().strip(), "{}")
            with self.assertRaises(RuntimeError):
                store.fetch_catalogues([name], temporary, require_existing=True)


if __name__ == "__main__":
    unittest.main()
