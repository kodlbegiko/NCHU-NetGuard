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
