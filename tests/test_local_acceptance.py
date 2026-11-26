import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/acceptance"))
import run_all as runner
import soak_test as soak

class LocalAcceptanceTests(unittest.TestCase):
    def test_exit_never_treats_inconclusive_or_dirty_as_pass(self):
        self.assertEqual(runner.automatic_exit([runner.row("a", "pass", "exit")], True), 0)
        self.assertEqual(runner.automatic_exit([runner.row("a", "pass", "exit")], False), 2)
        for state in ("inconclusive", "blocked", "skipped"):
            self.assertEqual(runner.automatic_exit([runner.row("a", state, "test")], True), 2)
        self.assertEqual(runner.automatic_exit([runner.row("a", "fail", "exit")], True), 1)
        self.assertEqual(runner.automatic_exit([], True), 2)

    def test_runner_logs_and_checks_marker_and_exit(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "logs").mkdir()
            def step(id, code, **kw):
                return runner.run_step(out, id, [sys.executable, "-c", code], 5, **kw)
            ok = step("ok", "print('OK')", marker="OK")
            self.assertEqual(ok["status"], "pass")
            self.assertEqual(len(ok["log_sha256"]), 64)
            self.assertEqual(step("marker", "print('NOT OK')", marker="OK")["status"], "inconclusive")
            self.assertEqual(step("unknown", "raise SystemExit(2)", inconclusive_codes=(2,))["status"], "inconclusive")
            self.assertEqual(step("bad", "raise SystemExit(1)")["status"], "fail")
            timeout = runner.run_step(out, "timeout", [sys.executable, "-c", "import time; time.sleep(5)"], .1)
            self.assertEqual(timeout["reason"], "timeout")

    def test_private_report_is_atomic_and_numeric_targets_are_strict(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "metrics.json"
            data = {"average_cpu_percent_one_core": .49, "max_rss_bytes": 79_999_999,
                    "duration_seconds": 60, "samples": 13}
            runner.write_json(path, data)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertTrue(runner.performance_result(path)["meets_numeric_target"])
            data["average_cpu_percent_one_core"] = .5
            runner.write_json(path, data)
            self.assertFalse(runner.performance_result(path)["meets_numeric_target"])
            data["max_rss_bytes"] = True
            runner.write_json(path, data)
            self.assertIsNone(runner.performance_result(path))

    def test_soak_never_equates_short_trial_or_gap_to_full_duration(self):
        self.assertEqual(soak.assess(10, 10, 3, False, 5, 15), "short_trial_only")
        self.assertEqual(soak.assess(soak.TARGET, soak.TARGET, 100, False, 10, 15), "review_required")
        self.assertEqual(soak.assess(soak.TARGET, soak.TARGET, 100, False, 16, 15), "inconclusive")
        self.assertEqual(soak.assess(soak.TARGET, soak.TARGET, 100, True, 10, 15), "inconclusive")
