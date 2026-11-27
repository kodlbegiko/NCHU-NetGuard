import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ContractRegistryTests(unittest.TestCase):
    def test_registry_matches_v1_golden_contracts(self):
        registry = json.loads((ROOT / "docs/contracts/registry-v1.json").read_text())
        self.assertEqual(registry["schema_version"], 1)
        self.assertEqual(registry["status"], "freeze-candidate-not-approved")
        contracts = registry["contracts"]
        fixture_source = (ROOT / "Tests/NetGuardCoreTests/ContractCompatibilityTests.swift").read_text()
        fixtures = dict(re.findall(r'try verify\((\w+)\.self, #"(\{[^\n]+\})"#\)', fixture_source))
        self.assertEqual(set(fixtures), set(contracts))
        self.assertEqual(len(contracts), 8)
        for name, spec in contracts.items():
            with self.subTest(contract=name):
                fixture = json.loads(fixtures[name])
                required, optional = set(spec["required_fields"]), set(spec["optional_fields"])
                self.assertFalse(required & optional)
                self.assertEqual(fixture["schemaVersion"], spec["wire_version"])
                self.assertTrue(required <= set(fixture) <= required | optional)
                if spec["interface_fields"]:
                    for row in fixture["interfaces"]:
                        self.assertEqual(set(row), set(spec["interface_fields"]))
                self.assertIn("public struct " + name + ":", (ROOT / spec["source"]).read_text())
                validator = (ROOT / spec["validator"]).read_text()
                self.assertIn("extension " + name + ": ValidatedContract", validator)
                self.assertIn("func " + spec["golden_test"] + "()", fixture_source)
                self.assertEqual(spec["approval"], "pending")
                self.assertTrue(spec["semantics"])

    def test_production_contract_reference_inventory(self):
        registry = json.loads((ROOT / "docs/contracts/consumer-registry-v1.json").read_text())
        contracts = json.loads((ROOT / "docs/contracts/registry-v1.json").read_text())["contracts"]
        self.assertEqual(registry["schema_version"], 1)
        self.assertEqual(set(registry["contracts"]), set(contracts))
        actual = {name: [] for name in contracts}
        paths = sorted(list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "src").rglob("*.swift")))
        for path in paths:
            source = path.read_text()
            for name in contracts:
                if re.search(r"\b" + re.escape(name) + r"\b", source):
                    actual[name].append(path.relative_to(ROOT).as_posix())
        self.assertEqual(actual, registry["contracts"], "Update inventory and review contract consumers")
