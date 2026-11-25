#!/usr/bin/env python3
"""Run the bundled fixture-only native smoke path; no install or launch agent."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

MARKER = "NETGUARD_SMOKE_OK fixture-native-views=4 status-item=1 resources=2"


def run_smoke(app: Path, timeout: float = 30) -> None:
    executable = app.resolve() / "Contents" / "MacOS" / "NCHUTraffic"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise RuntimeError("Missing executable; run make build first.")
    # Foundation/AppKit can maintain OS-managed caches; these env values
    # supplement the explicit fixture delegate, not a security sandbox.
    with tempfile.TemporaryDirectory(prefix="netguard-smoke-") as temp:
        env = os.environ.copy()
        env.update(HOME=temp, CFFIXED_USER_HOME=temp, TMPDIR=temp)
        try:
            result = subprocess.run(
                [str(executable), "--netguard-smoke"],
                cwd=temp, env=env, capture_output=True, text=True,
                timeout=timeout, check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("Fixture smoke timed out; GUI session may be unavailable.") from exc
        if result.stdout:
            print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        if result.returncode != 0 or MARKER not in result.stdout.splitlines():
            raise RuntimeError(f"Fixture smoke failed (exit {result.returncode}); exact success marker required.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build/NCHUTraffic.app"))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        print("Smoke requires macOS and a GUI-capable login session.", file=sys.stderr)
        return 1
    try:
        run_smoke(args.app)
    except (OSError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
