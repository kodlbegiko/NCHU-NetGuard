#!/usr/bin/env python3
"""One supervised setup, followed by unattended, read-only candidate validation.

Never launches/restarts an app, changes sleep settings, modifies network routes,
generates controlled traffic, or operates on the user's installation.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import shlex
import sqlite3
import diagnostics
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
from verify_report import verify, read_private, strict_json, owned_directory, timestamp
from soak_test import TARGET
sys.path.insert(0, str(ROOT / "scripts"))
from benchmark_device import sample, summarize
from candidate_inventory import collect, describe

PERFORMANCE_WINDOWS = 3
PERFORMANCE_SECONDS = 300
SOAK_INTERVAL = 60
REGRESSION_PERIOD = 6 * 3600


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


HEALTH_MAX_AGE = 15
HEALTH_COUNTS = ("tick_count", "sample_cycles", "measured_cycles", "save_successes", "safety_hold_ticks")
HEALTH_FLAGS = ("sleeping", "clock_held", "persistence_blocked", "accounting_overflow", "history_healthy")
HEALTH_TIMES = ("wall_seconds", "max_tick_gap_seconds", "max_tick_duration_seconds",
                "sample_age_seconds", "save_age_seconds", "max_sample_age_seconds", "max_save_gap_seconds")
HEALTH_KEYS = {"schema_version", "day", "received", "sent", "busy_seconds", "max_busy_seconds",
               *HEALTH_COUNTS, *HEALTH_FLAGS, *HEALTH_TIMES}


def validate_health(health, wall):
    if (not isinstance(health, dict) or set(health) != HEALTH_KEYS or
            type(health["schema_version"]) is not int or health["schema_version"] != 1):
        raise ValueError("heartbeat schema")
    for key in HEALTH_COUNTS + ("received", "sent"):
        if type(health[key]) is not int or not 0 <= health[key] <= 9_007_199_254_740_991:
            raise ValueError("invalid heartbeat counter")
    if (health["tick_count"] < 1 or health["sample_cycles"] > health["tick_count"] or
            health["measured_cycles"] > health["sample_cycles"] or
            health["received"] + health["sent"] > 9_007_199_254_740_991):
        raise ValueError("heartbeat counter invariant")
    for key in HEALTH_TIMES:
        value = health[key]
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise ValueError("invalid or unavailable heartbeat timing")
    if (type(wall) not in (int, float) or not math.isfinite(wall) or
            not -2 <= wall - health["wall_seconds"] <= HEALTH_MAX_AGE or
            health["max_tick_gap_seconds"] > 15 or health["max_tick_duration_seconds"] > 15 or
            health["sample_age_seconds"] > 5 or health["save_age_seconds"] > 30 or
            health["max_sample_age_seconds"] > 5 or health["max_save_gap_seconds"] > 30):
        raise ValueError("stalled heartbeat, sample or persistence")
    if (any(type(health[key]) is not bool for key in HEALTH_FLAGS) or
            any(health[key] for key in HEALTH_FLAGS[:-1]) or not health["history_healthy"] or
            health["safety_hold_ticks"] != 0):
        raise ValueError("app safety hold or persistence failure")
    for field in ("busy_seconds", "max_busy_seconds"):
        busy = health[field]
        if (not isinstance(busy, dict) or set(busy) != {"route", "apps", "ping", "provider", "dns"} or
                any(type(v) not in (int, float) or not math.isfinite(v) or not 0 <= v <= 60
                    for v in busy.values())):
            raise ValueError("background probe stalled")
    if any(health["busy_seconds"][k] > health["max_busy_seconds"][k] for k in health["busy_seconds"]):
        raise ValueError("busy maximum inconsistent")
    day = dt.date.fromisoformat(health["day"])
    if day.isoformat() != health["day"]:
        raise ValueError("invalid heartbeat day")
    return health


def read_health(directory, pid, wall):
    owned_directory(directory)
    value = strict_json(read_private(directory / "heartbeat.json", 16_384))
    if not isinstance(value, dict) or type(value.get("pid")) is not int or value.pop("pid") != pid:
        raise ValueError("heartbeat does not belong to selected PID")
    return validate_health(value, wall)


def health_transition(previous, current):
    a, b = previous["health"], current["health"]
    if (any(b[k] < a[k] for k in HEALTH_COUNTS) or b["day"] < a["day"] or
            b["wall_seconds"] < a["wall_seconds"] or
            b["max_tick_gap_seconds"] < a["max_tick_gap_seconds"] or
            any(b[k] < a[k] for k in ("max_tick_duration_seconds", "max_sample_age_seconds", "max_save_gap_seconds")) or
            any(b["max_busy_seconds"][k] < a["max_busy_seconds"][k] for k in a["max_busy_seconds"])):
        raise ValueError("heartbeat rollback")
    if b["tick_count"] == a["tick_count"] and b != a:
        raise ValueError("heartbeat changed without new tick")
    if b["day"] == a["day"] and any(b[k] < a[k] for k in ("received", "sent")):
        raise ValueError("daily ledger regressed")
    if current["elapsed_seconds"] - previous["elapsed_seconds"] >= 30:
        if any(b[k] <= a[k] for k in ("tick_count", "sample_cycles", "save_successes")):
            raise ValueError("main loop, sample or save progress stopped")


def health_summary(rows):
    first, last = rows[0]["health"], rows[-1]["health"]
    if any(last[k] <= first[k] for k in ("tick_count", "sample_cycles", "save_successes")):
        raise ValueError("no functional progress")
    rollovers = sum(a["health"]["day"] != b["health"]["day"] for a,b in zip(rows, rows[1:]))
    return {"ticks": last["tick_count"] - first["tick_count"],
            "sample_cycles": last["sample_cycles"] - first["sample_cycles"],
            "measured_cycles": last["measured_cycles"] - first["measured_cycles"],
            "successful_saves": last["save_successes"] - first["save_successes"],
            "observed_day_transitions": rollovers,
            "max_tick_gap_seconds": last["max_tick_gap_seconds"],
            "max_tick_duration_seconds": last["max_tick_duration_seconds"],
            "max_sample_age_seconds": last["max_sample_age_seconds"],
            "max_save_gap_seconds": last["max_save_gap_seconds"],
            "max_busy_seconds": last["max_busy_seconds"], "safety_hold_ticks": last["safety_hold_ticks"],
            "measurement_evidence": ("observed" if last["measured_cycles"] > first["measured_cycles"]
                                     else "no_measured_cycles_review_required")}


def regression_cycle(out, index, sha):
    exact_checkout(sha)
    rows = []
    for suffix, argv, timeout in (
        ("python", ["make", "test"], 180),
        ("swift", ["swift", "test", "--skip-build"], 600)):
        name = "regression_%02d_%s" % (index, suffix)
        result = run_step(out, name, argv, timeout)
        rows.append(result)
        if result["status"] != "pass":
            break
    exact_checkout(sha)
    return rows


def review_regressions(out, seconds):
    data = strict_json(read_private(out / "regressions.json", 256 * 1024))
    expected = (seconds - 1) // REGRESSION_PERIOD + 1
    if not isinstance(data, list) or len(data) != expected:
        raise ValueError("incomplete regression schedule")
    for index, item in enumerate(data):
        at = item["started_elapsed_seconds"]
        due = index * REGRESSION_PERIOD
        if (type(at) not in (int, float) or not math.isfinite(at) or
                not due <= at <= due + 75 or item["index"] != index):
            raise ValueError("regression schedule mismatch")
        rows = item["steps"]
        if len(rows) != 2:
            raise ValueError("incomplete regression cycle")
        for suffix, row in zip(("python", "swift"), rows):
            name = "regression_%02d_%s" % (index, suffix)
            raw = read_private(out / "logs" / (name + ".log"), LIMIT)
            if (row["id"] != name or row["status"] != "pass" or row["exit_code"] != 0 or
                    row["log"] != "logs/" + name + ".log" or
                    hashlib.sha256(raw).hexdigest() != row["log_sha256"]):
                raise ValueError("regression evidence mismatch")
    return {"cycles": expected, "steps": expected * 2, "status": "recorded_pass",
            "period_seconds": REGRESSION_PERIOD}


def fixture_timing(out):
    expected = {"Smoke · Quick panel", "Smoke · Settings", "Smoke · Management", "Smoke · History"}
    result = {}
    for name in ("legacy", "module"):
        raw = read_private(out / "automatic" / "logs" / (name + "_smoke.log"), LIMIT)
        prefix = b"NETGUARD_FIXTURE_TIMING "
        lines = [line[len(prefix):] for line in raw.splitlines() if line.startswith(prefix)]
        if len(lines) != 1:
            raise ValueError("missing fixture UI timing")
        data = strict_json(lines[0])
        if set(data) != expected or any(
                set(item) != {"construction_ms", "layout_ms"} or
                any(type(v) not in (int,float) or not math.isfinite(v) or v < 0 for v in item.values())
                for item in data.values()):
            raise ValueError("invalid fixture UI timing")
        result[name] = data
    return {"variants": result, "scope": "fixture_construction_and_layout_not_production_open_latency"}


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
    resource_at = history_at = None
    previous_day = None
    pool = ThreadPoolExecutor(max_workers=1) if interval == SOAK_INTERVAL else None
    future = None
    regression_runs = []
    pending = None

    def finish_cycle():
        nonlocal future, pending
        if future is not None:
            pending["steps"] = future.result()
            regression_runs.append(pending)
            write_json(out / "regressions.json", regression_runs)
            future = pending = None
            if len(regression_runs[-1]["steps"]) != 2 or any(
                    step["status"] != "pass" for step in regression_runs[-1]["steps"]):
                raise ValueError("periodic regression failed")

    try:
        with path.open("x", encoding="utf-8") as stream:
            while True:
                current = check_process(pid, expected, sha)
                wall = time.time()
                if first is None:
                    first, first_wall = current, wall
                row = sample_row(current, first, wall, first_wall)
                row["sample_wall_seconds"] = wall
                row["health"] = read_health(out / "health", pid, wall)
                if previous is not None:
                    health_transition(previous, row)
                    gap = validate_transition(previous, row, interval + (10 if interval == 5 else 15))
                    status["max_gap_seconds"] = max(status["max_gap_seconds"], gap)
                else:
                    if row["rss_bytes"] <= 0:
                        raise ValueError("invalid initial RSS")
                # Extra probes only during soak, never the idle benchmark.
                if interval == SOAK_INTERVAL:
                    elapsed = row["elapsed_seconds"]
                    if future is not None and future.done():
                        finish_cycle()
                    index = len(regression_runs)
                    if index * REGRESSION_PERIOD < seconds and elapsed >= index * REGRESSION_PERIOD:
                        if future is None:
                            pending = {"index": index, "started_elapsed_seconds": elapsed}
                            future = pool.submit(regression_cycle, out, index, sha)
                        elif elapsed >= (index + 1) * REGRESSION_PERIOD:
                            raise ValueError("periodic regression exceeded schedule")
                    rollover = previous_day is not None and previous_day["day"] != row["health"]["day"]
                    if resource_at is None or elapsed - resource_at >= 300:
                        row["resources"] = diagnostics.resources(pid, first_wall)
                        resource_at = elapsed
                    if history_at is None or elapsed - history_at >= 3600 or rollover:
                        row["persisted_state"] = diagnostics.inspect_state(Path.home() / ".nchu_traffic_state.json")
                        days = [previous_day["day"]] if rollover else []
                        try:
                            row["history"] = diagnostics.inspect_history(
                                Path.home() / "Library/Application Support/NCHU-NetGuard/history.sqlite", days)
                        except sqlite3.OperationalError:
                            row["history"] = {"status": "busy_or_unavailable_review_required", "days": {}, "database_bytes": None}
                        if rollover:
                            row["rollover"] = diagnostics.rollover_evidence(row["history"], previous_day)
                            if row["rollover"] == "observed_lower_bound_mismatch":
                                raise ValueError("finalized history lost observed bytes")
                        history_at = elapsed
                    previous_day = row["health"]
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
                # Include diagnostics and logging in the sampling deadline,
                # rather than adding their elapsed time to every sleep.
                time.sleep(max(0, min(interval, seconds - row["elapsed_seconds"]) -
                               (time.monotonic() - current[1])))
        if future is not None:
            finish_cycle()
        if interval == SOAK_INTERVAL:
            review_regressions(out, seconds)
        if interval == 5:
            metrics = performance_metrics(summarize(readings))
            status["metrics"] = metrics
            status["status"] = ("numeric_target_met_review_required"
                                if metrics["meets_observation_window"] and metrics["meets_numeric_target"]
                                else "numeric_target_not_met")
        else:
            status["status"] = "duration_met_review_required" if seconds == TARGET else "short_trial_only"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, ArithmeticError, KeyboardInterrupt, KeyError, TypeError, sqlite3.Error) as error:
        status["status"] = "inconclusive"
        status["failure_type"] = type(error).__name__
        # Only fixed diagnostic strings are retained, never arbitrary errors
        # from subprocess, file paths, SQLite or user data.
        codes = {"stalled heartbeat, sample or persistence": "health_stalled",
                 "app safety hold or persistence failure": "safety_hold",
                 "background probe stalled": "probe_stalled",
                 "heartbeat rollback": "heartbeat_rollback",
                 "daily ledger regressed": "ledger_regressed",
                 "main loop, sample or save progress stopped": "functional_progress_stalled",
                 "observation gap, clock or CPU counter discontinuity": "observation_discontinuity",
                 "candidate on disk changed": "bundle_changed",
                 "selected process changed": "process_changed",
                 "checkout changed": "revision_changed",
                 "finalized history lost observed bytes": "history_lower_bound_mismatch",
                 "periodic regression failed": "regression_failed"}
        status["failure_code"] = codes.get(str(error), "unclassified_review_required")
        status["failure_observed_at"] = now()
    finally:
        if pool is not None:
            # The only active worker runs bounded fixture tests; never kills
            # the selected application. Its current command may finish first.
            pool.shutdown(wait=True, cancel_futures=True)
        if path.exists():
            status["sha256"] = hashlib.sha256(read_private(path, LIMIT)).hexdigest()
        write_json(checkpoint, status)
    return status


def diagnostic_summary(rows):
    resources = []
    history = []
    rollovers = []
    resource_at = history_at = None
    previous = None
    previous_state = None
    for row in rows:
        elapsed = row["elapsed_seconds"]
        rollover = previous is not None and previous["day"] != row["health"]["day"]
        if resource_at is None or elapsed - resource_at >= 300:
            resources.append(diagnostics.validate_resources(row["resources"]))
            resource_at = elapsed
        elif "resources" in row:
            raise ValueError("unexpected resource sample")
        if history_at is None or elapsed - history_at >= 3600 or rollover:
            state = row["persisted_state"]
            diagnostics.canonical_day(state["day"])
            if (diagnostics.byte_count(state["received"]) + diagnostics.byte_count(state["sent"]) !=
                    diagnostics.byte_count(state["total"])):
                raise ValueError("invalid persisted directional total")
            diagnostics.byte_count(state["measured_samples"])
            if previous_state is not None:
                if (state["day"] < previous_state["day"] or (state["day"] == previous_state["day"] and
                    any(state[k] < previous_state[k] for k in ("received","sent","measured_samples")))):
                    raise ValueError("persisted state regressed")
            previous_state = state
            item = row["history"]
            if item["status"] not in ("snapshot_validated", "not_present", "sidecar_present_review_required",
                                      "busy_or_unavailable_review_required"):
                raise ValueError("invalid history status")
            size = item["database_bytes"]
            if size is not None and (type(size) is not int or not 0 <= size <= diagnostics.MAX_BYTES):
                raise ValueError("invalid database size")
            history.append(item)
            if rollover:
                expected = diagnostics.rollover_evidence(item, previous)
                if row["rollover"] != expected or expected == "observed_lower_bound_mismatch":
                    raise ValueError("invalid rollover evidence")
                rollovers.append(expected)
            history_at = elapsed
        elif any(k in row for k in ("history", "persisted_state", "rollover")):
            raise ValueError("unexpected database sample")
        previous = row["health"]
    counters = {}
    for key in diagnostics.CUMULATIVE_RESOURCES:
        values = [r[key] for r in resources if r[key] is not None]
        if any(b < a for a,b in zip(values, values[1:])):
            raise ValueError("native resource counter regressed")
        counters[key] = values[-1] - values[0] if len(values) >= 2 else None
    peak_cpu = max(100 * (b["cpu_seconds_delta"] - a["cpu_seconds_delta"]) /
                   (b["elapsed_seconds"] - a["elapsed_seconds"]) for a,b in zip(rows, rows[1:]))
    return {"resource_samples": len(resources),
            "peak_sample_interval_cpu_percent_one_core": round(peak_cpu, 4),
            "native_counter_deltas": counters,
            "resources": {key: diagnostics.trend([r[key] for r in resources]) for key in resources[0]},
            "rss_bytes": diagnostics.trend([r["rss_bytes"] for r in rows]),
            "history_samples": len(history),
            "history_validated_samples": sum(r["status"] == "snapshot_validated" for r in history),
            "database_bytes": diagnostics.trend([r["database_bytes"] for r in history]),
            "rollovers": rollovers, "interpretation": "sampled_trends_not_leak_or_full_integrity_proof"}


def observation_evidence(out, name, seconds, interval, *, require_health=False):
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
    health = None
    if require_health:
        for row in rows:
            validate_health(row["health"], row["sample_wall_seconds"])
        for a,b in zip(rows, rows[1:]):
            health_transition(a, b)
        health = health_summary(rows)
    if interval == 5:
        target = round(cpu, 4) < 0.5 and rss < 80_000_000
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
    result = {"status": status, "samples": len(rows), "elapsed_seconds": elapsed,
              "average_cpu_percent_one_core": round(cpu, 4), "max_rss_bytes": rss, "max_gap_seconds": gap,
              "sha256": summary["sha256"]}
    if require_health:
        result["functional_health"] = health
        if interval == SOAK_INTERVAL:
            result["periodic_diagnostics"] = diagnostic_summary(rows)
            result["periodic_regressions"] = review_regressions(out, seconds)
    return result


def review_completed(out, expected_sha):
    """Verify completed evidence without using any live PID or network probe."""
    owned_directory(out)
    owned_directory(out / "logs")
    report = strict_json(read_private(out / "summary.json", 256 * 1024))
    sha = report["commit_sha"]
    if (report["schema_version"] != 2 or report["kind"] != "unattended_acceptance" or
            sha != expected_sha or report["full_device_acceptance"] is not False or
            report["release_authorized"] is not False or
            timestamp(report["finished_at"]) < timestamp(report["started_at"])):
        raise ValueError("invalid acceptance report")
    auto = verify(out / "automatic", sha)
    if auto != report["automatic"]:
        raise ValueError("automatic summary mismatch")
    if fixture_timing(out) != report["fixture_ui_timing"]:
        raise ValueError("fixture timing mismatch")
    results = {row["id"]: row["status"] for row in auto["step_statuses"]}
    if (any(results.get(id) != "pass" for id in CORE_STEPS) or
            any(state == "fail" for state in results.values())):
        raise ValueError("core or host failure")
    if report["manual_gates"] != [{"id": id, "status": "blocked" if id in BLOCKED_IDS else "review_required"}
                                   for id in MANUAL_IDS]:
        raise ValueError("manual gate mismatch")
    markers = {"isolated_install": "NETGUARD_ISOLATED_INSTALL_OK bundles=2",
               "isolated_lifecycle": "NETGUARD_LIFECYCLE_REHEARSAL_OK exchange rollback conflict quarantine synthetic-data"}
    if set(report["steps"]) != set(markers):
        raise ValueError("isolated step inventory mismatch")
    for name, marker in markers.items():
        row = report["steps"][name]
        raw = read_private(out / "logs" / (name + ".log"), LIMIT)
        if (row["id"] != name or row["status"] != "pass" or row["exit_code"] != 0 or
                row["log"] != "logs/" + name + ".log" or
                hashlib.sha256(raw).hexdigest() != row["log_sha256"] or marker.encode() not in raw.splitlines()):
            raise ValueError("isolated step not demonstrated")
    inventory = report["candidate_inventory"]
    if (inventory["commit_sha"] != sha or inventory["release_authorized"] is not False or
            inventory["full_device_acceptance"] is not False or set(inventory["bundles"]) != {"legacy", "module"} or
            not report["matched_candidate_variants"] or
            not set(report["matched_candidate_variants"]) <= set(inventory["bundles"])):
        raise ValueError("candidate inventory mismatch")
    seconds = report["soak_requested_seconds"]
    if type(seconds) is not int or not 60 <= seconds <= TARGET:
        raise ValueError("invalid soak duration")
    expected = {"idle_" + str(i + 1): (PERFORMANCE_SECONDS, 5) for i in range(PERFORMANCE_WINDOWS)}
    expected["soak"] = (seconds, SOAK_INTERVAL)
    if set(report["observations"]) != set(expected):
        raise ValueError("incomplete observation plan")
    observations = {name: observation_evidence(out, name, *plan, require_health=True)
                    for name, plan in expected.items()}
    if observations != report["observations"]:
        raise ValueError("observation summary mismatch")
    failed = any(observations[name]["status"] != "numeric_target_met_review_required"
                 for name in expected if name != "soak")
    verdict = ("numeric_target_not_met" if failed else
               "short_trial_only" if seconds != TARGET else "observations_complete_review_required")
    if report["status"] != verdict:
        raise ValueError("unattended verdict mismatch")
    return {"commit_sha": sha, "status": verdict, "observations": observations,
            "automatic": auto, "fixture_ui_timing": report["fixture_ui_timing"],
            "manual_gates": report["manual_gates"],
            "full_device_acceptance": False, "release_authorized": False,
            "integrity_scope": "local_consistency_only_not_authenticity"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trial-seconds", type=int, help="Short soak rehearsal, never full acceptance")
    parser.add_argument("--verify", type=Path, help="Review an existing completed private run instead of testing")
    parser.add_argument("--expected-sha", help="Exact source SHA required for report review")
    args = parser.parse_args()
    if args.verify is not None:
        if not args.expected_sha or args.trial_seconds is not None:
            parser.error("report review requires exact SHA and no execution options")
        try:
            result = review_completed(args.verify, args.expected_sha)
            print(json.dumps(result, indent=2))
            return 0 if result["status"] == "observations_complete_review_required" else 2
        except (OSError, ValueError, TypeError, KeyError, IndexError, OverflowError):
            print(json.dumps({"status": "invalid_or_incomplete_evidence", "full_device_acceptance": False}))
            return 2
    if args.expected_sha is not None:
        parser.error("expected SHA is only for report review")
    if (platform.system() != "Darwin" or
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
    report = {"schema_version": 2, "kind": "unattended_acceptance", "commit_sha": sha,
              "started_at": now(), "environment": environment(), "status": "inconclusive",
              "soak_requested_seconds": seconds, "full_device_acceptance": False,
              "release_authorized": False, "steps": {}, "observations": {},
              "manual_gates": [{"id": id, "status": "blocked" if id in BLOCKED_IDS else "review_required"}
                               for id in MANUAL_IDS]}
    path = out / "summary.json"
    write_json(path, report)
    health_directory = out / "health"
    health_directory.mkdir(mode=0o700)
    print("Private acceptance directory: " + str(out.relative_to(ROOT)), flush=True)
    try:
        execute(SimpleNamespace(profile="host", pid=None, traffic_evidence=None,
                                benchmark_seconds=300), automatic, sha, clean)
        auto = verify(automatic, sha)
        report["automatic"] = auto
        report["fixture_ui_timing"] = fixture_timing(out)
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
            marker = ("NETGUARD_ISOLATED_INSTALL_OK bundles=2" if name == "isolated_install" else
                      "NETGUARD_LIFECYCLE_REHEARSAL_OK exchange rollback conflict quarantine synthetic-data")
            result = run_step(out, name, argv, 180, marker=marker)
            report["steps"][name] = result
            write_json(path, report)
            if result["status"] != "pass":
                raise ValueError("isolated test did not pass")
        inventory = collect(sha)
        report["candidate_inventory"] = inventory
        write_json(path, report)
        print("Builds ready. Quit any existing NetGuard normally. In a second terminal run:", flush=True)
        print("/usr/bin/open -a " + shlex.quote(str(ROOT / "build/NCHUTraffic.app")) +
              " --args --netguard-qa-health-dir " + shlex.quote(str(health_directory)), flush=True)
        print("Wait for the candidate to start, close its panels, and find its PID in Activity Monitor.", flush=True)
        pid = int(input("Candidate PID: ").strip())
        if pid <= 0:
            raise ValueError("invalid PID")
        expected = identity_of(pid, inventory)
        # Allow the first periodic save and heartbeat to become available.
        deadline = time.monotonic() + 30
        while True:
            try:
                read_health(health_directory, pid, time.time())
                break
            except (OSError, ValueError, TypeError, KeyError):
                if time.monotonic() >= deadline:
                    raise ValueError("candidate heartbeat unavailable")
                time.sleep(1)
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
            report["observations"][name] = observation_evidence(out, name, PERFORMANCE_SECONDS, 5, require_health=True)
            write_json(path, report)
        print("Starting continuous soak; leave the candidate running.", flush=True)
        result = observe(out, "soak", pid, expected, sha, seconds, SOAK_INTERVAL)
        report["observations"]["soak"] = result
        write_json(path, report)
        if result["status"] == "inconclusive":
            raise ValueError("soak interrupted")
        report["observations"]["soak"] = observation_evidence(out, "soak", seconds, SOAK_INTERVAL, require_health=True)
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
    if report["status"] == "observations_complete_review_required":
        try:
            review_completed(out, sha)
        except (OSError, ValueError, TypeError, KeyError, IndexError, OverflowError):
            report["status"] = "inconclusive"
            write_json(path, report)
            print("Final evidence review failed; no complete observation claim.", flush=True)
    return 0 if report["status"] == "observations_complete_review_required" else 2


if __name__ == "__main__":
    raise SystemExit(main())
