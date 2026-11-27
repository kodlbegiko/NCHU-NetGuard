import hashlib
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
import record_manual as manual
import verify_report as verifier
import manual_session as session

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
                    "duration_seconds": 60, "samples": 13, "max_sample_gap_seconds": 5}
            runner.write_json(path, data)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertTrue(runner.performance_result(path)["meets_numeric_target"])
            self.assertFalse(runner.performance_result(path)["meets_observation_window"])
            data.update(duration_seconds=300, samples=61)
            runner.write_json(path, data)
            self.assertTrue(runner.performance_result(path)["meets_observation_window"])
            data["max_sample_gap_seconds"] = 16
            runner.write_json(path, data)
            self.assertFalse(runner.performance_result(path)["meets_observation_window"])
            data.update(max_sample_gap_seconds=5, samples=2)
            runner.write_json(path, data)
            self.assertIsNone(runner.performance_result(path))
            data["samples"] = 61
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


    def test_planned_steps_missing_duplicate_or_unrequested_cannot_pass(self):
        expected = runner.planned_steps("host", True, True)
        rows = [runner.row(id, "pass", "exit") for id in expected]
        self.assertEqual(runner.automatic_exit(rows, True, expected), 0)
        self.assertEqual(runner.automatic_exit(rows[:-1], True, expected), 2)
        self.assertEqual(runner.automatic_exit(rows + rows[:1], True, expected), 2)
        self.assertEqual(runner.automatic_exit(rows[::-1], True, expected), 2)

    def test_report_verifier_checks_logs_plan_and_verdict(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "logs").mkdir(mode=0o700)
            env = {"os":"Darwin","os_version":"15.0","architecture":"arm64",
                   "python":"3.12","hardware_model":"Mac16,12"}
            options = {"performance":False,"traffic":False}
            plan = runner.planned_steps("core", **options)
            rows = [runner.row("preflight", "pass", "clean_macos_checkout")]
            for id in plan[1:]:
                raw = (verifier.MARKERS.get(id, "ok") + "\n").encode()
                if id == "coverage":
                    raw = json.dumps({"executable_lines":100,"covered_lines":95,
                        "complete_inventory":True,"meets_target":True}).encode()
                path = out / "logs" / (id + ".log")
                path.write_bytes(raw)
                path.chmod(0o600)
                rows.append(runner.row(id, "pass", "exit", log="logs/" + path.name,
                    log_sha256=hashlib.sha256(raw).hexdigest(), exit_code=0, duration_seconds=1))
            report = {"schema_version":2,"kind":"local_automatic","started_at":runner.now(),
                "finished_at":runner.now(),"commit_sha":"a"*40,"clean_at_start":True,
                "clean_at_end":True,"same_revision_at_end":True,"environment":env,
                "profile":"core","options":options,"planned_steps":list(plan),"steps":rows,
                "manual_gates":[{"id":id,"status":"blocked" if id in runner.BLOCKED_IDS else "review_required"}
                    for id in runner.MANUAL_IDS],"full_device_acceptance":False,"automatic_exit_code":0}
            runner.write_json(out / "environment.json", env)
            runner.write_json(out / "summary.json", report)
            self.assertEqual(verifier.verify(out, "a"*40)["automatic_exit_code"], 0)
            with self.assertRaises(ValueError):
                verifier.verify(out, "b"*40)
            path = out / "logs" / "module_smoke.log"
            original = path.read_bytes()
            path.write_bytes(b"modified")
            with self.assertRaises(ValueError):
                verifier.verify(out)
            path.write_bytes(original)
            report["steps"] = rows[:-1]
            runner.write_json(out / "summary.json", report)
            with self.assertRaises(ValueError):
                verifier.verify(out)
            report["automatic_exit_code"] = 2
            runner.write_json(out / "summary.json", report)
            self.assertEqual(verifier.verify(out)["automatic_exit_code"], 2)
            self.assertFalse(verifier.verify(out)["full_device_acceptance"])
            report["steps"] = rows
            report["automatic_exit_code"] = 0
            runner.write_json(out / "summary.json", report)
            target = out / "logs" / "other.log"
            path.rename(target)
            path.symlink_to(target)
            with self.assertRaises(OSError):
                verifier.verify(out)


    def test_verifier_rejects_short_gapped_and_mismatched_performance_pass(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            (out / "logs").mkdir(mode=0o700)
            env = {"os":"Darwin","os_version":"15.0","architecture":"arm64",
                   "python":"3.12","hardware_model":"Mac16,12"}
            options = {"performance":True,"traffic":False}
            plan = runner.planned_steps("core", **options)
            rows = [runner.row("preflight", "pass", "clean_macos_checkout")]
            for id in plan[1:-1]:
                raw = (verifier.MARKERS.get(id, "ok") + "\n").encode()
                if id == "coverage":
                    raw = json.dumps({"executable_lines":100,"covered_lines":95,
                        "complete_inventory":True,"meets_target":True}).encode()
                path = out / "logs" / (id + ".log")
                path.write_bytes(raw)
                path.chmod(0o600)
                rows.append(runner.row(id, "pass", "exit", log="logs/" + path.name,
                    log_sha256=hashlib.sha256(raw).hexdigest(), exit_code=0, duration_seconds=1))
            report = {"schema_version":2,"kind":"local_automatic","started_at":runner.now(),
                "finished_at":runner.now(),"commit_sha":"a"*40,"clean_at_start":True,
                "clean_at_end":True,"same_revision_at_end":True,"environment":env,
                "profile":"core","options":options,"planned_steps":list(plan),
                "manual_gates":[{"id":id,"status":"blocked" if id in runner.BLOCKED_IDS else "review_required"}
                    for id in runner.MANUAL_IDS],"full_device_acceptance":False,"automatic_exit_code":0}
            runner.write_json(out / "environment.json", env)
            path = out / "logs" / "performance.log"
            data = {"average_cpu_percent_one_core":.25,"max_rss_bytes":55_000_000,
                    "duration_seconds":300,"samples":61,"max_sample_gap_seconds":5}
            def publish(payload, mismatch=False):
                raw = json.dumps(payload).encode()
                path.write_bytes(raw)
                path.chmod(0o600)
                metrics = runner.performance_metrics(payload)
                if mismatch:
                    metrics["cpu_percent_one_core"] = 0
                report["steps"] = rows + [runner.row("performance", "pass", "numeric_target_only_review_required",
                    log="logs/" + path.name, log_sha256=hashlib.sha256(raw).hexdigest(),
                    exit_code=0, duration_seconds=payload["duration_seconds"], metrics=metrics)]
                runner.write_json(out / "summary.json", report)
            publish(data)
            self.assertEqual(verifier.verify(out)["automatic_exit_code"], 0)
            for payload in (dict(data, duration_seconds=60, samples=13),
                            dict(data, max_sample_gap_seconds=16)):
                publish(payload)
                with self.assertRaises(ValueError):
                    verifier.verify(out)
            publish(data, mismatch=True)
            with self.assertRaises(ValueError):
                verifier.verify(out)

    def test_manual_session_keeps_first_observation_and_checks_actual_files(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            env = {"os_version":"15.0","architecture":"arm64","hardware_model":"Mac16,12"}
            session.create_session(out, "a"*40, env)
            source = out / "fixture.txt"
            source.write_text("synthetic redacted observation")
            result = session.record(out, "a"*40, "sleep_wake", "observed_pass", [source])
            self.assertEqual(result["verified_evidence_files"], 1)
            self.assertFalse(result["full_device_acceptance"])
            new_source = out / "new.txt"
            new_source.write_text("second observation")
            prior = set((out / "evidence").iterdir())
            with self.assertRaises(OSError):
                session.record(out, "a"*40, "dual_stack", "observed_fail", [new_source, out / "missing"])
            self.assertEqual(set((out / "evidence").iterdir()), prior)
            with self.assertRaises(ValueError):
                session.record(out, "a"*40, "sleep_wake", "observed_fail", [source])
            with self.assertRaises(ValueError):
                session.record(out, "a"*40, "recovery", "observed_pass", [source])
            with self.assertRaises(ValueError):
                session.record(out, "b"*40, "dual_stack", "observed_pass", [source])
            link = out / "link"
            link.symlink_to(source)
            with self.assertRaises(OSError):
                session.record(out, "a"*40, "dual_stack", "inconclusive", [link])
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            (out / "evidence" / (digest + ".bin")).write_bytes(b"altered")
            with self.assertRaises(ValueError):
                session.verify_evidence(out, session.read_ledger(out))
