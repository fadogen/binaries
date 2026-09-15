"""Contracts for immutable package planning and partial publication."""

import sys
import unittest
from copy import deepcopy
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.homebrew import FormulaAPI, Unavailable, runtime_dependencies, select_bottle
from native_packages.planning import archive_name, fingerprint, make_matrix, merge_results, prune_metadata


def formula(name, version, *, deps=(), bottles=None, siblings=()):
    return {
        "name": name,
        "versions": {"stable": version},
        "revision": 0,
        "versioned_formulae": list(siblings),
        "dependencies": list(deps),
        "bottle": {
            "stable": {
                "files": bottles
                or {
                    "arm64_sonoma": {
                        "url": "https://ghcr.io/v2/homebrew/core/example/blobs/sha256:" + "a" * 64,
                        "sha256": "a" * 64,
                        "cellar": ":any",
                    }
                }
            }
        },
    }


def package(**changes):
    row = {
        "service": "redis",
        "major": "8",
        "version": "8.10.1",
        "os": "darwin",
        "arch": "arm64",
        "runner": "macos-26",
        "components": [{"name": "redis", "version": "8.10.1", "sha256": "a" * 64}],
        "packager": "b" * 64,
    }
    row.update(changes)
    row["deps"] = fingerprint(row)
    row["filename"] = archive_name(row, "c" * 64)
    return row


class HomebrewTests(unittest.TestCase):
    def test_resolves_highest_release_within_requested_major(self):
        api = FormulaAPI(
            documents={
                "mysql": formula("mysql", "26.7.0", siblings=["mysql@8.4", "mysql@8.0", "mysql@9.7"]),
                "mysql@8.4": formula("mysql@8.4", "8.4.11"),
                "mysql@8.0": formula("mysql@8.0", "8.0.47"),
                "mysql@9.7": formula("mysql@9.7", "9.7.2"),
            }
        )
        self.assertEqual(api.resolve("mysql", "8")["name"], "mysql@8.4")
        self.assertEqual(api.resolve("mysql", "9")["name"], "mysql@9.7")
        with self.assertRaises(Unavailable):
            api.resolve("mysql", "7")

    def test_runtime_closure_uses_target_variation_without_build_tools(self):
        doc = formula("server", "1.0", deps=["openssl@3"])
        doc.update(build_dependencies=["cmake"], uses_from_macos=[{"bison": "build"}, "perl"])
        doc["variations"] = {"arm64_linux": {"dependencies": ["openssl@3", "linux-pam"]}}
        self.assertEqual(runtime_dependencies(doc, "arm64_linux"), ["linux-pam", "openssl@3", "perl"])
        self.assertEqual(runtime_dependencies(doc, "arm64_sonoma"), ["openssl@3"])

    def test_missing_target_bottle_is_unavailable_not_a_source_build(self):
        doc = formula("server", "1.0")
        with self.assertRaises(Unavailable):
            select_bottle(doc, ["arm64_linux"])

    def test_architecture_independent_bottle_can_serve_a_target(self):
        doc = formula("data", "1", bottles={"all": {"sha256": "a" * 64, "url": "https://example.test/data"}})
        self.assertEqual(select_bottle(doc, ["arm64_linux"])[0], "all")

    def test_linux_plan_includes_only_the_implicit_compiler_runtime(self):
        bottles = {"arm64_linux": {"url": "https://example.test/bottle", "sha256": "a" * 64}}
        api = FormulaAPI(
            documents={
                "server": formula("server", "1", bottles=bottles),
                "gcc": formula("gcc", "16.2.0", deps=["gmp"], bottles=bottles),
            }
        )
        components = api.closure("server", ["arm64_linux"])
        compiler = next(item for item in components if item["name"] == "gcc")
        self.assertEqual(compiler["role"], "compiler-runtime")
        self.assertEqual(compiler["dependencies"], [])
        self.assertEqual({item["name"] for item in components}, {"server", "gcc"})

    def test_dependency_cycle_is_reported(self):
        api = FormulaAPI(
            documents={
                "a": formula("a", "1", deps=["b"]),
                "b": formula("b", "1", deps=["a"]),
            }
        )
        with self.assertRaisesRegex(ValueError, "cycle"):
            api.closure("a", ["arm64_sonoma"])


