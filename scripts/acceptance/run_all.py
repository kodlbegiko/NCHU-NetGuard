#!/usr/bin/env python3
"""Local acceptance orchestrator. No installation, privilege elevation or network mutations."""
import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIMIT = 16 * 1024 * 1024
MANUAL_IDS = ("traffic_accuracy", "vpn_deduplication", "dual_stack",
              "network_switching", "sleep_wake", "workflow_identity",
              "provider_accounting", "security_review", "recovery",
              "performance_idle", "accessibility", "novice_ux",
              "lifecycle", "soak_168h", "extension")

BLOCKED_IDS = frozenset(("recovery", "lifecycle", "extension"))

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, timeout=15,
                                   stderr=subprocess.DEVNULL).decode("utf-8", "strict").strip()

def revision():
    sha = git("rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("invalid revision")
    return sha, not bool(git("status", "--porcelain=v1", "--untracked-files=normal"))

def private_root():
    path = ROOT / "test-results"
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise OSError("test-results must be a private, owned real directory (mode 700)")
    return path

def new_run(prefix="local-"):
    return Path(tempfile.mkdtemp(prefix=prefix, dir=private_root()))

def write_json(path, value):
    # New private temporary file + atomic replacement inside a private run directory.
    fd, name = tempfile.mkstemp(prefix=".report-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def row(id, status, reason, **extra):
    return {"id": id, "status": status, "reason": reason, **extra}

def stop_child(proc):
    # Only the process group created for this test; never an arbitrary user PID.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass

def run_step(out, id, argv, timeout, *, inconclusive_codes=(), marker=None):
    start = time.monotonic()
    path = out / "logs" / (id + ".log")
    reason, status, code = "exit", "fail", None
    proc = None
    with path.open("xb") as log:
        try:
            proc = subprocess.Popen(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            size = 0
            with selectors.DefaultSelector() as selector:
                selector.register(proc.stdout, selectors.EVENT_READ)
                while True:
                    remaining = timeout - (time.monotonic() - start)
                    if remaining <= 0 or not selector.select(remaining):
                        raise TimeoutError("deadline")
                    data = os.read(proc.stdout.fileno(), min(65536, LIMIT + 1 - size))
                    if not data:
                        break
                    if size + len(data) > LIMIT:
                        raise OverflowError("output_limit")
                    log.write(data)
                    size += len(data)
            code = proc.wait(timeout=max(0.001, timeout - (time.monotonic() - start)))
            status = "pass" if code == 0 else ("inconclusive" if code in inconclusive_codes else "fail")
        except (TimeoutError, subprocess.TimeoutExpired):
            reason, status = "timeout", "inconclusive"
            if proc is not None:
                stop_child(proc)
        except OverflowError:
            reason, status = "output_limit", "inconclusive"
            if proc is not None:
                stop_child(proc)
        except OSError:
            reason, status = "launch_or_io_error", "fail"
            if proc is not None:
                stop_child(proc)
        except KeyboardInterrupt:
            reason, status = "interrupted", "inconclusive"
            if proc is not None:
                stop_child(proc)
        finally:
            if proc is not None and proc.stdout is not None:
                proc.stdout.close()
    data = path.read_bytes()
    if status == "pass" and marker is not None and marker.encode() not in data.splitlines():
        reason, status = "missing_success_marker", "inconclusive"
    return row(id, status, reason, exit_code=code,
               duration_seconds=round(time.monotonic() - start, 3),
               log="logs/" + path.name, log_sha256=hashlib.sha256(data).hexdigest())

CORE_STEPS = ("preflight", "toolchain", "python_tests", "swift_tests", "coverage",
              "legacy_build", "module_build", "legacy_smoke", "module_smoke")
HOST_STEPS = ("host_compatibility", "tcp_observation", "udp_observation")

def planned_steps(profile, performance=False, traffic=False):
    if profile not in ("core", "host") or type(performance) is not bool or type(traffic) is not bool:
        raise ValueError("invalid acceptance plan")
    return (CORE_STEPS + (HOST_STEPS if profile == "host" else ())
            + (("performance",) if performance else ())
            + (("traffic_numeric",) if traffic else ()))

def automatic_exit(rows, clean, expected=None):
    if any(x["status"] == "fail" for x in rows):
        return 1
    if expected is not None and tuple(x["id"] for x in rows) != tuple(expected):
        return 2
    if not clean or any(x["status"] in ("inconclusive", "blocked", "skipped") for x in rows):
        return 2
    return 0 if rows and all(x["status"] == "pass" for x in rows) else 2

def performance_result(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        cpu, rss, duration, count = (data[k] for k in ("average_cpu_percent_one_core",
                                                      "max_rss_bytes", "duration_seconds", "samples"))
        if (type(cpu) not in (int, float) or not math.isfinite(cpu) or cpu < 0 or
            type(rss) is not int or rss <= 0 or type(duration) not in (int, float) or
            not math.isfinite(duration) or duration <= 0 or type(count) is not int or count < 2):
            raise ValueError("bad metrics")
        return {"cpu_percent_one_core": cpu, "max_rss_bytes": rss,
                "duration_seconds": duration, "samples": count,
                "meets_numeric_target": cpu < 0.5 and rss < 80_000_000,
                "idle_condition_and_binary_identity": "operator_review_required"}
    except (OSError, ValueError, KeyError, TypeError):
        return None

def coverage_result(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8").splitlines()[0])
        total, covered = data["executable_lines"], data["covered_lines"]
        if (type(total) is not int or type(covered) is not int or not 0 <= covered <= total
            or type(data["complete_inventory"]) is not bool or type(data["meets_target"]) is not bool):
            return None
        complete = data["complete_inventory"] and total > 0
        meets = complete and covered * 100 >= total * 90
        if data["meets_target"] != meets:
            return None
        return {"executable_lines": total, "covered_lines": covered, "complete_inventory": complete,
                "target_percent": 90, "meets_numeric_target": meets}
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return None

def environment():
    info = {"os": platform.system(), "os_version": platform.mac_ver()[0] or platform.release(),
            "architecture": platform.machine(), "python": platform.python_version(), "hardware_model": None}
    if info["os"] == "Darwin":
        try:
            model = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], timeout=5,
                                            stderr=subprocess.DEVNULL, text=True).strip()
            if re.fullmatch(r"[A-Za-z0-9,._-]{1,64}", model):
                info["hardware_model"] = model
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return info

def execute(args, out, sha, clean):
    rows = []
    options = {"performance": args.pid is not None, "traffic": args.traffic_evidence is not None}
    expected = planned_steps(args.profile, **options)
    report = {"schema_version": 2, "kind": "local_automatic", "started_at": now(),
              "options": options, "planned_steps": list(expected),
              "commit_sha": sha, "clean_at_start": clean, "clean_at_end": False,
              "same_revision_at_end": False, "environment": environment(),
              "profile": args.profile, "steps": rows,
              "manual_gates": [{"id": id, "status": "blocked" if id in BLOCKED_IDS else "review_required"}
                               for id in MANUAL_IDS],
              "full_device_acceptance": False, "automatic_exit_code": 2}
    write_json(out / "environment.json", report["environment"])
    write_json(out / "summary.json", report)

    def add(value):
        rows.append(value)
        write_json(out / "summary.json", report)
        print(value["id"] + ": " + value["status"], flush=True)
        return value

    def step(id, argv, timeout, **kwargs):
        if any(x["reason"] == "interrupted" for x in rows):
            return add(row(id, "skipped", "interrupted"))
        return add(run_step(out, id, argv, timeout, **kwargs))

    try:
        if not clean:
            add(row("preflight", "blocked", "dirty_checkout"))
        elif platform.system() != "Darwin":
            add(row("preflight", "blocked", "macos_required"))
        else:
            add(row("preflight", "pass", "clean_macos_checkout"))
            step("toolchain", ["swift", "--version"], 30)
            step("python_tests", ["make", "test"], 180)
            swift = step("swift_tests", ["swift", "test", "--enable-code-coverage"], 1200)
            if swift["status"] == "pass":
                try:
                    coverage_path = subprocess.check_output(["swift", "test", "--show-codecov-path"],
                        cwd=ROOT, timeout=60, stderr=subprocess.DEVNULL).decode().strip()
                    candidate = (ROOT / coverage_path).resolve()
                    if ROOT.resolve() not in candidate.parents:
                        raise ValueError("coverage outside checkout")
                    coverage = step("coverage", [sys.executable, "scripts/core_coverage.py", "--root", str(ROOT),
                         "--report", str(candidate)], 120)
                    if coverage["status"] == "pass":
                        metrics = coverage_result(out / coverage["log"])
                        coverage["metrics"] = metrics
                        if metrics is None or not metrics["complete_inventory"]:
                            coverage.update(status="inconclusive", reason="incomplete_coverage_evidence")
                        elif not metrics["meets_numeric_target"]:
                            coverage.update(status="fail", reason="coverage_below_target")
                        write_json(out / "summary.json", report)
                        print("coverage verdict: " + coverage["status"], flush=True)
                except (OSError, ValueError, subprocess.SubprocessError):
                    add(row("coverage", "inconclusive", "coverage_path_unavailable"))
            else:
                add(row("coverage", "skipped", "swift_tests_not_passed"))
            legacy = step("legacy_build", ["make", "build"], 600)
            modular = step("module_build", ["make", "build-module"], 1200)
            for label, build, app in (("legacy", legacy, "build/NCHUTraffic.app"),
                                      ("module", modular, "build/module/NCHUTraffic.app")):
                if build["status"] == "pass":
                    step(label + "_smoke", [sys.executable, "scripts/smoke_test.py", "--app", app], 90,
                         marker="NETGUARD_SMOKE_OK fixture-native-views=4 status-item=1 resources=2")
                else:
                    add(row(label + "_smoke", "skipped", "build_not_passed"))
            if args.profile == "host":
                for id, option, marker in (
                    ("host_compatibility", "--netguard-host-check", "NETGUARD_HOST_CHECK_OK"),
                    ("tcp_observation", "--netguard-flow-check", "NETGUARD_TCP_FLOW_CHECK_OK"),
                    ("udp_observation", "--netguard-udp-check", "NETGUARD_UDP_FLOW_CHECK_OK")):
                    if legacy["status"] == "pass":
                        step(id, ["build/NCHUTraffic.app/Contents/MacOS/NCHUTraffic", option],
                             90, inconclusive_codes=(2,), marker=marker)
                    else:
                        add(row(id, "skipped", "build_not_passed"))
            if args.pid is not None:
                perf = step("performance", [sys.executable, "scripts/benchmark_device.py",
                            "--pid", str(args.pid), "--seconds", str(args.benchmark_seconds)],
                            args.benchmark_seconds + 90)
                if perf["status"] == "pass":
                    metrics = performance_result(out / perf["log"])
                    perf["metrics"] = metrics
                    if metrics is None:
                        perf.update(status="inconclusive", reason="invalid_metrics")
                    elif not metrics["meets_numeric_target"]:
                        perf.update(status="fail", reason="numeric_target_exceeded")
                    else:
                        perf["reason"] = "numeric_target_only_review_required"
                    write_json(out / "summary.json", report)
                    print("performance verdict: " + perf["status"], flush=True)
            if args.traffic_evidence is not None:
                traffic = step("traffic_numeric", [sys.executable, "scripts/traffic_acceptance.py",
                               str(args.traffic_evidence.resolve())], 30, inconclusive_codes=(2,))
                if traffic["status"] == "pass":
                    traffic["reason"] = "numeric_target_only_review_required"
                    write_json(out / "summary.json", report)
    except KeyboardInterrupt:
        add(row("interruption", "inconclusive", "interrupted"))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        add(row("runner_error", "inconclusive", "orchestration_error"))
    finally:
        try:
            end, end_clean = revision()
            report.update(clean_at_end=end_clean, same_revision_at_end=end == sha)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        report["finished_at"] = now()
        report["automatic_exit_code"] = automatic_exit(rows, clean and report["clean_at_end"]
                                                       and report["same_revision_at_end"], expected)
        write_json(out / "summary.json", report)
    return report["automatic_exit_code"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("core", "host"), default="host")
    parser.add_argument("--pid", type=int, help="Explicit existing NetGuard PID for optional benchmark")
    parser.add_argument("--benchmark-seconds", type=int, default=300)
    parser.add_argument("--traffic-evidence", type=Path, help="Existing redacted independent measurements")
    args = parser.parse_args()
    if (args.pid is not None and args.pid <= 0) or not 10 <= args.benchmark_seconds <= 3600:
        parser.error("invalid PID or benchmark duration")
    os.umask(0o077)
    try:
        sha, clean = revision()
        out = new_run()
        (out / "logs").mkdir(mode=0o700)
        result = execute(args, out, sha, clean)
        print("Local private report: " + str(out.relative_to(ROOT) / "summary.json"))
        print("Full device acceptance: not granted")
        return result
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Acceptance setup failed: check git, Python and private test-results directory.", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
