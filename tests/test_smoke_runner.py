import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts.smoke_test import MARKER, run_smoke


class SmokeRunnerTests(unittest.TestCase):
    def fixture(self, root):
        app = pathlib.Path(root) / "Test.app"
        executable = app / "Contents/MacOS/NCHUTraffic"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture")
        executable.chmod(0o700)
        return app

    @patch("scripts.smoke_test.subprocess.run")
    def test_requires_exact_marker_and_zero_exit(self, run):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.fixture(tmp)
            run.return_value = subprocess.CompletedProcess([], 0, MARKER + "\n", "")
            run_smoke(app)
            self.assertEqual(run.call_args.args[0][1], "--netguard-smoke")
            self.assertEqual(run.call_args.kwargs["timeout"], 30)
            self.assertNotEqual(run.call_args.kwargs["env"]["HOME"], str(app))
            run.return_value = subprocess.CompletedProcess([], 0, "prefix " + MARKER + "\n", "")
            with self.assertRaises(RuntimeError):
                run_smoke(app)
            run.return_value = subprocess.CompletedProcess([], 1, MARKER + "\n", "")
            with self.assertRaises(RuntimeError):
                run_smoke(app)

    @patch("scripts.smoke_test.subprocess.run")
    def test_timeout_never_reports_success(self, run):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.fixture(tmp)
            run.side_effect = subprocess.TimeoutExpired([], 1)
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                run_smoke(app, timeout=1)

    @patch("scripts.smoke_test.subprocess.run")
    def test_missing_binary_rejected_without_launch(self, run):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, "Missing executable"):
                run_smoke(pathlib.Path(tmp) / "missing.app")
            run.assert_not_called()
