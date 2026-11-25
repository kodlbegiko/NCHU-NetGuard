import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class ModuleBoundaryTests(unittest.TestCase):
    def test_every_core_source_has_one_owner(self):
        manifest = json.loads((ROOT / "docs/module-ownership.json").read_text())
        self.assertEqual(manifest["schema_version"], 1)
        paths = {p.name for p in (ROOT / "Sources/NetGuardCore").glob("*.swift")}
        self.assertEqual(paths, set(manifest["core_owners"]))
        self.assertTrue(all(type(v) is int and 0 <= v <= 8 for v in manifest["core_owners"].values()))
        self.assertEqual(manifest["shared_paths"]["src/main.swift"], 0)

    def test_core_does_not_import_ui_frameworks(self):
        for path in (ROOT / "Sources/NetGuardCore").glob("*.swift"):
            with self.subTest(path=path.name):
                self.assertIsNone(re.search(
                    r"^\s*(?:@\w+\s+)*import\s+(?:Cocoa|AppKit|SwiftUI|WebKit|UIKit)\b",
                    path.read_text(), re.MULTILINE))

    def test_probe_runner_is_only_core_process_launcher(self):
        for path in (ROOT / "Sources/NetGuardCore").glob("*.swift"):
            if path.name == "ProbeRunner.swift":
                continue
            with self.subTest(path=path.name):
                self.assertIsNone(re.search(r"\bProcess\s*\(", path.read_text()))
