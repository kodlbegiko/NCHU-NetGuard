import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/acceptance"))
import run_all as runner
import soak_test as soak
import record_manual as manual

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

    def test_coverage_requires_actual_threshold_not_just_exit_zero(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "coverage.log"
            data = {"executable_lines": 100, "covered_lines": 89, "complete_inventory": True, "meets_target": False}
            path.write_text(json.dumps(data) + "\n::warning::below threshold\n")
            self.assertFalse(runner.coverage_result(path)["meets_numeric_target"])
            data.update(covered_lines=90, meets_target=True)
            path.write_text(json.dumps(data))
            self.assertTrue(runner.coverage_result(path)["meets_numeric_target"])
            data.update(complete_inventory=False, meets_target=False)
            path.write_text(json.dumps(data))
            self.assertFalse(runner.coverage_result(path)["complete_inventory"])
            data.update(meets_target=True)
            path.write_text(json.dumps(data))
            self.assertIsNone(runner.coverage_result(path))

    def test_matrix_template_and_validator_stay_aligned(self):
        docs = ROOT / "docs/acceptance"
        matrix = json.loads((docs / "acceptance-matrix.json").read_text())
        ledger = json.loads((docs / "MANUAL-RESULT.template.json").read_text())
        schema = json.loads((docs / "RESULT-SCHEMA.json").read_text())
        self.assertEqual(tuple(g["id"] for g in matrix["gates"]), runner.MANUAL_IDS)
        self.assertEqual(tuple(g["id"] for g in ledger["gates"]), runner.MANUAL_IDS)
        self.assertEqual(set(g["id"] for g in matrix["gates"] if g["initial_status"] == "blocked"), runner.BLOCKED_IDS)
        self.assertEqual(set(schema["properties"]["manual_gates"]["items"]["properties"]["id"]["enum"]), set(runner.MANUAL_IDS))
        with self.assertRaises(ValueError):
            manual.validate(ledger)
        ledger["commit_sha"] = "a" * 40
        ledger["environment"] = {"os_version":"15.0","architecture":"arm64","hardware_model":"Mac16,12"}
        result = manual.validate(ledger)
        self.assertFalse(result["full_device_acceptance"])
        gate = ledger["gates"][0]
        gate["outcome"] = "observed_pass"
        with self.assertRaises(ValueError):
            manual.validate(ledger)
        gate.update(observed_at="2026-11-26T12:00:00+00:00", evidence_sha256=["a"*64])
        self.assertEqual(manual.validate(ledger)["counts"]["observed_pass"], 1)
        recovery = next(g for g in ledger["gates"] if g["id"] == "recovery")
        recovery.update(outcome="observed_pass", observed_at=gate["observed_at"], evidence_sha256=gate["evidence_sha256"])
        with self.assertRaises(ValueError):
            manual.validate(ledger)
