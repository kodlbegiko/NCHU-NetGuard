import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("core_coverage", Path(__file__).resolve().parents[1] / "scripts/core_coverage.py")
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class CoverageTests(unittest.TestCase):
    def test_weighted_lines_missing_and_duplicate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources"
            source.mkdir()
            a, b = source / "A.swift", source / "B.swift"
            a.touch()
            b.touch()
            def row(path, count, covered):
                return {"filename": str(path), "summary": {"lines": {"count": count, "covered": covered}}}
            def report(*rows):
                return {"data": [{"files": list(rows)}]}
            one = coverage.summarize(root, report(row(a, 90, 90)))
            self.assertEqual(one["reported_line_coverage_percent"], 100)
            self.assertFalse(one["meets_target"])
            self.assertEqual(one["missing_sources"], ["Sources/B.swift"])
            both = coverage.summarize(root, report(row(a, 90, 90), row(b, 10, 0), row(root / "Tests.swift", 100, 0)))
            self.assertEqual(both["reported_line_coverage_percent"], 90)
            self.assertTrue(both["meets_target"])
            with self.assertRaises(ValueError):
                coverage.summarize(root, report(row(a, 90, 90), row(a, 90, 90)))
            with self.assertRaises(ValueError):
                coverage.summarize(root, report(row(a, 10, 11)))

    def test_only_verified_alias_file_may_be_omitted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources" / "NetGuardCore"
            source.mkdir(parents=True)
            app = source / "App.swift"
            app.touch()
            alias = source / "ModuleCompatibility.swift"
            alias.write_text("#if SWIFT_PACKAGE\nimport NetGuardTraffic\npublic typealias X = NetGuardTraffic.X\n#endif\n")
            report = {"data": [{"files": [{"filename": str(app), "summary": {"lines": {"count": 10, "covered": 9}}}]}]}
            result = coverage.summarize(root, report)
            self.assertTrue(result["meets_target"])
            self.assertEqual(result["verified_non_executable_sources"], ["Sources/NetGuardCore/ModuleCompatibility.swift"])
            alias.write_text(alias.read_text() + "\nfunc bypass() {}\n")
            self.assertFalse(coverage.summarize(root, report)["meets_target"])
