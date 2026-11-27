import sqlite3
import sys
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/acceptance"))
import diagnostics as diag


class DiagnosticTests(unittest.TestCase):
    def test_history_partition_and_rollover(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "history.sqlite"
            db = sqlite3.connect(path)
            db.executescript("""
                CREATE TABLE history_days(day TEXT PRIMARY KEY,total INTEGER,download INTEGER,upload INTEGER);
                CREATE TABLE history_scopes(day TEXT,scope TEXT,download INTEGER,upload INTEGER,PRIMARY KEY(day,scope));
                INSERT INTO history_days VALUES('2026-11-28',100,80,20);
                INSERT INTO history_scopes VALUES('2026-11-28','dorm',80,20);
                PRAGMA user_version=3;
            """)
            db.close()
            path.chmod(0o600)
            original = path.read_bytes()
            report = diag.inspect_history(path, ["2026-11-28"])
            self.assertEqual(report["status"], "snapshot_validated")
            self.assertEqual(diag.rollover_evidence(report, {"day":"2026-11-28","received":79,"sent":20}),
                             "observed_lower_bound_met_review_required")
            self.assertEqual(diag.rollover_evidence(report, {"day":"2026-11-28","received":81,"sent":20}),
                             "observed_lower_bound_mismatch")
            self.assertEqual(path.read_bytes(), original)
            db = sqlite3.connect(path)
            db.execute("UPDATE history_scopes SET download=79")
            db.commit()
            db.close()
            original = path.read_bytes()
            with self.assertRaises(ValueError):
                diag.inspect_history(path, [])
            self.assertEqual(path.read_bytes(), original)

    def test_missing_and_alias_are_not_validated(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "history.sqlite"
            self.assertEqual(diag.inspect_history(path, [])["status"], "not_present")
            path.symlink_to(Path(folder) / "missing")
            with self.assertRaises(ValueError):
                diag.inspect_history(path, [])

    def test_resource_trend_does_not_claim_leak_proof(self):
        self.assertEqual(diag.trend([None])["status"], "unavailable")
        self.assertEqual(diag.trend([10, None, 12])["net_change"], 2)
        self.assertEqual(diag.trend([10, 12])["status"], "review_required")

    def test_diagnostic_report_index_never_reads_report_contents(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "NCHUTraffic-2026.ips").write_text("private fixture")
            (root / "OtherApp-2026.ips").write_text("unrelated")
            (root / "NetGuard-alias.crash").symlink_to(root / "NCHUTraffic-2026.ips")
            self.assertEqual(diag.crash_report_count(root, 0), 1)
            self.assertEqual(diag.crash_report_count(root, 10**12), 0)
            self.assertIsNone(diag.crash_report_count(root / "missing", 0))
