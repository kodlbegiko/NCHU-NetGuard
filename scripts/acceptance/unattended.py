#!/usr/bin/env python3
"""One supervised setup, followed by unattended, read-only candidate validation.

Never launches/restarts an app, changes sleep settings, modifies network routes,
generates controlled traffic, or operates on the user's installation.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
from types import SimpleNamespace

from run_all import (ROOT, BLOCKED_IDS, CORE_STEPS, MANUAL_IDS, environment,
                     execute, new_run, now, revision, run_step, write_json,
                     performance_metrics, LIMIT)
from verify_report import verify, read_private, strict_json
from soak_test import TARGET
sys.path.insert(0, str(ROOT / "scripts"))
from benchmark_device import sample, summarize
from candidate_inventory import collect, describe

PERFORMANCE_WINDOWS = 3
PERFORMANCE_SECONDS = 300
SOAK_INTERVAL = 60


def exact_checkout(sha):
    if revision() != (sha, True):
        raise ValueError("checkout changed")


def identity_of(pid, inventory):
    reading = sample(pid)
    binary = Path(reading[0][0])
    if (not binary.is_absolute() or binary.name != "NCHUTraffic" or
            binary.parent.name != "MacOS" or binary.parent.parent.name != "Contents"):
        raise ValueError("cannot establish absolute candidate executable path")
    bundle = binary.parent.parent.parent
    actual = describe(bundle)
    variants = [name for name, value in inventory["bundles"].items() if actual == value]
    if not variants:
        raise ValueError("selected bundle differs from built candidates")
    confirmed = sample(pid)
    if confirmed[0] != reading[0]:
        raise ValueError("process changed during candidate check")
    return reading[0], bundle, actual, variants


def check_process(pid, expected, sha):
    identity, bundle, actual, _ = expected
    exact_checkout(sha)
    if describe(bundle) != actual:
        raise ValueError("candidate on disk changed")
    reading = sample(pid)
    if reading[0] != identity:
        raise ValueError("selected process changed")
    return reading


def sample_row(reading, first, wall, first_wall):
    return {"elapsed_seconds": reading[1] - first[1],
            "wall_elapsed_seconds": wall - first_wall,
            "cpu_seconds_delta": reading[2] - first[2],
            "rss_bytes": reading[3] * 1024}


def validate_transition(previous, current, allowed_gap):
    for row in (previous, current):
        if (any(type(row[k]) not in (int, float) or not math.isfinite(row[k]) or row[k] < 0
                for k in ("elapsed_seconds", "wall_elapsed_seconds", "cpu_seconds_delta"))
                or type(row["rss_bytes"]) is not int or row["rss_bytes"] <= 0):
            raise ValueError("invalid observation")
    mono = current["elapsed_seconds"] - previous["elapsed_seconds"]
    wall = current["wall_elapsed_seconds"] - previous["wall_elapsed_seconds"]
    if (mono <= 0 or wall < 0 or max(mono, wall) > allowed_gap or
            current["cpu_seconds_delta"] < previous["cpu_seconds_delta"]):
        raise ValueError("observation gap, clock or CPU counter discontinuity")
    return max(mono, wall)


def observe(out, name, pid, expected, sha, seconds, interval):
    """Write private streaming evidence; an interruption cannot be a pass."""
    path = out / (name + ".jsonl")
    checkpoint = out / (name + ".json")
    status = {"status": "inconclusive", "samples": 0, "elapsed_seconds": 0,
              "max_gap_seconds": 0, "requested_seconds": seconds, "interval_seconds": interval,
              "binary_identity": "on_disk_content_and_ps_identity_only"}
    write_json(checkpoint, status)
    first = previous = None
    first_wall = None
    readings = []
    try:
        with path.open("x", encoding="utf-8") as stream:
            while True:
                current = check_process(pid, expected, sha)
                wall = time.time()
                if first is None:
                    first, first_wall = current, wall
                row = sample_row(current, first, wall, first_wall)
                if previous is not None:
                    gap = validate_transition(previous, row, interval + (10 if interval == 5 else 15))
                    status["max_gap_seconds"] = max(status["max_gap_seconds"], gap)
                else:
                    if row["rss_bytes"] <= 0:
                        raise ValueError("invalid initial RSS")
                stream.write(json.dumps(row, allow_nan=False) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
                status.update(samples=status["samples"] + 1, elapsed_seconds=row["elapsed_seconds"],
                              max_rss_bytes=max(status.get("max_rss_bytes", 0), row["rss_bytes"]))
                if interval == 5:
                    readings.append(current)
                write_json(checkpoint, status)
                if row["elapsed_seconds"] >= seconds:
                    break
                previous = row
                time.sleep(min(interval, max(0, seconds - row["elapsed_seconds"])))
        if interval == 5:
            metrics = performance_metrics(summarize(readings))
            status["metrics"] = metrics
            status["status"] = ("numeric_target_met_review_required"
                                if metrics["meets_observation_window"] and metrics["meets_numeric_target"]
                                else "numeric_target_not_met")
        else:
            status["status"] = "duration_met_review_required" if seconds == TARGET else "short_trial_only"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, ArithmeticError, KeyboardInterrupt):
        status["status"] = "inconclusive"
    finally:
        if path.exists():
            status["sha256"] = hashlib.sha256(read_private(path, LIMIT)).hexdigest()
        write_json(checkpoint, status)
    return status


def observation_evidence(out, name, seconds, interval):
    """Recompute duration, gaps and numeric metrics from recorded samples."""
    summary = strict_json(read_private(out / (name + ".json"), 256 * 1024))
    raw = read_private(out / (name + ".jsonl"), LIMIT)
    if hashlib.sha256(raw).hexdigest() != summary.get("sha256"):
        raise ValueError("observation digest mismatch")
    rows = [strict_json(line) for line in raw.splitlines()]
    if not 2 <= len(rows) <= 150_000:
        raise ValueError("invalid observation count")
    if summary.get("requested_seconds") != seconds or summary.get("interval_seconds") != interval:
        raise ValueError("observation plan mismatch")
    if any(rows[0][key] != 0 for key in ("elapsed_seconds", "wall_elapsed_seconds", "cpu_seconds_delta")):
        raise ValueError("nonzero initial observation")
    gap = max(validate_transition(a, b, interval + (10 if interval == 5 else 15))
              for a,b in zip(rows, rows[1:]))
    elapsed = rows[-1]["elapsed_seconds"]
    rss = max(row["rss_bytes"] for row in rows)
    if (elapsed < seconds or len(rows) != summary["samples"] or
            elapsed != summary["elapsed_seconds"] or rss != summary["max_rss_bytes"] or
            gap != summary["max_gap_seconds"]):
        raise ValueError("duration or summary mismatch")
    cpu = 100 * rows[-1]["cpu_seconds_delta"] / elapsed
    if interval == 5:
        target = cpu < 0.5 and rss < 80_000_000
        metrics = summary.get("metrics") or {}
        if (not metrics.get("meets_observation_window") or
                abs(metrics.get("cpu_percent_one_core", -1) - cpu) > 0.000051 or
                metrics.get("max_rss_bytes") != rss or
                metrics.get("meets_numeric_target") != target):
            raise ValueError("performance metrics mismatch")
        status = "numeric_target_met_review_required" if target else "numeric_target_not_met"
    else:
        status = "duration_met_review_required" if seconds == TARGET else "short_trial_only"
    if summary["status"] != status:
        raise ValueError("observation verdict mismatch")
    return {"status": status, "samples": len(rows), "elapsed_seconds": elapsed,
            "average_cpu_percent_one_core": round(cpu, 4), "max_rss_bytes": rss, "max_gap_seconds": gap,
            "sha256": summary["sha256"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, help="Explicit running candidate PID; otherwise prompt once after build")
    parser.add_argument("--trial-seconds", type=int, help="Short soak rehearsal, never full acceptance")
    args = parser.parse_args()
    if (platform.system() != "Darwin" or (args.pid is not None and args.pid <= 0) or
            (args.trial_seconds is not None and not 60 <= args.trial_seconds < TARGET)):
        parser.error("requires macOS, positive PID, and bounded short trial")
    os.umask(0o077)
    sha, clean = revision()
    if not clean:
        parser.error("requires clean checkout")
    out = new_run("unattended-")
    (out / "logs").mkdir(mode=0o700)
    automatic = out / "automatic"
    automatic.mkdir(mode=0o700)
    (automatic / "logs").mkdir(mode=0o700)
    seconds = TARGET if args.trial_seconds is None else args.trial_seconds
    report = {"schema_version": 1, "kind": "unattended_acceptance", "commit_sha": sha,
              "started_at": now(), "environment": environment(), "status": "inconclusive",
              "soak_requested_seconds": seconds, "full_device_acceptance": False,
              "release_authorized": False, "steps": {}, "observations": {},
              "manual_gates": [{"id": id, "status": "blocked" if id in BLOCKED_IDS else "review_required"}
                               for id in MANUAL_IDS]}
    path = out / "summary.json"
    write_json(path, report)
    print("Private acceptance directory: " + str(out.relative_to(ROOT)), flush=True)
    try:
        execute(SimpleNamespace(profile="host", pid=None, traffic_evidence=None,
                                benchmark_seconds=300), automatic, sha, clean)
        auto = verify(automatic, sha)
        report["automatic"] = auto
        write_json(path, report)
        results = {row["id"]: row["status"] for row in auto["step_statuses"]}
        if any(results.get(id) != "pass" for id in CORE_STEPS):
            raise ValueError("core tests did not pass")
        if any(state == "fail" for state in results.values()):
            raise ValueError("host test failed")
        for name, argv in (
            ("isolated_install", [sys.executable, "scripts/verify_install_candidate.py",
                                  "--app", "build/NCHUTraffic.app", "--app", "build/module/NCHUTraffic.app"]),
            ("isolated_lifecycle", [sys.executable, "scripts/verify_lifecycle_candidate.py",
                                    "--app", "build/NCHUTraffic.app"])):
            exact_checkout(sha)
            result = run_step(out, name, argv, 180)
            report["steps"][name] = result
            write_json(path, report)
            if result["status"] != "pass":
                raise ValueError("isolated test did not pass")
        inventory = collect(sha)
        report["candidate_inventory"] = inventory
        write_json(path, report)
        print("Builds ready. Open the reviewed candidate app yourself, close its panels, "
              "and choose its PID from Activity Monitor.", flush=True)
        pid = args.pid if args.pid is not None else int(input("Candidate PID: ").strip())
        if pid <= 0:
            raise ValueError("invalid PID")
        expected = identity_of(pid, inventory)
        report["matched_candidate_variants"] = expected[3]
        report["binary_identity"] = "on_disk_content_and_ps_identity_only"
        write_json(path, report)
        for index in range(PERFORMANCE_WINDOWS):
            name = "idle_" + str(index + 1)
            print("Observing " + name, flush=True)
            result = observe(out, name, pid, expected, sha, PERFORMANCE_SECONDS, 5)
            report["observations"][name] = result
            write_json(path, report)
            if result["status"] == "inconclusive":
                raise ValueError("idle observation interrupted")
            report["observations"][name] = observation_evidence(out, name, PERFORMANCE_SECONDS, 5)
            write_json(path, report)
        print("Starting continuous soak; leave the candidate running.", flush=True)
        result = observe(out, "soak", pid, expected, sha, seconds, SOAK_INTERVAL)
        report["observations"]["soak"] = result
        write_json(path, report)
        if result["status"] == "inconclusive":
            raise ValueError("soak interrupted")
        report["observations"]["soak"] = observation_evidence(out, "soak", seconds, SOAK_INTERVAL)
        exact_checkout(sha)
        check_process(pid, expected, sha)
        if collect(sha) != inventory:
            raise ValueError("built candidate inventory changed")
        if any(report["observations"]["idle_" + str(i+1)]["status"] != "numeric_target_met_review_required"
               for i in range(PERFORMANCE_WINDOWS)):
            report["status"] = "numeric_target_not_met"
        elif seconds != TARGET:
            report["status"] = "short_trial_only"
        else:
            report["status"] = "observations_complete_review_required"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, ArithmeticError, KeyboardInterrupt, EOFError):
        report["status"] = "inconclusive"
    finally:
        report["finished_at"] = now()
        write_json(path, report)
        print("Private acceptance summary: " + str(path.relative_to(ROOT)), flush=True)
        print("Result: " + report["status"] + "; full device acceptance not granted", flush=True)
    return 0 if report["status"] == "observations_complete_review_required" else 2


if __name__ == "__main__":
    raise SystemExit(main())
