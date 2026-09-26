"""Publication must preserve successful runtimes and refuse ambiguous storage state."""

import sys
import unittest
from copy import deepcopy
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.planning import archive_name, fingerprint
from runtime_packages.catalogues import catalogue_name, merge_catalogues, selected_packages


def package(service="composer", *, os="any", arch="any", major="2", version="2.10.3"):
    result = {
        "service": service,
        "major": major,
        "version": version,
        "os": os,
        "arch": arch,
        "packager": "a" * 64,
        "engine": "vendor",
        "components": [{"name": service, "sha256": "b" * 64}],
    }
    result["deps"] = fingerprint(result)
    return result


def receipt(row):
    return row | {
        "sha256": "c" * 64,
        "verified_sha256": "c" * 64,
        "filename": archive_name(row, "c" * 64),
    }


class RuntimeCatalogueTests(unittest.TestCase):
    def test_catalogues_keep_the_application_contract(self):
        composer, reverb = package(), package("reverb")
        sshpass = package("sshpass", os="darwin", arch="arm64", version="1.10")
        php = package("php", os="linux", arch="arm64", major="8.5", version="8.5.10")
        php["releaseDate"] = "27 Aug 2026"
        rows = [composer, reverb, sshpass, php]
        result = merge_catalogues({}, [receipt(row) for row in rows], rows)
        self.assertEqual(result["metadata-composer.json"]["latest"], "2.10.3")
        self.assertEqual(result["metadata-reverb.json"]["reverb"]["latest"], "2.10.3")
        self.assertEqual(result["metadata-sshpass-darwin-arm64.json"]["version"], "1.10")
        self.assertEqual(result["metadata-php-linux-arm64.json"]["8.5"]["latest"], "8.5.10")

    def test_same_version_changed_input_is_selected(self):
        row = package()
        metadata = merge_catalogues({}, [receipt(row)], [row])
        self.assertEqual(selected_packages([row], metadata), [])
        changed = deepcopy(row)
        changed["components"][0]["sha256"] = "d" * 64
        changed["deps"] = fingerprint(changed)
        self.assertEqual(selected_packages([changed], metadata), [changed])

    def test_partial_success_keeps_other_platforms(self):
        mac = package("garage", os="darwin", arch="arm64")
        linux = package("garage", os="linux", arch="arm64")
        previous = merge_catalogues({}, [receipt(linux)], [linux])
        result = merge_catalogues(previous, [receipt(mac)], [mac, linux])
        self.assertEqual(result[catalogue_name(linux)], previous[catalogue_name(linux)])
        self.assertIn(catalogue_name(mac), result)

    def test_tampered_and_duplicate_receipts_are_rejected_before_merging(self):
        row = package()
        for changes in ({"deps": "d" * 64}, {"verified_sha256": "d" * 64}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                merge_catalogues({}, [receipt(row) | changes], [row])
        with self.assertRaises(ValueError):
            merge_catalogues({}, [receipt(row), receipt(row)], [row])

    def test_unavailable_source_does_not_delete_published_package(self):
        previous = {"metadata-garage-linux-arm64.json": {"latest": "2.3.0", "filename": "old.tar.gz"}}
        self.assertEqual(merge_catalogues(previous, [], []), previous)

    def test_php_retires_unsupported_branch_but_keeps_failed_supported_build(self):
        row = package("php", os="linux", arch="arm64", major="8.5", version="8.5.10")
        row["releaseDate"] = "27 Aug 2026"
        previous = {
            catalogue_name(row): {"8.2": {"filename": "retired.zip"}, "8.5": {"filename": "keep.zip"}}
        }
        self.assertEqual(
            merge_catalogues(previous, [], [row]), {catalogue_name(row): {"8.5": {"filename": "keep.zip"}}}
        )

    def test_php_receipt_binds_dependency_snapshot_to_global_plan(self):
        from runtime_packages.php import resolved_package

        row = package("php", os="linux", arch="arm64", major="8.5", version="8.5.10")
        row.update(engine="spc", releaseDate="27 Aug 2026")
        resolved = resolved_package(row, [{"name": "libsodium", "sha256": "d" * 64}])
        result = merge_catalogues({}, [receipt(resolved)], [row])
        self.assertEqual(result[catalogue_name(row)]["8.5"]["deps"], resolved["deps"])
        with self.assertRaises(ValueError):
            merge_catalogues({}, [receipt(resolved) | {"sources": []}], [row])


if __name__ == "__main__":
    unittest.main()
