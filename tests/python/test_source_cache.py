"""The HTTP cache cannot silently authorize stale or corrupted source bytes."""

import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from native_packages.common import file_digest
from runtime_packages.sources import SourceCache


def response(content):
    result = io.BytesIO(content)
    result.headers = {"ETag": '"release-object"'}
    return result


class SourceCacheTests(unittest.TestCase):
    url = "https://example.org/release.tar.gz"

    def test_validated_cache_uses_conditional_request_but_corruption_forces_refetch(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = SourceCache(temporary)
            with patch("runtime_packages.sources.urlopen", return_value=response(b"verified")):
                first = cache.source(self.url)
            self.assertEqual(
                len(list(Path(temporary).iterdir())), 2, "One object and one URL index; no duplicate body"
            )
            with patch(
                "runtime_packages.sources.urlopen",
                side_effect=HTTPError(self.url, 304, "unchanged", {}, None),
            ) as get:
                self.assertEqual(cache.source(self.url), first)
                self.assertEqual(get.call_args.args[0].get_header("If-none-match"), '"release-object"')
            (Path(temporary) / f"{first['sha256']}.tar.gz").write_bytes(b"corrupted")
            with patch("runtime_packages.sources.urlopen", return_value=response(b"verified")) as get:
                self.assertEqual(cache.source(self.url), first)
                self.assertIsNone(get.call_args.args[0].get_header("If-none-match"))

    def test_changed_official_checksum_is_checked_even_after_not_modified(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = SourceCache(temporary)
            with patch("runtime_packages.sources.urlopen", return_value=response(b"verified")):
                cache.source(self.url)
            with (
                patch(
                    "runtime_packages.sources.urlopen",
                    side_effect=HTTPError(self.url, 304, "unchanged", {}, None),
                ),
                self.assertRaises(ValueError),
            ):
                cache.source(self.url, expected="a" * 64)

    def test_checksum_failure_preserves_the_previous_valid_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = SourceCache(temporary)
            with patch("runtime_packages.sources.urlopen", return_value=response(b"verified")):
                first = cache.source(self.url)
            with (
                patch("runtime_packages.sources.urlopen", return_value=response(b"untrusted")),
                self.assertRaises(ValueError),
            ):
                cache.source(self.url, expected=first["sha256"])
            self.assertEqual(file_digest(Path(temporary) / f"{first['sha256']}.tar.gz"), first["sha256"])


if __name__ == "__main__":
    unittest.main()
