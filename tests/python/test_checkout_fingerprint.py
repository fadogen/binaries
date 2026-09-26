"""Windows checkout settings must not change the frozen recipe fingerprint."""

import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY / ".github/scripts"))
from native_packages.common import file_digest


class CheckoutFingerprintTests(unittest.TestCase):
    def test_crlf_checkout_settings_preserve_recipe_bytes(self):
        files = [
            ".github/scripts/runtime_packages/php.py",
            ".github/scripts/native_packages/archive.py",
            ".github/scripts/entitlements-php.plist",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(
                [
                    "git",
                    "-c",
                    "core.autocrlf=true",
                    "-c",
                    "core.eol=crlf",
                    "checkout-index",
                    "--prefix=" + Path(temporary).as_posix() + "/",
                    "--",
                    *files,
                ],
                cwd=REPOSITORY,
                check=True,
            )
            for file in files:
                committed = subprocess.check_output(["git", "show", ":" + file], cwd=REPOSITORY)
                self.assertEqual(
                    hashlib.sha256(committed).hexdigest(), file_digest(Path(temporary) / file), file
                )


if __name__ == "__main__":
    unittest.main()
