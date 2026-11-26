#!/usr/bin/env python3
"""Foreground, explicitly selected process soak observation; never launch or restart it."""
import argparse
import json
import math
import os
import platform
import sys
import time
from pathlib import Path

from run_all import ROOT, new_run, now, revision, write_json

sys.path.insert(0, str(ROOT / "scripts"))
from benchmark_device import sample

TARGET = 168 * 3600

def assess(elapsed, target, samples, interrupted, max_gap, allowed_gap):
    if interrupted or samples < 2 or max_gap > allowed_gap:
        return "inconclusive"
    if elapsed < target:
        return "inconclusive"
    return "review_required" if target == TARGET else "short_trial_only"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=TARGET)
    parser.add_argument("--interval", type=int, default=60)
    args = parser.parse_args()
    if (platform.system() != "Darwin" or args.pid <= 0 or
        not 10 <= args.seconds <= TARGET or not 5 <= args.interval <= 300 or args.interval > args.seconds):
        parser.error("requires macOS, positive PID and valid duration/interval")
    os.umask(0o077)
    try:
        sha, clean = revision()
        if not clean:
            raise ValueError("dirty checkout")
        out = new_run("soak-")
    except (OSError, ValueError, RuntimeError):
        print("Soak setup failed.", file=sys.stderr)
        return 2
    summary = {"schema_version": 1, "kind": "process_soak", "commit_sha": sha,
               "started_at": now(), "requested_seconds": args.seconds,
               "interval_seconds": args.interval, "status": "inconclusive",
               "samples": 0, "elapsed_seconds": 0, "max_gap_seconds": 0,
               "binary_identity": "operator_review_required", "full_device_acceptance": False}
    path = out / "summary.json"
    write_json(path, summary)
    first = previous = None
    first_wall = previous_wall = None
    max_rss = max_gap = 0
    count = 0
    interrupted = False
    try:
        with (out / "samples.jsonl").open("x", encoding="utf-8") as stream:
            while True:
                current = sample(args.pid)
                wall = time.time()
                if first is None:
                    first, first_wall = current, wall
                if previous is not None:
                    gap = max(current[1] - previous[1], wall - previous_wall)
                    max_gap = max(max_gap, gap)
                    if (current[0] != first[0] or current[2] < previous[2] or
                        current[1] <= previous[1] or wall < previous_wall or gap > args.interval + 15):
                        raise RuntimeError("identity, clock or observation gap")
                count += 1
                max_rss = max(max_rss, current[3] * 1024)
                elapsed = current[1] - first[1]
                wall_elapsed = wall - first_wall
                stream.write(json.dumps({"elapsed_seconds": round(elapsed, 3),
                    "cpu_seconds_delta": round(current[2] - first[2], 4),
                    "rss_bytes": current[3] * 1024}, allow_nan=False) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
                summary.update(samples=count, elapsed_seconds=elapsed, wall_elapsed_seconds=wall_elapsed,
                               max_gap_seconds=max_gap, max_rss_bytes=max_rss,
                               average_cpu_percent_one_core=(100 * (current[2] - first[2]) / elapsed
                                                             if elapsed > 0 else None))
                write_json(path, summary)
                if elapsed >= args.seconds:
                    break
                previous, previous_wall = current, wall
                time.sleep(min(args.interval, max(0, args.seconds - elapsed)))
    except (KeyboardInterrupt, OSError, ValueError, RuntimeError, ArithmeticError, __import__("subprocess").SubprocessError):
        interrupted = True
    finally:
        try:
            end_sha, end_clean = revision()
            interrupted = interrupted or end_sha != sha or not end_clean
        except Exception:
            interrupted = True
        summary["status"] = assess(summary["elapsed_seconds"], args.seconds, count,
                                   interrupted, max_gap, args.interval + 15)
        summary["finished_at"] = now()
        write_json(path, summary)
        print("Private soak report: " + str(path.relative_to(ROOT)))
    return 0 if summary["status"] in ("review_required", "short_trial_only") else 2

if __name__ == "__main__":
    raise SystemExit(main())
