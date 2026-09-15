"""Filesystem and relocation contracts, independent of installed Homebrew."""

import hashlib
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.archive import create_archive, extract_bottle
from native_packages.download import Downloader
from native_packages.layout import dependency_target, expose_service, runtime_files


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="package tests with spaces ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def bottle(self, files):
        path = self.root / "bottle.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, data in files.items():
                item = tarfile.TarInfo(name)
                item.size = len(data)
                item.mode = 0o755
                archive.addfile(item, io.BytesIO(data))
        return path

    def test_bottle_preserves_versioned_keg_and_executable_mode(self):
        source = self.bottle({"demo/1.2_1/bin/demo": b"hello"})
        dest = self.root / "destination"
        keg = extract_bottle(source, dest, {"name": "demo", "version": "1.2", "revision": 1})
        self.assertEqual(keg, dest / "demo/1.2_1")
        self.assertEqual((keg / "bin/demo").read_bytes(), b"hello")
        self.assertEqual((keg / "bin/demo").stat().st_mode & 0o777, 0o755)

    def test_unused_init_system_link_is_not_installed_into_the_app_package(self):
        source = self.root / "with-init-link.tar.gz"
        with tarfile.open(source, "w:gz") as archive:
            binary = tarfile.TarInfo("mariadb/12.3.3/bin/mariadbd")
            binary.size = 6
            archive.addfile(binary, io.BytesIO(b"server"))
            link = tarfile.TarInfo("mariadb/12.3.3/bin/rcmysql")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../../../etc/init.d/mysql"
            archive.addfile(link)
        keg = extract_bottle(
            source, self.root / "Cellar", {"name": "mariadb", "version": "12.3.3", "revision": 0}
        )
        self.assertTrue((keg / "bin/mariadbd").exists())
        self.assertFalse((keg / "bin/rcmysql").is_symlink())

    def test_wrong_upstream_version_cannot_be_labelled_as_requested_version(self):
        source = self.bottle({"demo/1.1/bin/demo": b"hello"})
        with self.assertRaises(ValueError):
            extract_bottle(
                source, self.root / "destination", {"name": "demo", "version": "1.2", "revision": 0}
            )

    def test_archive_is_reproducible_and_links_survive_reextraction(self):
        tree = self.root / "tree"
        (tree / "bin").mkdir(parents=True)
        (tree / "bin/real").write_bytes(b"payload")
        (tree / "bin/real").chmod(0o755)
        (tree / "bin/alias").symlink_to("real")
        first, second = self.root / "one.tar.gz", self.root / "two.tar.gz"
        create_archive(tree, first, "demo-1.2")
        create_archive(tree, second, "demo-1.2")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with tarfile.open(first) as archive:
            archive.extractall(self.root / "extracted", filter="data")
        alias = self.root / "extracted/demo-1.2/bin/alias"
        self.assertTrue(alias.is_symlink())
        self.assertEqual(alias.read_bytes(), b"payload")

    def test_dependency_resolution_keeps_libraries_with_identical_names_distinct(self):
        locations = {name: self.root / "Cellar" / name / "1.0" for name in ["one", "two"]}
        for location in locations.values():
            (location / "lib").mkdir(parents=True)
            (location / "lib/libcommon.dylib").touch()
        first = dependency_target("@@HOMEBREW_PREFIX@@/opt/one/lib/libcommon.dylib", locations)
        second = dependency_target("/opt/homebrew/Cellar/two/1.0/lib/libcommon.dylib", locations)
        self.assertNotEqual(first, second)
        self.assertEqual(first, locations["one"] / "lib/libcommon.dylib")

    def test_postgresql_shared_prefix_can_refer_to_libpq_outside_the_extension_folder(self):
        keg = self.root / "Cellar/postgresql@14/14.23"
        (keg / "lib/postgresql").mkdir(parents=True)
        (keg / "lib/libpq.5.dylib").touch()
        (keg / "lib/postgresql/hstore.so").touch()
        locations = {"postgresql@14": keg}
        self.assertEqual(
            dependency_target("@@HOMEBREW_PREFIX@@/lib/postgresql@14/libpq.5.dylib", locations),
            keg / "lib/libpq.5.dylib",
        )
        self.assertEqual(
            dependency_target("@@HOMEBREW_PREFIX@@/lib/postgresql@14/hstore.so", locations),
            keg / "lib/postgresql/hstore.so",
        )

    def test_unresolved_application_dependency_fails_instead_of_using_host_brew(self):
        with self.assertRaises(ValueError):
            dependency_target("/opt/homebrew/opt/missing/lib/x.dylib", {})
        self.assertIsNone(dependency_target("/usr/lib/libSystem.B.dylib", {}))

    def test_runtime_selection_keeps_extensions_and_licenses_but_drops_build_artifacts(self):
        self.assertTrue(runtime_files(Path("lib/postgresql/hstore.so")))
        self.assertTrue(runtime_files(Path("share/postgresql/extension/hstore.control")))
        self.assertTrue(runtime_files(Path("COPYING")))
        self.assertFalse(runtime_files(Path("include/server.h")))
        self.assertFalse(runtime_files(Path("lib/libpq.a")))
        self.assertFalse(runtime_files(Path("share/man/man1/server.1")))
        self.assertFalse(runtime_files(Path("mysql-test/test.sql")))

    def test_postgresql_layout_preserves_compiled_relative_share_and_lib_paths(self):
        keg = self.root / "Cellar/postgresql@18/18.6"
        for suffix in ["bin", "lib/postgresql", "share/postgresql"]:
            (keg / suffix).mkdir(parents=True)
        (keg / "bin/postgres").touch()
        expose_service(self.root, "postgresql", "postgresql@18", keg)
        self.assertEqual((self.root / "bin/postgres").resolve(), keg / "bin/postgres")
        self.assertEqual((self.root / "share/postgresql@18").resolve(), keg / "share/postgresql")
        self.assertEqual((self.root / "lib/postgresql@18").resolve(), keg / "lib/postgresql")

    def test_redis_modules_have_the_execute_bit_required_by_the_server(self):
        keg = self.root / "Cellar/redis/8.10.1"
        (keg / "bin").mkdir(parents=True)
        module = keg / "lib/redis/modules/rejson.so"
        module.parent.mkdir(parents=True)
        module.write_bytes(b"module")
        module.chmod(0o644)
        expose_service(self.root, "redis", "redis", keg)
        self.assertEqual(module.stat().st_mode & 0o111, 0o111)

    def test_download_rejects_corruption_and_does_not_keep_partial_content(self):
        source = self.root / "source"
        source.write_bytes(b"changed")
        downloader = Downloader(self.root / "cache")
        with self.assertRaises(ValueError):
            downloader.fetch(source.as_uri(), hashlib.sha256(b"expected").hexdigest())
        self.assertEqual(list((self.root / "cache").glob("*")), [])

    def test_versioned_ghcr_repository_uses_its_complete_token_scope(self):
        content = b"verified bottle"
        sha = hashlib.sha256(content).hexdigest()
        url = f"https://ghcr.io/v2/homebrew/core/postgresql/18/blobs/sha256:{sha}"
        with patch(
            "native_packages.download.urlopen",
            side_effect=[io.BytesIO(b'{"token":"anonymous"}'), io.BytesIO(content)],
        ) as request:
            path = Downloader(self.root / "cache").fetch(url, sha)
        self.assertIn(
            "repository%3Ahomebrew%2Fcore%2Fpostgresql%2F18%3Apull", request.call_args_list[0].args[0]
        )
        self.assertEqual(path.read_bytes(), content)

    def test_cached_download_is_reverified(self):
        source = self.root / "source"
        source.write_bytes(b"correct")
        downloader = Downloader(self.root / "cache")
        sha = hashlib.sha256(b"correct").hexdigest()
        path = downloader.fetch(source.as_uri(), sha)
        path.write_bytes(b"broken")
        self.assertEqual(downloader.fetch(source.as_uri(), sha).read_bytes(), b"correct")


if __name__ == "__main__":
    unittest.main()
