"""Generated launchers preserve arguments and independent instance paths."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.launchers import install_launcher, patch_mariadb_installer


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="launchers with spaces ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "bin").mkdir()
        self.native = self.root / "Cellar/server/1/bin/server"
        self.native.parent.mkdir(parents=True)
        self.native.write_text('#!/bin/sh\nprintf "%s\\0" "$@"\n')
        self.native.chmod(0o755)
        self.data = self.root / "data with spaces"

    def invoke(self, service, *arguments):
        path = self.root / "bin/server"
        if not path.exists():
            install_launcher(self.root, path, self.native, service)
        return subprocess.check_output([str(path), *arguments]).decode().strip("\0").split("\0")

    def test_datadir_with_spaces_gets_a_private_socket_and_explicit_plugin_path(self):
        args = self.invoke("mariadb", "--datadir=" + str(self.data), "--port=3307")
        self.assertIn("--basedir=" + str(self.root), args)
        self.assertIn("--plugin-dir=" + str(self.root / "lib/plugin"), args)
        self.assertIn("--socket=" + str(self.data / "mariadb.sock"), args)
        self.assertEqual(args[-2:], ["--datadir=" + str(self.data), "--port=3307"])

    def test_no_defaults_stays_first_for_the_native_parser(self):
        args = self.invoke("mariadb", "--no-defaults", "--datadir", str(self.data))
        self.assertEqual(args[0], "--no-defaults")
        self.assertEqual(args.count("--no-defaults"), 1)
        self.assertIn("--socket=" + str(self.data / "mariadb.sock"), args)

    def test_user_socket_option_is_preserved_after_the_default(self):
        args = self.invoke("mariadb", "--datadir=" + str(self.data), "--socket=/tmp/selected.sock")
        self.assertEqual(args[-1], "--socket=/tmp/selected.sock")

    def test_mysql_initialization_keeps_its_exact_flag(self):
        args = self.invoke("mysql", "--initialize-insecure", "--datadir=" + str(self.data))
        self.assertIn("--initialize-insecure", args)
        self.assertIn("--mysqlx=OFF", args)

    def test_launcher_survives_moving_the_entire_package(self):
        self.invoke("mariadb", "--version")
        moved = self.root / "moved package"
        original = self.root / "bin/server"
        # Move the two package directories together, preserving only relative paths.
        moved.mkdir()
        (self.root / "bin").rename(moved / "bin")
        (self.root / "Cellar").rename(moved / "Cellar")
        args = subprocess.check_output([str(moved / "bin/server"), "--version"]).decode().split("\0")
        self.assertIn("--basedir=" + str(moved), args)
        self.assertFalse(original.exists())

    def test_installer_patch_is_guarded_against_upstream_drift(self):
        path = self.root / "mariadb-install-db"
        path.write_text("an unrelated future installer\n")
        with self.assertRaises(ValueError):
            patch_mariadb_installer(path)
        self.assertEqual(path.read_text(), "an unrelated future installer\n")


if __name__ == "__main__":
    unittest.main()