class PublicationTests(unittest.TestCase):
    def test_config_prunes_removed_targets_majors_services_and_exclusions(self):
        retained = {"latest": "8.0.1", "filename": "redis-8.0.1-darwin-arm64.tar.gz"}
        config = {
            "services": {"redis": ["8"], "valkey": ["9"]},
            "targets": [
                {"os": "darwin", "arch": "arm64"},
                {"os": "windows", "arch": "x86_64", "exclude": ["valkey"]},
            ],
        }
        metadata = {
            "darwin-arm64": {"redis": {"7": {}, "8": retained}, "mysql": {"8": {}}},
            "darwin-x86_64": {"redis": {"8": retained}},
            "windows-x86_64": {"valkey": {"9": {}}},
        }
        original = deepcopy(metadata)
        self.assertEqual(
            prune_metadata(metadata, config),
            {"darwin-arm64": {"redis": {"8": retained}}, "windows-x86_64": {}},
        )
        self.assertEqual(metadata, original)

    def test_filtered_or_unavailable_plan_does_not_remove_supported_catalogue_entries(self):
        built = package()
        config = {
            "services": {"redis": ["8"], "valkey": ["9"]},
            "targets": [{"os": "darwin", "arch": "arm64"}, {"os": "linux", "arch": "arm64"}],
        }
        retained = {"latest": "9.0.0", "filename": "valkey-9.0.0-linux-arm64.tar.gz"}
        old = {"linux-arm64": {"valkey": {"9": retained}}}
        after = prune_metadata(
            merge_results(old, [{**built, "sha256": "c" * 64, "verified_sha256": "c" * 64}], [built]),
            config,
        )
        self.assertEqual(after["linux-arm64"]["valkey"]["9"], retained)
        self.assertIn("redis", after["darwin-arm64"])

    def test_published_result_carries_original_plan_when_upstream_changes(self):
        built = package()
        result = {**built, "sha256": "c" * 64, "verified_sha256": "c" * 64}
        next_plan = package(components=[{"name": "redis", "version": "8.10.1", "sha256": "d" * 64}])
        metadata = merge_results({}, [result], [built])
        self.assertEqual(metadata["darwin-arm64"]["redis"]["8"]["deps"], built["deps"])
        self.assertNotEqual(built["deps"], next_plan["deps"])
        self.assertEqual(len(make_matrix([next_plan], metadata)), 1)

    def test_unrelated_homebrew_commit_does_not_rebuild_identical_bottles(self):
        first = package(
            components=[{"name": "redis", "version": "8.10.1", "sha256": "a" * 64, "formula_commit": "old"}]
        )
        second = package(
            components=[{"name": "redis", "version": "8.10.1", "sha256": "a" * 64, "formula_commit": "new"}]
        )
        self.assertEqual(first["deps"], second["deps"])

    def test_success_is_not_rebuilt_on_following_run(self):
        built = package()
        metadata = merge_results({}, [{**built, "sha256": "c" * 64, "verified_sha256": "c" * 64}], [built])
        self.assertEqual(make_matrix([built], metadata), [])

    def test_dependency_only_bottle_revision_triggers_new_immutable_archive(self):
        before = package()
        after = deepcopy(before)
        after["components"].append({"name": "openssl@3", "version": "3.6.4", "sha256": "d" * 64})
        after = package(components=after["components"])
        self.assertNotEqual(before["deps"], after["deps"])
        self.assertNotEqual(archive_name(before, "c" * 64), archive_name(after, "d" * 64))

    def test_partial_success_preserves_failed_and_unrelated_entries(self):
        built = package()
        old = {"darwin-arm64": {"mariadb": {"12": {"latest": "12.3.2", "filename": "old.tar.gz"}}}}
        expected_old = deepcopy(old)
        metadata = merge_results(old, [{**built, "sha256": "c" * 64, "verified_sha256": "c" * 64}], [built])
        self.assertEqual(metadata["darwin-arm64"]["mariadb"], old["darwin-arm64"]["mariadb"])
        self.assertEqual(old, expected_old)
        self.assertIn("redis", metadata["darwin-arm64"])

    def test_receipt_from_a_different_plan_is_rejected(self):
        expected = package()
        wrong = package(packager="d" * 64)
        with self.assertRaises(ValueError):
            merge_results({}, [{**wrong, "sha256": "c" * 64, "verified_sha256": "c" * 64}], [expected])

    def test_an_unverified_native_archive_cannot_be_published(self):
        built = package()
        with self.assertRaisesRegex(ValueError, "verified"):
            merge_results({}, [{**built, "sha256": "c" * 64}], [built])

    def test_verification_of_other_archive_bytes_is_rejected(self):
        built = package()
        with self.assertRaisesRegex(ValueError, "verified"):
            merge_results({}, [{**built, "sha256": "c" * 64, "verified_sha256": "d" * 64}], [built])

    def test_archive_key_changes_when_a_forced_rebuild_changes_signed_bytes(self):
        built = package()
        self.assertNotEqual(archive_name(built, "c" * 64), archive_name(built, "d" * 64))

    def test_empty_receipts_do_not_prune_existing_versions(self):
        old = {"linux-arm64": {"valkey": {"8": {"filename": "keep.tar.gz"}}}}
        self.assertEqual(merge_results(old, [], []), old)

    def test_force_rebuild_is_scoped_to_service_and_major(self):
        first, second = package(), package(service="mariadb", major="12", version="12.3.3")
        metadata = merge_results(
            {},
            [{**p, "sha256": "c" * 64, "verified_sha256": "c" * 64} for p in [first, second]],
            [first, second],
        )
        self.assertEqual(make_matrix([first, second], metadata, force=["redis@8"]), [first])


if __name__ == "__main__":
    unittest.main()
