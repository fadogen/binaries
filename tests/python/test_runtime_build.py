"""Portable PHP packaging must work with the CLI's relative, content-addressed cache."""

import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import chdir
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from runtime_packages.build import assemble_runtime
from runtime_packages.planning import packager_digest


class RuntimeBuildTests(unittest.TestCase):
    def test_reverb_installer_runs_as_a_phar_after_changing_into_the_source_tree(self):
        with tempfile.TemporaryDirectory() as temporary, chdir(temporary):
            cache, source = Path(".cache"), Path("source/app")
            cache.mkdir()
            for name in ["app", "bootstrap/cache", "config", "routes", "storage", "vendor"]:
                (source / name).mkdir(parents=True, exist_ok=True)
            for name in ["artisan", "composer.json", "composer.lock", "LICENSE"]:
                (source / name).write_text("{}")
            # The downloader stores every verified object under a .tar.gz name.
            cached = cache / f"{'b' * 64}.tar.gz"
            cached.write_text("verified installer")
            with tarfile.open(cache / "reverb.tar.gz", "w:gz") as archive:
                archive.add(source, arcname="app")
            package = {
                "service": "reverb",
                "engine": "composer",
                "packager": packager_digest(),
                "components": [
                    {"name": "reverb", "url": "source", "sha256": "a" * 64},
                    {"name": "composer", "url": "installer", "sha256": "b" * 64},
                ],
            }

            def install(arguments, *, cwd, check):
                installer = Path(cwd) / arguments[1]
                self.assertEqual(installer.suffix, ".phar")
                self.assertEqual(installer.read_text(), "verified installer")
                return subprocess.CompletedProcess(arguments, 0)

            with (
                patch(
                    "runtime_packages.build.Downloader.fetch",
                    side_effect=[cache / "reverb.tar.gz", cached],
                ),
                patch("runtime_packages.build.shutil.which", return_value="/usr/bin/php"),
                patch("runtime_packages.build.subprocess.run", side_effect=install),
            ):
                assemble_runtime(package, Path("result"), cache)
            self.assertTrue(Path("result/artisan").is_file())
            self.assertTrue(Path("result/LICENSE").is_file())


if __name__ == "__main__":
    unittest.main()
