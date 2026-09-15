"""Publication uses the complete remote catalogue even with a filtered local plan."""

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import chdir, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / ".github/scripts"
sys.path.insert(0, str(SCRIPTS))
from native_packages.common import read_json, write_json
from test_planning import package
from test_storage import MemoryStore, catalogue_key, entry

spec = importlib.util.spec_from_file_location("package_services", SCRIPTS / "package-services.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class CommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.config = self.directory / "services.json"
        write_json(
            self.config,
            {
                "services": {"redis": ["8"]},
                "targets": [{"os": "darwin", "arch": "arm64"}, {"os": "linux", "arch": "arm64"}],
            },
        )
        write_json(self.directory / "plan.json", {"packages": [package()]})
        (self.directory / "receipts").mkdir()

    def invoke(self, arguments):
        with chdir(self.directory), patch.object(cli, "CONFIG", self.config), redirect_stdout(io.StringIO()):
            args = cli.parser().parse_args(arguments)
            args.handler(args)

    def test_publication_reads_all_remote_targets_despite_an_incomplete_local_directory(self):
        retained = "redis-8.0.1-linux-arm64.tar.gz"
        remote = MemoryStore(
            {
                catalogue_key("darwin-arm64"): "{}",
                catalogue_key("linux-arm64"): json.dumps({"redis": {"8": entry(retained)}}),
                retained: "archive",
            }
        )
        incomplete = self.directory / catalogue_key("darwin-arm64")
        write_json(incomplete, {})
        with patch.object(cli, "store", return_value=remote):
            self.invoke(["publish-metadata", "--plan", "plan.json", "--receipts", "receipts"])
        self.assertIn(retained, remote.objects)
        self.assertEqual(remote.get_counts[catalogue_key("linux-arm64")], 2)
        self.assertEqual(read_json(incomplete), {})
        self.assertFalse((self.directory / catalogue_key("linux-arm64")).exists())

    def test_publication_requires_both_plan_and_receipts(self):
        for arguments in [["publish-metadata"], ["publish-metadata", "--plan", "plan.json"]]:
            with (
                self.subTest(arguments=arguments),
                redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit),
            ):
                cli.parser().parse_args(arguments)

    def test_a_missing_receipt_directory_is_an_error_before_remote_access(self):
        remote = MemoryStore({})
        with (
            patch.object(cli, "store", return_value=remote),
            self.assertRaisesRegex(ValueError, "Receipt directory"),
        ):
            self.invoke(["publish-metadata", "--plan", "plan.json", "--receipts", "missing"])
        self.assertEqual(remote.calls, [])

    def test_local_preview_prunes_scope_without_remote_access(self):
        keep = entry("redis-8.0.1-linux-arm64.tar.gz")
        write_json(self.directory / catalogue_key("linux-arm64"), {"redis": {"7": {}, "8": keep}})
        retired = self.directory / catalogue_key("darwin-x86_64")
        write_json(retired, {"redis": {"8": keep}})
        with patch.object(cli, "store") as remote:
            self.invoke(["update-metadata", "--plan", "plan.json", "--receipts", "receipts"])
        remote.assert_not_called()
        self.assertFalse(retired.exists())
        self.assertEqual(read_json(self.directory / catalogue_key("linux-arm64")), {"redis": {"8": keep}})


if __name__ == "__main__":
    unittest.main()
