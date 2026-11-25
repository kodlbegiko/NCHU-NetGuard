import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("traffic_monitor", ROOT / "scripts/traffic_monitor.py")
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)

def row(ip, dl="1.5 GB", ul="2 MB", total="1.502 GB"):
    return f"<tr><td>1</td><td>fixture</td><td>{ip}</td><td>{dl}</td><td>{ul}</td><td>{total}</td></tr>"

class RankingParserTests(unittest.TestCase):
    def test_exact_match_only(self):
        result = monitor.parse_ranking(row("192.0.2.10") + row("192.0.2.1"), "192.0.2.1")
        self.assertEqual(result["status"], "listed")
        self.assertFalse(result["units_verified"])
        self.assertNotIn("in_bytes", result)
    def test_missing_and_duplicate_unknown(self):
        for html in [row("192.0.2.10"), row("192.0.2.1") * 2]:
            self.assertIsNone(monitor.parse_ranking(html, "192.0.2.1")["in_top1000"])
    def test_malformed_duplicate_identity_is_ambiguous(self):
        html = row("192.0.2.1") + row("192.0.2.1", "NaN GB")
        self.assertIsNone(monitor.parse_ranking(html, "192.0.2.1")["in_top1000"])
    def test_invalid_units_and_cross_row_unknown(self):
        for html in [row("192.0.2.1", "NaN GB"), "<tr><td>1</td><td>fixture</td><td>192.0.2.1</td></tr><tr><td>1 GB</td><td>2 MB</td><td>1 GB</td></tr>"]:
            self.assertIsNone(monitor.parse_ranking(html, "192.0.2.1")["in_top1000"])
