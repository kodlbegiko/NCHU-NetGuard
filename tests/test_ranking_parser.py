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

    def test_missing_row_distinguished_from_unrecognized_page(self):
        self.assertEqual(monitor.parse_ranking(row("192.0.2.2"), "192.0.2.1")["error_code"], "not_listed")
        self.assertEqual(monitor.parse_ranking("<html>unrecognized</html>", "192.0.2.1")["error_code"], "unrecognized_ranking")
        self.assertEqual(monitor.parse_ranking(row("192.0.2.1") * 2, "192.0.2.1")["error_code"], "ambiguous_identity")
        self.assertEqual(monitor.parse_ranking(row("192.0.2.1", "NaN GB"), "192.0.2.1")["error_code"], "malformed_row")


    def test_structural_ambiguity_does_not_produce_listing_or_absence(self):
        valid = row("192.0.2.1")
        for html in (
                valid.replace("<td>fixture</td>", "<td><tr><td>fixture</td></tr></td>"),
                valid.replace("<td>fixture</td>", "<td><td>fixture</td></td>"),
                valid.replace("</td>", "</th>", 1),
                valid[:-5],
                valid.replace("1.5 GB", "<script>1.5 GB</script>"),
                valid.replace("1.5 GB", "1.5<span hidden> GB</span>"),
                valid.replace("1.5 GB", "1" + " "*1024 + "GB")):
            with self.subTest(html=html):
                result = monitor.parse_ranking(html, "192.0.2.1")
                self.assertEqual(result["error_code"], "unrecognized_ranking")
                self.assertIsNone(result["in_top1000"])
        # A malformed page must not be used as evidence of absence either.
        self.assertEqual(monitor.parse_ranking(valid + "<tr><td>unfinished", "192.0.2.2")["error_code"],
                         "unrecognized_ranking")

    def test_display_length_and_spanned_rows_fail_closed(self):
        valid = row("192.0.2.1")
        too_long = row("192.0.2.1", "1" + " "*40 + "GB")
        self.assertEqual(monitor.parse_ranking(too_long, "192.0.2.1")["error_code"], "malformed_row")
        self.assertIsNone(monitor.parse_ranking(valid.replace("<td>fixture", "<td colspan='2'>fixture"),
                                               "192.0.2.1")["in_top1000"])
        header = "<tr><th colspan='6'>Ranking</th></tr>"
        self.assertEqual(monitor.parse_ranking(header + valid, "192.0.2.1")["status"], "listed")
        self.assertEqual(monitor.parse_ranking(valid.replace("1.5 GB", "<b>1.5</b> GB"),
                                               "192.0.2.1")["status"], "listed")
