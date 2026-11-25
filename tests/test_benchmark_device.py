import importlib.util
import pathlib
import unittest
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
