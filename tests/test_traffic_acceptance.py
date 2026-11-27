import copy
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("traffic_acceptance", Path(__file__).resolve().parents[1] / "scripts/traffic_acceptance.py")
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class ControlledTrafficTests(unittest.TestCase):
    def setUp(self):
        self.document = {"schema_version": 1,
                         "reference": {"boundary": "physicalWire", "observation_id": "fixture-1",
                                       "interface_id": "fixture-nic", "source_id": "reference",
                                       "complete": True, "received": 10000, "sent": 0},
                         "observed": {"boundary": "physicalWire", "observation_id": "fixture-1",
                                      "interface_id": "fixture-nic", "source_id": "monitor",
                                      "complete": True, "received": 10100, "sent": 0}}

    def test_directional_exact_threshold_and_zero(self):
        self.assertTrue(acceptance.evaluate(self.document)["meets_numeric_target"])
        self.document["observed"]["received"] = 10101
        self.assertFalse(acceptance.evaluate(self.document)["meets_numeric_target"])
        self.document["observed"]["received"] = 10000
        self.document["observed"]["sent"] = 1
        self.assertFalse(acceptance.evaluate(self.document)["meets_numeric_target"])

    def test_reject_mismatched_boundary_source_interval_and_incomplete(self):
        for key, value in [("boundary", "socketPayload"), ("observation_id", "other"), ("interface_id", "other"),
                           ("source_id", "reference"), ("complete", False), ("received", True), ("sent", -1)]:
            document = copy.deepcopy(self.document)
            document["observed"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                acceptance.evaluate(document)
