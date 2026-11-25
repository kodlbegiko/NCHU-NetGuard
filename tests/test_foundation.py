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
    @patch.object(monitor, "load_state", return_value={"dorm_in": 10, "dorm_out": 5})
    @patch.object(monitor, "run_probe", side_effect=["interface: en0", "140.120.1.2"])
    def test_explicit_scope_reports_local_bucket_not_provider_balance(self, _route, _state, _provider):
        result = monitor.query_traffic("dorm")
        self.assertEqual(result["used_total"], 15)
        self.assertTrue(result["scope_user_selected"])
        self.assertIsNone(result["rem_total"])
        self.assertFalse(result["quota_units_verified"])

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

    def test_json_cli(self):
        output = subprocess.check_output([sys.executable, str(ROOT / "scripts/traffic_monitor.py"), "--json"], text=True, timeout=20)
        result = json.loads(output)
        self.assertEqual(result["schema_version"], 1)

    def test_no_direct_app_process_launcher(self):
        for path in (ROOT / "src").glob("*.swift"):
            self.assertNotRegex(path.read_text(), r"\bProcess\s*\(")
        self.assertNotIn("140.120.251.126", (ROOT / "src/main.swift").read_text())

    def test_portability(self):
        self.assertNotIn("/Users/", (ROOT / "src/main.swift").read_text())
        self.assertIn("scripts/traffic_monitor.py", (ROOT / "Makefile").read_text())

if __name__ == "__main__":
    unittest.main()
