import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("traffic_monitor", ROOT / "scripts/traffic_monitor.py")
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)

class FoundationTests(unittest.TestCase):
    def test_tls_not_bypassed(self):
        for path in ["src/main.swift", "scripts/traffic_monitor.py"]:
            source = (ROOT / path).read_text()
            for token in ["InsecureCertDelegate", "ssl.CERT_NONE", "check_hostname = False"]:
                self.assertNotIn(token, source)

    def test_legacy_mutations_disabled(self):
        source = (ROOT / "src/main.swift").read_text()
        for token in ["SIGKILL", "SIGSTOP", "SIGCONT", '"/usr/bin/pkill"', '"-setairportpower"', '"-setadditionalroutes"', '"-ordernetworkservices"', '"-setnetworkserviceenabled"']:
            self.assertNotIn(token, source)

    @patch.object(monitor, "run_probe", side_effect=OSError("offline"))
    def test_unknown_network(self, _):
        result = monitor.query_traffic()
        self.assertEqual(result["status"], "network_unknown")
        self.assertIsNone(result["top100"]["in_top1000"])

    @patch.object(monitor.urllib.request, "build_opener", side_effect=OSError("TLS or network failure"))
    def test_provider_error_unknown(self, _):
        result = monitor.get_top100_data("192.0.2.1")
        self.assertIsNone(result["in_top1000"])
        self.assertEqual(result["status"], "unavailable")

    @patch.object(monitor, "load_state", return_value=None)
    @patch.object(monitor, "run_probe", side_effect=["interface: en0", "192.0.2.1"])
    def test_missing_state_never_means_zero(self, _route, _state):
        result = monitor.query_traffic()
        self.assertEqual(result["status"], "local_usage_unknown")
        self.assertNotIn("used_total", result)

    @patch.object(monitor, "get_top100_data", return_value={"status": "unavailable"})
    @patch.object(monitor, "load_state", return_value={"dorm_in": 10, "dorm_out": 5})
    @patch.object(monitor, "run_probe", side_effect=["interface: en0", "140.120.1.2"])
    def test_campus_ip_alone_does_not_prove_dorm(self, _route, _state, provider):
        result = monitor.query_traffic()
        self.assertEqual(result["status"], "local_usage_unknown")
        self.assertNotIn("rem_total", result)
        provider.assert_called_once_with("140.120.1.2")

    @patch.object(monitor, "get_top100_data", return_value={"status": "unavailable"})
    @patch.object(monitor, "load_state", return_value={"dorm_in": 10, "dorm_out": 5, "observed_scopes": ["dorm"], "scoped_history_eligible": True, "measured_sample_count": 1})
    @patch.object(monitor, "run_probe", side_effect=["interface: en0", "140.120.1.2"])
    def test_explicit_scope_reports_local_bucket_not_provider_balance(self, _route, _state, _provider):
        result = monitor.query_traffic("dorm")
        self.assertEqual(result["used_total"], 15)
        self.assertTrue(result["scope_user_selected"])
        self.assertIsNone(result["rem_total"])
        self.assertFalse(result["quota_units_verified"])

    @patch.object(monitor, "run_probe", side_effect=["interface: en0", "192.0.2.1"])
    def test_scope_zero_requires_positive_observation_evidence(self, _route):
        state = {"ext_in": 0, "ext_out": 0}
        with patch.object(monitor, "load_state", return_value=state):
            self.assertEqual(monitor.query_traffic("external")["status"], "local_usage_unknown")
        state.update(observed_scopes=["external"], scoped_history_eligible=True, measured_sample_count=1)
        with patch.object(monitor, "run_probe", side_effect=["interface: en0", "192.0.2.1"]), patch.object(monitor, "load_state", return_value=state):
            self.assertEqual(monitor.query_traffic("external")["used_total"], 0)

    def test_provider_failure_categories_are_redacted(self):
        errors = [(TimeoutError("private path"), "timeout"),
                  (monitor.ssl.SSLError("private cert"), "tls_error"),
                  (monitor.urllib.error.HTTPError("https://example.invalid", 429, "", {}, None), "rate_limited"),
                  (monitor.urllib.error.HTTPError("https://example.invalid", 302, "", {}, None), "redirect_rejected")]
        for error, code in errors:
            with patch.object(monitor.urllib.request, "build_opener", side_effect=error):
                result = monitor.get_top100_data("192.0.2.1")
                self.assertEqual(result["error_code"], code)
                self.assertIsNone(result["in_top1000"])
                self.assertNotIn("private", json.dumps(result))

    def test_redirect_rejected(self):
        self.assertIsNone(monitor.NoRedirect().redirect_request(None, None, 302, "", {}, "http://example.invalid"))

    def test_probe_bounded(self):
        self.assertEqual(monitor.run_probe([sys.executable, "-c", "print('ok')"], 2), "ok\n")
        with self.assertRaises(ValueError):
            monitor.run_probe([sys.executable, "-c", "print('x' * 10000)"], 2, 32)
        with self.assertRaises(TimeoutError):
            monitor.run_probe([sys.executable, "-c", "import time; time.sleep(3)"], .05)

    def test_local_json_rejects_symlink_and_non_object(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / "state"
            path.write_text("[]")
            self.assertIsNone(monitor.read_json_object(path))
            path.write_text('{"date": "test"}')
            self.assertEqual(monitor.read_json_object(path), {"date": "test"})
            link = pathlib.Path(root) / "link"
            link.symlink_to(path)
            self.assertIsNone(monitor.read_json_object(link))

    def test_cli_reads_finalized_sqlite_not_stale_legacy(self):
        import sqlite3
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            db = pathlib.Path(root) / "history.sqlite"
            legacy = pathlib.Path(root) / "legacy.json"
            legacy.write_text('{"2026-11-24": 999}')
            with sqlite3.connect(db) as conn:
                conn.execute("PRAGMA user_version=2")
                conn.execute("CREATE TABLE history_days(day TEXT, total INTEGER, download INTEGER, upload INTEGER)")
                conn.execute("INSERT INTO history_days VALUES('2026-11-24',15,10,5)")
            with patch.object(monitor, "HISTORY_DB", str(db)), patch.object(monitor, "HISTORY_FILE", str(legacy)):
                self.assertEqual(monitor.load_history(), {"2026-11-24": {"total": 15, "dl": 10, "ul": 5}})
                with sqlite3.connect(db) as conn:
                    conn.execute("UPDATE history_days SET total=999")
                self.assertEqual(monitor.load_history(), {})
                db.unlink()
                self.assertEqual(monitor.load_history(), {"2026-11-24": 999})

    def test_json_cli(self):
        output = subprocess.check_output([sys.executable, str(ROOT / "scripts/traffic_monitor.py"), "--json"], text=True, timeout=20)
        result = json.loads(output)
        self.assertEqual(result["schema_version"], 1)

    def test_no_direct_app_process_launcher(self):
        for path in (ROOT / "src").glob("*.swift"):
            self.assertNotRegex(path.read_text(), r"\bProcess\s*\(")
        self.assertNotIn("140.120.251.126", (ROOT / "src/main.swift").read_text())

    def test_legacy_bridge_has_no_markup_sink_or_dynamic_code(self):
        html = (ROOT / "src/Resources/popover.html").read_text()
        swift = (ROOT / "src/main.swift").read_text()
        self.assertNotIn("innerHTML", html)
        self.assertIn("connect-src 'none'", html)
        self.assertIn("callAsyncJavaScript", swift)
        self.assertNotIn("evaluateJavaScript(js", swift)
        self.assertIn("navigationDelegate = self", swift)

    def test_portability(self):
        self.assertNotIn("/Users/", (ROOT / "src/main.swift").read_text())
        self.assertIn("scripts/traffic_monitor.py", (ROOT / "Makefile").read_text())


class LoginItemSafetyTests(unittest.TestCase):
    def test_legacy_login_item_is_not_rewritten_and_disabled_menu_is_explicit(self):
        swift = (ROOT / "src/main.swift").read_text()
        self.assertIn("LoginItemConfiguration.matches(existing, executable: executable)", swift)
        self.assertIn("HistoryFileAccess.removeIfUnchanged(url, expected: existing", swift)
        self.assertNotIn("plistContent.write", swift)
        self.assertNotIn("http://140.120.4.13/apply.php", swift)
        for selector in ("handleToggleWifiFailover", "handleToggleSplitRouting", "handleToggleMidnightSchedule"):
            self.assertNotIn("action: #selector(" + selector + ")", swift)

if __name__ == "__main__":
    unittest.main()
