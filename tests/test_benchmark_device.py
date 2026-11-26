import importlib.util
import pathlib
import unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("device_benchmark",ROOT/"scripts/benchmark_device.py")
benchmark=importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)

class BenchmarkTests(unittest.TestCase):
    def test_cpu_time(self):
        self.assertEqual(benchmark.cpu_seconds("1:02.50"),62.5)
        self.assertEqual(benchmark.cpu_seconds("1-02:03:04"),93784)
        with self.assertRaises(ValueError):
            benchmark.cpu_seconds("1:99")
    def test_cpu_and_rss(self):
        result=benchmark.summarize([(("app","start"),10,1,100),(("app","start"),20,1.05,120)])
        self.assertAlmostEqual(result["average_cpu_percent_one_core"],.5)
        self.assertEqual(result["max_rss_bytes"],122880)
        with self.assertRaises(RuntimeError):
            benchmark.summarize([(("app","start"),10,1,100),(("app","new"),20,1.05,120)])

    def test_sample_rechecks_identity(self):
        with patch.object(benchmark, "probe", side_effect=["/fixture/NCHUTraffic", "start", "0:01", "100", "/fixture/NCHUTraffic", "new"]):
            with self.assertRaises(RuntimeError):
                benchmark.sample(12345)
        with patch.object(benchmark, "probe", side_effect=["/fixture/NCHUTraffic", "start", "0:01", "100", "/fixture/NCHUTraffic", "start"]):
            self.assertEqual(benchmark.sample(12345)[2:], (1.0, 100))


    def test_relative_windows_disclose_peak_without_retaining_identity(self):
        identity = ("/fixture/NCHUTraffic", "start")
        samples = [(identity, 100, 1, 60), (identity, 160, 1.3, 100),
                   (identity, 220, 1.6, 70), (identity, 240, 1.8, 65)]
        result = benchmark.summarize(samples)
        self.assertEqual(result["peak_at_seconds"], 60)
        self.assertEqual(result["max_rss_bytes"], 100*1024)
        self.assertEqual(result["final_rss_bytes"], 65*1024)
        self.assertEqual(len(result["relative_windows"]), 3)
        self.assertEqual(result["relative_windows"][-1]["start_seconds"], 120)
        self.assertEqual(result["relative_windows"][-1]["end_seconds"], 140)
        self.assertNotIn("NCHUTraffic", str(result))
