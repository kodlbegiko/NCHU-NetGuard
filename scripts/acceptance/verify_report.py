#!/usr/bin/env python3
"""Verify local report structure, log digests and plan; emit a limited review summary."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import stat
from pathlib import Path

from run_all import (BLOCKED_IDS, MANUAL_IDS, automatic_exit, planned_steps,
                     LIMIT, performance_metrics)

MAX_JSON = 256 * 1024
MARKERS = {
    "legacy_smoke": "NETGUARD_SMOKE_OK fixture-native-views=4 status-item=1 resources=2",
    "module_smoke": "NETGUARD_SMOKE_OK fixture-native-views=4 status-item=1 resources=2",
    "host_compatibility": "NETGUARD_HOST_CHECK_OK",
    "tcp_observation": "NETGUARD_TCP_FLOW_CHECK_OK",
    "udp_observation": "NETGUARD_UDP_FLOW_CHECK_OK",
}
STATES = {"pass", "fail", "inconclusive", "skipped", "blocked"}

def require(condition, reason):
    if not condition:
        raise ValueError(reason)

def owned_directory(path):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid()
            and not info.st_mode & 0o077, "unsafe_directory")

def read_private(path, cap):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                and info.st_uid == os.geteuid() and not info.st_mode & 0o077
                and info.st_size <= cap, "unsafe_or_oversized_file")
        raw = stream.read(cap + 1)
        require(len(raw) <= cap, "oversized_file")
        return raw

def strict_json(raw):
    def pairs(items):
        result = {}
        for k, v in items:
            require(k not in result, "duplicate_json_field")
            result[k] = v
        return result
    def invalid_constant(_):
        raise ValueError("nonfinite_json_constant")
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid_constant)

def timestamp(value):
    require(isinstance(value, str), "invalid_timestamp")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timezone_required")
    return parsed

def verify(directory, expected_sha=None):
    directory = Path(directory)
    owned_directory(directory)
    report = strict_json(read_private(directory / "summary.json", MAX_JSON))
    env = strict_json(read_private(directory / "environment.json", MAX_JSON))
    require(isinstance(report, dict) and type(report.get("schema_version")) is int
            and report["schema_version"] == 2 and report.get("kind") == "local_automatic",
            "unsupported_report_version")
    require(report.get("full_device_acceptance") is False, "invalid_acceptance_claim")
    sha = report["commit_sha"]
    require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha), "invalid_sha")
    require(expected_sha is None or sha == expected_sha, "revision_mismatch")
    require(timestamp(report["finished_at"]) >= timestamp(report["started_at"]), "unfinished_or_reversed_time")
    require(env == report["environment"] and isinstance(env, dict), "environment_mismatch")
    require(set(env) == {"os", "os_version", "architecture", "python", "hardware_model"}, "environment_shape")
    for key, val in env.items():
        require((key == "hardware_model" and val is None) or
                (isinstance(val, str) and len(val) <= 128 and
                 re.fullmatch(r"[A-Za-z0-9.,_+() -]+", val)), "environment_value")
    options = report["options"]
    require(isinstance(options, dict) and set(options) == {"performance", "traffic"}, "invalid_options")
    expected = planned_steps(report["profile"], **options)
    require(report["planned_steps"] == list(expected), "plan_mismatch")
    gates = [{"id": id, "status": "blocked" if id in BLOCKED_IDS else "review_required"}
             for id in MANUAL_IDS]
    require(report["manual_gates"] == gates, "manual_gate_mismatch")
    flags = ("clean_at_start", "clean_at_end", "same_revision_at_end")
    require(all(type(report[k]) is bool for k in flags), "invalid_revision_flags")
    rows = report["steps"]
    require(isinstance(rows, list) and len(rows) <= len(expected) + 1, "invalid_steps")
    owned_directory(directory / "logs")
    seen, actual, checked = set(), [], 0
    for step in rows:
        require(isinstance(step, dict), "invalid_step")
        id, status, reason = (step[k] for k in ("id", "status", "reason"))
        require(isinstance(id, str) and id not in seen and
                id in expected + ("interruption", "runner_error"), "invalid_or_duplicate_step")
        seen.add(id)
        if id in expected:
            actual.append(id)
        require(isinstance(status, str) and status in STATES and
                isinstance(reason, str) and re.fullmatch(r"[a-z0-9_]{1,80}", reason), "invalid_step_status")
        has_log = any(k in step for k in ("log", "log_sha256", "exit_code", "duration_seconds"))
        if has_log:
            require(step.get("log") == "logs/" + id + ".log", "invalid_log_path")
            digest = step.get("log_sha256")
            require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), "invalid_digest")
            raw = read_private(directory / "logs" / (id + ".log"), LIMIT)
            require(hashlib.sha256(raw).hexdigest() == digest, "log_digest_mismatch")
            checked += 1
            duration, code = step.get("duration_seconds"), step.get("exit_code")
            require(type(duration) in (int, float) and math.isfinite(duration) and duration >= 0
                    and (code is None or type(code) is int), "invalid_execution_metadata")
            if status == "pass":
                require(code == 0, "pass_with_nonzero_exit")
                if id in MARKERS:
                    require(MARKERS[id].encode() in raw.splitlines(), "missing_success_marker")
                if id in ("coverage", "performance"):
                    # Use the already checked bytes, not a second untrusted pathname read.
                    data = strict_json(raw.splitlines()[0] if id == "coverage" else raw)
                    if id == "coverage":
                        total, covered = data["executable_lines"], data["covered_lines"]
                        require(type(total) is int and type(covered) is int and
                                0 <= covered <= total and total > 0 and covered * 100 >= total * 90
                                and data["complete_inventory"] is True and data["meets_target"] is True,
                                "coverage_not_demonstrated")
                    else:
                        metrics = performance_metrics(data)
                        require(metrics["meets_numeric_target"] and metrics["meets_observation_window"],
                                "performance_not_demonstrated")
                        require(step.get("metrics") == metrics, "performance_summary_mismatch")
                if id == "traffic_numeric":
                    data = strict_json(raw)
                    require(data.get("meets_numeric_target") is True and
                            data.get("independence") == "caller_asserted_not_verified",
                            "traffic_target_not_demonstrated")
        elif status == "pass":
            require(id == "preflight" and reason == "clean_macos_checkout"
                    and env["os"] == "Darwin", "pass_without_log")
        if id in ("interruption", "runner_error"):
            require(status == "inconclusive" and step is rows[-1], "invalid_terminal_step")
    require(actual == [id for id in expected if id in seen], "out_of_order_steps")
    verdict = automatic_exit(rows, all(report[k] for k in flags), expected)
    require(type(report["automatic_exit_code"]) is int and verdict == report["automatic_exit_code"],
            "verdict_mismatch")
    return {"schema_version": 1, "kind": "local_review_summary",
            "commit_sha": sha, "profile": report["profile"],
            "automatic_exit_code": verdict, "steps_recorded": len(rows),
            "planned_steps": len(expected), "verified_log_digests": checked,
            "step_statuses": [{"id": x["id"], "status": x["status"]} for x in rows],
            "review_status": "review_required", "full_device_acceptance": False,
            "integrity_scope": "local_consistency_only_not_authenticity"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--expected-sha")
    args = parser.parse_args()
    try:
        result = verify(args.directory, args.expected_sha)
    except (OSError, ValueError, TypeError, KeyError, IndexError, RecursionError, OverflowError):
        print(json.dumps({"status":"invalid_or_incomplete_evidence", "full_device_acceptance":False}))
        return 2
    print(json.dumps(result, indent=2))
    return result["automatic_exit_code"]

if __name__ == "__main__":
    raise SystemExit(main())
