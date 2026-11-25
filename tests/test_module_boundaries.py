import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class ModuleBoundaryTests(unittest.TestCase):
    def test_every_core_source_has_one_owner(self):
        manifest = json.loads((ROOT / "docs/module-ownership.json").read_text())
        self.assertEqual(manifest["schema_version"], 1)
        paths = {p.name for p in (ROOT / "Sources").rglob("*.swift")}
        self.assertEqual(paths, set(manifest["core_owners"]))
        self.assertTrue(all(type(v) is int and 0 <= v <= 8 for v in manifest["core_owners"].values()))
        self.assertEqual(manifest["shared_paths"]["src/main.swift"], 0)

    def test_core_does_not_import_ui_frameworks(self):
        for path in (ROOT / "Sources").rglob("*.swift"):
            with self.subTest(path=path.name):
                self.assertIsNone(re.search(
                    r"^\s*(?:@\w+\s+)*import\s+(?:Cocoa|AppKit|SwiftUI|WebKit|UIKit)\b",
                    path.read_text(), re.MULTILINE))

    def test_probe_runner_is_only_core_process_launcher(self):
        for path in (ROOT / "Sources").rglob("*.swift"):
            if path.name == "ProbeRunner.swift":
                continue
            with self.subTest(path=path.name):
                self.assertIsNone(re.search(r"\bProcess\s*\(", path.read_text()))

    def test_swiftpm_target_membership_and_dependency_boundaries(self):
        manifest = json.loads((ROOT / "docs/module-ownership.json").read_text())
        paths = list((ROOT / "Sources").rglob("*.swift"))
        self.assertEqual(len(paths), len({p.name for p in paths}))
        self.assertEqual({p.name: p.parent.name for p in paths}, manifest["source_targets"])
        for path in paths:
            allowed = manifest["targets"][path.parent.name]
            for dependency in re.findall(r"^\s*import\s+(NetGuard\w+)\b", path.read_text(), re.MULTILINE):
                self.assertIn(dependency, allowed, f"{path.name}: {dependency}")
        package = (ROOT / "Package.swift").read_text()
        for target in manifest["targets"]:
            self.assertIn(f'.target(name: "{target}"', package)
            if target != "NetGuardCore":
                self.assertIn(f'.testTarget(name: "{target}Tests", dependencies: ["{target}"])', package)

    def test_package_dependency_graph_matches_manifest(self):
        manifest = json.loads((ROOT / "docs/module-ownership.json").read_text())
        package = (ROOT / "Package.swift").read_text()
        # Targets in the current manifest use explicit literal dependency arrays.
        declarations = re.findall(r'\.target\(name:\s*"([^"]+)"(?:,\s*dependencies:\s*\[([^\]]*)\])?', package)
        graph = {name: re.findall(r'"([^"]+)"', deps) for name, deps in declarations}
        self.assertEqual(len(declarations), len(graph), "duplicate target declarations")
        self.assertEqual(set(graph), set(manifest["targets"]))
        for name, dependencies in graph.items():
            self.assertEqual(len(dependencies), len(set(dependencies)))
            self.assertEqual(set(dependencies), set(manifest["targets"][name]))
        visiting, visited = set(), set()
        def visit(node):
            self.assertNotIn(node, visiting, "module dependency cycle")
            if node in visited:
                return
            visiting.add(node)
            for dependency in graph[node]:
                self.assertIn(dependency, graph)
                visit(dependency)
            visiting.remove(node)
            visited.add(node)
        for name in graph:
            visit(name)
