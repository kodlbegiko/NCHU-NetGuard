import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import candidate_inventory as candidate


class CandidateInventoryTests(unittest.TestCase):
    def test_revision_must_be_exact_and_clean(self):
        sha = "a" * 40
        for outputs in (["b" * 40], [sha, " M README.md"], ["bad"]):
            with patch.object(candidate, "git", side_effect=outputs):
                with self.assertRaises(ValueError):
                    candidate.revision(sha)
        with patch.object(candidate, "git", side_effect=[sha, ""]):
            self.assertEqual(candidate.revision(sha), sha)

    def test_inventory_requires_matching_versions_and_never_authorizes_release(self):
        sha = "a" * 40
        a = {"sha256": "b" * 64, "bundle_short_version": "3.0", "bundle_build_version": None}
        b = dict(a, sha256="c" * 64)
        with patch.object(candidate, "revision", return_value=sha), patch.object(candidate, "describe", side_effect=[a,b]):
            report = candidate.collect(sha)
            self.assertFalse(report["release_authorized"])
            self.assertFalse(report["full_device_acceptance"])
            self.assertEqual(report["bundles"]["module"], b)
        with patch.object(candidate, "revision", return_value=sha), patch.object(candidate, "describe", side_effect=[a,dict(b,bundle_short_version="4.0")]):
            with self.assertRaises(ValueError):
                candidate.collect(sha)
