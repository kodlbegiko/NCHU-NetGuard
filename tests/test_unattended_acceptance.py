import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/acceptance"))
import unattended as runner


class UnattendedTests(unittest.TestCase):
    def test_clock_gap_and_cpu_rollback_rejected(self):
        a = dict(elapsed_seconds=0, wall_elapsed_seconds=0, cpu_seconds_delta=0, rss_bytes=1024)
        b = dict(a, elapsed_seconds=60, wall_elapsed_seconds=60, cpu_seconds_delta=1)
        self.assertEqual(runner.validate_transition(a, b, 75), 60)
        for invalid in (dict(b, wall_elapsed_seconds=80), dict(b, elapsed_seconds=0),
                        dict(b, cpu_seconds_delta=-1), dict(b, rss_bytes=True)):
            with self.assertRaises(ValueError):
                runner.validate_transition(a, invalid, 75)

    def test_report_recomputes_short_soak_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            rows = [dict(elapsed_seconds=t, wall_elapsed_seconds=t, cpu_seconds_delta=t/100,
                         rss_bytes=1024) for t in (0, 60)]
            raw = ("\n".join(json.dumps(r) for r in rows) + "\n").encode()
            log = out / "soak.jsonl"
            log.write_bytes(raw)
            log.chmod(0o600)
            report = dict(status="short_trial_only", samples=2, elapsed_seconds=60,
                          requested_seconds=60, interval_seconds=60, max_gap_seconds=60,
                          max_rss_bytes=1024, sha256=hashlib.sha256(raw).hexdigest())
            runner.write_json(out / "soak.json", report)
            self.assertEqual(runner.observation_evidence(out, "soak", 60, 60)["status"], "short_trial_only")
            with self.assertRaises(ValueError):
                runner.observation_evidence(out, "soak", runner.TARGET, 60)
            report["elapsed_seconds"] = 600
            runner.write_json(out / "soak.json", report)
            with self.assertRaises(ValueError):
                runner.observation_evidence(out, "soak", 60, 60)
            log.write_bytes(raw + b"tampered")
            with self.assertRaises(ValueError):
                runner.observation_evidence(out, "soak", 60, 60)

    def test_identity_rejects_unmatched_bundle(self):
        identity = ("/fixture/NCHUTraffic.app/Contents/MacOS/NCHUTraffic", "start")
        with patch.object(runner, "sample", return_value=(identity, 1, 0, 100)), \
                patch.object(runner, "describe", return_value={"sha256":"different"}):
            with self.assertRaises(ValueError):
                runner.identity_of(123, {"bundles":{"legacy":{"sha256":"expected"}}})

    def test_incomplete_report_never_becomes_complete(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            (out / "logs").mkdir(mode=0o700)
            runner.write_json(out / "summary.json", {"schema_version": 2, "kind": "unattended_acceptance",
                "commit_sha": "a"*40, "full_device_acceptance": False, "release_authorized": False,
                "started_at": runner.now(), "status": "observations_complete_review_required"})
            with self.assertRaises((ValueError, KeyError)):
                runner.review_completed(out, "a"*40)

    def healthy(self, ticks=10, day="2026-11-28", received=100):
        return dict(schema_version=1, wall_seconds=100, tick_count=ticks,
                    sample_cycles=ticks, measured_cycles=ticks-1, save_successes=1,
                    max_tick_gap_seconds=1.1, max_tick_duration_seconds=.01,
                    max_sample_age_seconds=.02, max_save_gap_seconds=11,
                    safety_hold_ticks=0, sample_age_seconds=.01, save_age_seconds=2,
                    day=day, received=received, sent=20,
                    sleeping=False, clock_held=False, persistence_blocked=False,
                    accounting_overflow=False, history_healthy=True,
                    busy_seconds={"route":0, "apps":0, "ping":0, "provider":0, "dns":0},
                    max_busy_seconds={"route":0, "apps":0, "ping":0, "provider":0, "dns":0})

    def test_heartbeat_rejects_stale_or_stalled_function_and_safety_holds(self):
        h = self.healthy()
        self.assertEqual(runner.validate_health(h, 105), h)
        for bad in (dict(h, sample_age_seconds=6), dict(h, save_age_seconds=31),
                    dict(h, persistence_blocked=True), dict(h, max_tick_gap_seconds=16),
                    dict(h, max_save_gap_seconds=31), dict(h, safety_hold_ticks=1),
                    dict(h, max_busy_seconds={"route":61, "apps":0, "ping":0, "provider":0, "dns":0}),
                    dict(h, busy_seconds={"route":61, "apps":0, "ping":0, "provider":0, "dns":0}),
                    dict(h, measured_cycles=11), dict(h, day="2026-02-30")):
            with self.assertRaises(ValueError):
                runner.validate_health(bad, 105)
        with self.assertRaises(ValueError):
            runner.validate_health(h, 116)

    def test_health_transition_and_rollover(self):
        a = dict(elapsed_seconds=0, health=self.healthy())
        b = dict(elapsed_seconds=60, health=dict(self.healthy(70), save_successes=7, wall_seconds=160))
        runner.health_transition(a, b)
        with self.assertRaises(ValueError):
            runner.health_transition(a, dict(b, health=a["health"]))
        with self.assertRaises(ValueError):
            runner.health_transition(a, dict(b, health=dict(b["health"], received=99)))
        new_day = dict(b, health=dict(b["health"], day="2026-11-29", received=0))
        runner.health_transition(a, new_day)
        self.assertEqual(runner.health_summary([a,new_day])["observed_day_transitions"], 1)

    def test_missing_periodic_regression_never_passes(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            runner.write_json(out / "regressions.json", [])
            with self.assertRaises(ValueError):
                runner.review_regressions(out, 60)
