import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import verify_lifecycle_candidate as lifecycle


class LifecycleStateTests(unittest.TestCase):
    def test_exact_pair_required_for_recovery(self):
        self.assertEqual(lifecycle.observed_state("old", "new", "old", "new"), "original")
        self.assertEqual(lifecycle.observed_state("new", "old", "old", "new"), "exchanged")
        for active, retained in (("old", "old"), ("new", "new"), ("changed", "old"),
                                 ("new", "changed"), (None, "old")):
            self.assertEqual(lifecycle.observed_state(active, retained, "old", "new"), "conflict")
        self.assertEqual(lifecycle.observed_state("old", "old", "old", "old"), "conflict")
