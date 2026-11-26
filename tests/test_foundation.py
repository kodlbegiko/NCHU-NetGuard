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
    def test_interface_counter_source_has_no_legacy_32_bit_fallback(self):
        main = (ROOT / "src/main.swift").read_text()
        host = (ROOT / "src/HostProbeCheck.swift").read_text()
        self.assertNotIn("assumingMemoryBound(to: if_data.self)", main)
        self.assertIn("InterfaceMIBReader.read", main)
        self.assertIn("IFMIB_IFDATA", host)
        self.assertIn("MemoryLayout.size(ofValue: record.ifmd_data.ifi_ibytes) == 8", host)

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
            hard = pathlib.Path(root) / "hard"
            hard.hardlink_to(path)
            self.assertIsNone(monitor.read_json_object(path))
            self.assertIsNone(monitor.read_json_object(hard))

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
                    conn.execute("PRAGMA user_version=3")
                self.assertEqual(monitor.load_history(), {"2026-11-24": {"total": 15, "dl": 10, "ul": 5}})
                with sqlite3.connect(db) as conn:
                    conn.execute("UPDATE history_days SET total=999")
                self.assertEqual(monitor.load_history(), {})
                db.unlink()
                self.assertEqual(monitor.load_history(), {"2026-11-24": 999})

    def test_cli_rejects_ambiguous_json_and_nonfinite_constants(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / "state"
            for raw in ('{"x":1,"x":2}', '{"x":{"a":1,"a":2}}', '{"x":NaN}', '{"x":Infinity}', '{"x":-Infinity}'):
                with self.subTest(raw=raw):
                    path.write_text(raw)
                    self.assertIsNone(monitor.read_json_object(path))
            path.write_text('{"a":1}')
            self.assertEqual(monitor.read_json_object(path), {"a": 1})

    def test_cli_rejects_corrupt_aggregate_and_unselected_scope(self):
        valid = {"ext_in": 10, "ext_out": 5, "observed_scopes": ["external"],
                 "scoped_history_eligible": True, "measured_sample_count": 1}
        ceiling = monitor.MAX_EXACT_BYTES
        bad = [{"dorm_in": ceiling}, {"unattributed_out": 2**64 - 1},
               {"wifi_out": -1}, {"dorm_in": True}, {"today_in": ceiling + 1},
               {"accounting_overflow": "false"}, {"accounting_overflow": True}]
        for delta in bad:
            with self.subTest(delta=delta), patch.object(monitor, "load_state", return_value={**valid, **delta}), patch.object(monitor, "run_probe", side_effect=["interface: en0", "192.0.2.1"]):
                self.assertEqual(monitor.query_traffic("external")["status"], "local_usage_unknown")
        with patch.object(monitor, "load_state", return_value=valid), patch.object(monitor, "run_probe", side_effect=["interface: en0", "192.0.2.1"]):
            self.assertEqual(monitor.query_traffic()["status"], "local_usage_unknown")
        with patch.object(monitor, "load_state", return_value=valid), patch.object(monitor, "run_probe", side_effect=["interface: en0", "192.0.2.1"]):
            self.assertEqual(monitor.query_traffic("external")["used_total"], 15)
        self.assertTrue(monitor.valid_daily_counters({"dorm_in": ceiling}))
        self.assertFalse(monitor.valid_daily_counters({"dorm_in": ceiling, "ext_out": 1}))

    def test_history_rejects_unsafe_sidecars_and_oversized_totals(self):
        import sqlite3
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            db = pathlib.Path(root) / "history.sqlite"
            target = pathlib.Path(root) / "target"
            target.write_text("unchanged")
            with sqlite3.connect(db) as conn:
                conn.execute("PRAGMA user_version=2")
                conn.execute("CREATE TABLE history_days(day TEXT, total INTEGER, download INTEGER, upload INTEGER)")
                conn.execute("INSERT INTO history_days VALUES('2026-11-24',15,10,5)")
            with patch.object(monitor, "HISTORY_DB", str(db)):
                for suffix in ("-wal", "-shm", "-journal"):
                    side = db.with_name(db.name + suffix)
                    side.symlink_to(target)
                    self.assertEqual(monitor.load_history(), {})
                    side.unlink()
                    side.hardlink_to(target)
                    self.assertEqual(monitor.load_history(), {})
                    side.unlink()
                self.assertEqual(target.read_text(), "unchanged")
                self.assertEqual(monitor.load_history()["2026-11-24"]["total"], 15)
                with sqlite3.connect(db) as conn:
                    conn.execute("UPDATE history_days SET total=?, download=?, upload=0",
                                 (monitor.MAX_EXACT_BYTES + 1, monitor.MAX_EXACT_BYTES + 1))
                self.assertEqual(monitor.load_history(), {})

    def test_json_cli(self):
        import contextlib
        import io
        output = io.StringIO()
        with patch.object(sys, "argv", ["traffic_monitor.py", "--json"]), \
             patch.object(monitor, "run_probe", side_effect=OSError("offline fixture")), \
             patch.object(monitor, "load_state", return_value=None), \
             patch.object(monitor, "get_top100_data") as provider, contextlib.redirect_stdout(output):
            monitor.main()
        result = json.loads(output.getvalue())
        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["status"], "network_unknown")
        provider.assert_not_called()

    def test_no_direct_app_process_launcher(self):
        for path in (ROOT / "src").glob("*.swift"):
            self.assertNotRegex(path.read_text(), r"\bProcess\s*\(")
        self.assertNotIn("140.120.251.126", (ROOT / "src/main.swift").read_text())

    def test_popover_creation_deferred_until_opening(self):
        swift = (ROOT / "src/main.swift").read_text()
        setup = swift.split("func setupPopoverUI()", 1)[1].split("private func preparePopoverContent()", 1)[0]
        prepare = swift.split("private func preparePopoverContent()", 1)[1].split("func updateQuickPanel()", 1)[0]
        click = swift.split("func statusBarButtonClicked(", 1)[1].split("func pushDataToWebUI()", 1)[0]
        switch = swift.split("func switchPanel(", 1)[1].split("func openHistoryAnalytics()", 1)[0]
        self.assertNotIn("WKWebView(", setup)
        self.assertNotIn("NSHostingController(", setup)
        self.assertIn("guard popover.contentViewController == nil", prepare)
        self.assertIn("WKWebView(", prepare)
        self.assertIn("preparePopoverContent()", click)
        self.assertIn("if show, let button", switch)
        self.assertIn("preparePopoverContent()", switch)
        self.assertIn("if button.title != title", swift)
        self.assertIn("policyDayFormatter.string(from: Date())", swift)

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
