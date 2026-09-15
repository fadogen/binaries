"""R2 failures cannot turn existing publication metadata into an empty catalog."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.storage import Store
from test_planning import package


def catalogue_key(target):
    return f"metadata-services-{target}.json"


def entry(filename):
    return {"latest": "8.0.1", "sha256": "a" * 64, "filename": filename, "deps": "old"}


class MemoryStore(Store):
    """Exercise the real Store orchestration against an in-memory S3 endpoint."""

    def __init__(self, objects):
        super().__init__("test-bucket", "https://storage.example.test")
        self.objects = dict(objects)
        self.calls = []
        self.deleted_batches = []
        self.get_counts = {}
        self.get_failures = {}
        self.failed_upload = None
        self.failed_list_page = None
        self.delete_error = None
        self.list_override = None
        self.on_list = None

    def invoke(self, arguments):
        self.calls.append(arguments)
        operation = arguments[1]

        def option(name):
            return arguments[arguments.index(name) + 1]

        def success(value):
            return subprocess.CompletedProcess(arguments, 0, json.dumps(value), "")

        if operation == "get-object":
            key = option("--key")
            self.get_counts[key] = self.get_counts.get(key, 0) + 1
            failure = self.get_failures.get((key, self.get_counts[key]))
            if failure or key not in self.objects:
                return subprocess.CompletedProcess(arguments, 1, "", failure or "(NoSuchKey)")
            Path(arguments[-1]).write_text(self.objects[key])
            return success({})
        if operation == "put-object":
            key = option("--key")
            if key == self.failed_upload:
                return subprocess.CompletedProcess(arguments, 1, "", "(AccessDenied)")
            self.objects[key] = Path(option("--body")).read_text()
            return success({})
        if operation == "list-objects-v2":
            if self.on_list:
                self.on_list()
            start = int(option("--continuation-token")) if "--continuation-token" in arguments else 0
            if start == self.failed_list_page:
                return subprocess.CompletedProcess(arguments, 1, "", "(AccessDenied)")
            if self.list_override is not None:
                return success(self.list_override)
            keys = sorted(self.objects)
            response = {
                "Contents": [{"Key": key} for key in keys[start : start + 1000]],
                "IsTruncated": start + 1000 < len(keys),
            }
            if response["IsTruncated"]:
                response["NextContinuationToken"] = str(start + 1000)
            return success(response)
        if operation == "delete-objects":
            request = json.loads(Path(option("--delete").removeprefix("file://")).read_text())
            keys = [item["Key"] for item in request["Objects"]]
            self.deleted_batches.append(keys)
            for key in keys:
                if key != self.delete_error:
                    self.objects.pop(key, None)
            errors = [{"Key": self.delete_error, "Code": "AccessDenied"}] if self.delete_error in keys else []
            return success(
                {"Deleted": [{"Key": key} for key in keys if key != self.delete_error], "Errors": errors}
            )
        raise AssertionError(f"Unexpected S3 operation: {arguments}")


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "services": {
                "redis": ["8"],
                "valkey": ["9"],
                "mariadb": ["12"],
                "mysql": ["8"],
                "postgresql": ["18"],
            },
            "targets": [
                {"os": "darwin", "arch": "arm64"},
                {"os": "linux", "arch": "arm64"},
                {"os": "windows", "arch": "x86_64", "exclude": ["valkey"]},
            ],
        }
        self.old = "redis-8.0.1-darwin-arm64.tar.gz"
        self.keep = "valkey-9.0.0-linux-arm64.tar.gz"
        self.store = MemoryStore(
            {
                catalogue_key("darwin-arm64"): json.dumps({"redis": {"8": entry(self.old)}}),
                catalogue_key("linux-arm64"): json.dumps({"valkey": {"9": entry(self.keep)}}),
                catalogue_key("windows-x86_64"): "{}",
                self.old: "archive",
                self.keep: "archive",
            }
        )

    def reconcile(self, *, replacement=False):
        built = package()
        result = {**built, "sha256": "c" * 64, "verified_sha256": "c" * 64}
        if replacement:
            self.store.objects[built["filename"]] = "new archive already published"
        return self.store.reconcile_metadata(self.config, [built], [result] if replacement else [])

    def test_success_replaces_the_archive_and_keeps_the_other_platform(self):
        self.reconcile(replacement=True)
        self.assertNotIn(self.old, self.store.objects)
        self.assertIn(self.keep, self.store.objects)
        self.assertIn(package()["filename"], self.store.objects)
        self.assertEqual(
            json.loads(self.store.objects[catalogue_key("linux-arm64")]),
            {"valkey": {"9": entry(self.keep)}},
        )

    def test_empty_receipts_keep_the_supported_package_when_its_replacement_failed(self):
        self.reconcile()
        self.assertIn(self.old, self.store.objects)
        self.assertIn(self.keep, self.store.objects)
        self.assertEqual(self.store.deleted_batches, [])

    def test_removed_major_and_excluded_service_are_pruned_before_their_archives(self):
        retired = "postgresql-17.6-linux-arm64.tar.gz"
        excluded = "valkey-9.0.0-windows-x86_64.zip"
        self.store.objects[catalogue_key("linux-arm64")] = json.dumps(
            {"valkey": {"9": entry(self.keep)}, "postgresql": {"17": entry(retired)}}
        )
        self.store.objects[catalogue_key("windows-x86_64")] = json.dumps({"valkey": {"9": entry(excluded)}})
        self.store.objects.update({retired: "archive", excluded: "archive"})
        self.reconcile()
        self.assertNotIn(retired, self.store.objects)
        self.assertNotIn(excluded, self.store.objects)
        self.assertEqual(json.loads(self.store.objects[catalogue_key("windows-x86_64")]), {})

    def test_old_target_catalogue_is_deleted_before_its_unreferenced_archive(self):
        old_target = catalogue_key("darwin-x86_64")
        retired = "redis-8.0.1-darwin-x86_64.tar.gz"
        self.store.objects.update(
            {old_target: json.dumps({"redis": {"8": entry(retired)}}), retired: "archive"}
        )
        self.reconcile()
        self.assertNotIn(old_target, self.store.objects)
        self.assertNotIn(retired, self.store.objects)
        self.assertIn(old_target, self.store.deleted_batches[0])
        self.assertNotIn(retired, self.store.deleted_batches[0])

    def test_archive_referenced_by_a_retained_catalogue_survives_retired_target_cleanup(self):
        old_target = catalogue_key("darwin-x86_64")
        self.store.objects[old_target] = json.dumps({"valkey": {"9": entry(self.keep)}})
        self.reconcile()
        self.assertNotIn(old_target, self.store.objects)
        self.assertIn(self.keep, self.store.objects)

    def test_cleanup_only_recognizes_exact_service_archive_and_catalogue_names(self):
        removable = {
            "mariadb-10.11.14-darwin-x86_64.tar.gz",
            "mysql-8.4.7-linux-x86_64.tar.gz",
            "postgresql-14.19-windows-x86_64.zip",
            f"redis-8.0.1-{'a' * 16}-linux-arm64.tar.gz",
            f"valkey-9.0.0-{'b' * 64}-darwin-arm64.tar.gz",
        }
        protected = {
            "php-8.4.13-darwin-arm64.tar.gz",
            "composer.phar",
            "metadata-php-darwin-x86_64.json",
            "metadata-services-backup.json",
            "metadata-services-darwin-x86_64.json.orig",
            "redis-notes-linux-arm64.tar.gz",
            "redis-8.0.1-linux-arm64.tar.gz.bak",
            "foreign/redis-8.0.1-linux-arm64.tar.gz",
            "redis-cli-8.0.1-linux-arm64.tar.gz",
            "redis-8.0.1-windows-x86_64.tar.gz",
            "redis-8.0.1-darwin-arm64.zip",
            "redis-٨.٠.١-linux-arm64.tar.gz",
            f"redis-8.0.1-{'a' * 17}-linux-arm64.tar.gz",
        }
        self.store.objects.update(dict.fromkeys(removable | protected, "foreign or archive bytes"))
        self.reconcile()
        self.assertTrue(removable.isdisjoint(self.store.objects))
        self.assertTrue(protected.issubset(self.store.objects))

    def test_listing_is_paginated_and_deletions_are_batched_at_1000_keys(self):
        obsolete = {f"redis-8.0.{number}-linux-arm64.tar.gz" for number in range(2005)}
        self.store.objects.update(dict.fromkeys(obsolete, "archive"))
        self.reconcile()
        listed = [call for call in self.store.calls if call[1] == "list-objects-v2"]
        self.assertEqual(len(listed), 3)
        self.assertTrue(all("--no-paginate" in call for call in listed))
        self.assertEqual([len(batch) for batch in self.store.deleted_batches], [1000, 1000, 5])
        self.assertTrue(obsolete.isdisjoint(self.store.objects))
        self.assertIn(self.old, self.store.objects)
        self.assertIn(self.keep, self.store.objects)

    def test_any_metadata_upload_failure_prevents_all_deletion(self):
        self.store.objects[catalogue_key("windows-x86_64")] = json.dumps({"valkey": {"9": entry(self.keep)}})
        self.store.failed_upload = catalogue_key("windows-x86_64")
        with self.assertRaises(RuntimeError):
            self.reconcile(replacement=True)
        self.assertEqual(self.store.deleted_batches, [])
        self.assertIn(self.old, self.store.objects)

    def test_listing_failure_after_an_earlier_page_prevents_all_deletion(self):
        self.store.objects.update(
            {f"redis-8.0.{number}-linux-arm64.tar.gz": "archive" for number in range(1005)}
        )
        self.store.failed_list_page = 1000
        with self.assertRaises(RuntimeError):
            self.reconcile()
        self.assertEqual(self.store.deleted_batches, [])

    def test_malformed_truncated_listing_prevents_all_deletion(self):
        self.store.list_override = {"Contents": [{"Key": self.old}], "IsTruncated": True}
        with self.assertRaises((RuntimeError, ValueError)):
            self.reconcile(replacement=True)
        self.assertEqual(self.store.deleted_batches, [])

    def test_initial_read_failure_prevents_all_deletion(self):
        self.store.get_failures[(catalogue_key("linux-arm64"), 1)] = "(AccessDenied)"
        with self.assertRaises(RuntimeError):
            self.reconcile(replacement=True)
        self.assertEqual(self.store.deleted_batches, [])

    def test_valid_receipt_with_a_missing_published_archive_prevents_all_deletion(self):
        built = package()
        receipt = {**built, "sha256": "c" * 64, "verified_sha256": "c" * 64}
        with self.assertRaisesRegex(RuntimeError, "missing"):
            self.store.reconcile_metadata(self.config, [built], [receipt])
        self.assertEqual(self.store.deleted_batches, [])
        self.assertIn(self.old, self.store.objects)

    def test_missing_catalogue_is_published_even_when_it_is_empty(self):
        missing = catalogue_key("windows-x86_64")
        del self.store.objects[missing]
        self.reconcile()
        self.assertEqual(json.loads(self.store.objects[missing]), {})

    def test_absent_or_unreadable_final_catalogue_prevents_all_deletion(self):
        objects = dict(self.store.objects)
        for failure in ["(NoSuchKey)", "(AccessDenied)"]:
            with self.subTest(failure=failure):
                self.store = MemoryStore(objects)
                self.store.get_failures[(catalogue_key("linux-arm64"), 2)] = failure
                with self.assertRaises(RuntimeError):
                    self.reconcile(replacement=True)
                self.assertEqual(self.store.deleted_batches, [])
                self.assertIn(self.old, self.store.objects)

    def test_remote_catalogues_are_reloaded_before_cleanup_and_divergence_refuses_it(self):
        changed = catalogue_key("linux-arm64")
        self.store.on_list = lambda: self.store.objects.update({changed: "{}"})
        with self.assertRaisesRegex(RuntimeError, "changed"):
            self.reconcile(replacement=True)
        self.assertGreaterEqual(self.store.get_counts[changed], 2)
        self.assertEqual(self.store.deleted_batches, [])

    def test_malformed_retained_catalogue_refuses_cleanup(self):
        self.store.objects[catalogue_key("linux-arm64")] = json.dumps({"valkey": {"9": {"latest": "9.0.0"}}})
        with self.assertRaises(ValueError):
            self.reconcile(replacement=True)
        self.assertEqual(self.store.deleted_batches, [])

    def test_partial_delete_error_is_a_failure_and_preserves_archives_when_catalogue_delete_fails(self):
        old_target = catalogue_key("darwin-x86_64")
        retired = "redis-8.0.1-darwin-x86_64.tar.gz"
        self.store.objects.update({old_target: "{}", retired: "archive"})
        self.store.delete_error = old_target
        with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
            self.reconcile()
        self.assertIn(retired, self.store.objects)
        self.assertEqual(self.store.deleted_batches, [[old_target]])

    def test_published_catalogues_require_cache_revalidation(self):
        self.reconcile(replacement=True)
        uploads = [call for call in self.store.calls if call[1] == "put-object"]
        self.assertTrue(uploads)
        self.assertTrue(all(call[call.index("--cache-control") + 1] == "no-cache" for call in uploads))


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
