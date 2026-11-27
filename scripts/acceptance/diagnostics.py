"""Bounded read-only host evidence for the selected process and its history.

No raw process listing, command lines, database rows, paths or addresses leave
this module except the local redacted directional day summaries.
"""
import datetime as dt
import ctypes
import platform
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import time

from verify_report import read_private, strict_json

MAX_BYTES = 64 * 1024 * 1024
MAX_TOTAL = 9_007_199_254_740_991
SCOPES = {"dorm", "campusWifi", "external", "unknown"}
STATE_KEYS = ("dorm_in", "dorm_out", "wifi_in", "wifi_out", "ext_in", "ext_out",
              "unattributed_in", "unattributed_out")


def canonical_day(value):
    if not isinstance(value, str) or dt.date.fromisoformat(value).isoformat() != value:
        raise ValueError("invalid day")
    return value


def byte_count(value):
    if type(value) is not int or not 0 <= value <= MAX_TOTAL:
        raise ValueError("invalid byte count")
    return value


def inspect_state(path):
    data = strict_json(read_private(path, 1_048_576))
    if (not isinstance(data, dict) or type(data.get("schema_version")) is not int or
            data["schema_version"] != 1 or data.get("accounting_overflow") is not False):
        raise ValueError("invalid persisted state")
    values = [byte_count(data[k]) for k in STATE_KEYS]
    total = byte_count(sum(values))
    return {"day": canonical_day(data["date"]), "received": sum(values[::2]),
            "sent": sum(values[1::2]), "total": total,
            "measured_samples": byte_count(data["measured_sample_count"])}


def owned_regular(path):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
            info.st_nlink != 1 or info.st_mode & 0o022 or not 0 < info.st_size <= MAX_BYTES):
        raise ValueError("unsafe or oversized database")
    return info


def inspect_history(path, days):
    """One bounded read snapshot. Live journal sidecars are not opened here."""
    try:
        info = owned_regular(path)
    except FileNotFoundError:
        return {"status": "not_present", "days": {}, "database_bytes": 0}
    for suffix in ("-journal", "-wal", "-shm"):
        try:
            Path(str(path) + suffix).lstat()
        except FileNotFoundError:
            continue
        return {"status": "sidecar_present_review_required", "days": {}, "database_bytes": info.st_size}
    db = sqlite3.connect(path.absolute().as_uri() + "?mode=ro", uri=True, timeout=.25)
    deadline = time.monotonic() + 4
    try:
        db.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
        db.execute("PRAGMA query_only=ON")
        db.execute("PRAGMA trusted_schema=OFF")
        db.execute("BEGIN DEFERRED")
        version = db.execute("PRAGMA user_version").fetchone()[0]
        if version not in (1,2,3):
            raise ValueError("unsupported history schema")
        inventory = db.execute(
            "SELECT name,type FROM sqlite_master WHERE type IN ('table','view','trigger')").fetchall()
        expected = {"history_days"} if version == 1 else {"history_days", "history_scopes"}
        if (len(inventory) != len(expected) or set(inventory) != {(name, "table") for name in expected}
                or db.execute("PRAGMA quick_check").fetchall() != [("ok",)]):
            raise ValueError("history integrity")
        if {row[1] for row in db.execute("PRAGMA table_list") if row[0] == "main" and row[2] == "table"
            and not row[1].startswith("sqlite_")} != expected:
            raise ValueError("history table identity")
        for table, columns in (
            ("history_days", [("day","TEXT",1),("total","INTEGER",0),
                              ("download","INTEGER",0),("upload","INTEGER",0)]),
            ("history_scopes", [("day","TEXT",1),("scope","TEXT",2),
                                ("download","INTEGER",0),("upload","INTEGER",0)])):
            if table not in expected:
                continue
            actual = db.execute("PRAGMA table_xinfo(" + table + ")").fetchall()
            if [(row[1],row[2],row[5]) for row in actual] != columns or any(row[6] != 0 for row in actual):
                raise ValueError("unexpected history columns")
        if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise ValueError("history foreign key violation")
        if db.execute("SELECT count(*) FROM history_days").fetchone()[0] > 36_600:
            raise ValueError("history row limit")
        if version >= 2 and db.execute("SELECT count(*) FROM history_scopes").fetchone()[0] > 146_400:
            raise ValueError("scope row limit")
        # Validate every record, not merely rows requested for rollover evidence.
        aggregates = {}
        for day, total, rx, tx in db.execute("SELECT day,total,download,upload FROM history_days"):
            canonical_day(day)
            byte_count(total)
            if day in aggregates or (rx is None) != (tx is None):
                raise ValueError("duplicate or incomplete history row")
            if rx is not None and byte_count(rx) + byte_count(tx) != total:
                raise ValueError("history directional mismatch")
            aggregates[day] = (rx, tx)
        if version >= 2:
            partitions = {}
            for day, scope, rx, tx in db.execute("SELECT day,scope,download,upload FROM history_scopes"):
                canonical_day(day)
                if day not in aggregates or scope not in SCOPES:
                    raise ValueError("orphan or invalid scope")
                pair = (byte_count(rx), byte_count(tx))
                if (version == 2 or scope == "unknown") and pair == (0,0):
                    raise ValueError("unsupported zero scope")
                bucket = partitions.setdefault(day, {})
                if scope in bucket:
                    raise ValueError("duplicate scope")
                bucket[scope] = pair
            for day, bucket in partitions.items():
                summed = tuple(sum(pair[index] for pair in bucket.values()) for index in (0,1))
                if summed != aggregates[day]:
                    raise ValueError("history partition mismatch")
        actual = owned_regular(path)
        if (actual.st_dev, actual.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError("history identity changed")
        return {"status": "snapshot_validated", "database_bytes": actual.st_size,
                "recorded_days": len(aggregates), "schema_version": version,
                "days": {day: {"received": aggregates[day][0], "sent": aggregates[day][1]}
                         for day in sorted(set(days)) if day in aggregates}}
    finally:
        db.close()


def bounded_command(argv):
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                            timeout=3, check=False)
    if result.returncode != 0 or len(result.stdout) > 1_048_576:
        raise ValueError("host observation unavailable")
    return result.stdout.decode("utf-8", "strict")


# Darwin public rusage_info_v2 layout from Apple's sys/resource.h:
# https://github.com/apple/darwin-xnu/blob/main/bsd/sys/resource.h
# Only named public aggregate fields are emitted; the UUID and start identity
# remain in memory. Wakeups are energy proxies, not joules or battery usage.
RUSAGE_KEYS = ("disk_read_bytes", "disk_write_bytes", "package_idle_wakeups",
               "interrupt_wakeups", "physical_footprint_bytes")
CUMULATIVE_RESOURCES = RUSAGE_KEYS[:-1]


class RUsageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 18)]


def native_resources(pid):
    result = dict.fromkeys(RUSAGE_KEYS)
    if platform.system() != "Darwin" or ctypes.sizeof(RUsageV2) != 160:
        return result
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        call = lib.proc_pid_rusage
        call.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
        call.restype = ctypes.c_int
        record = RUsageV2()
        if call(pid, 2, ctypes.byref(record)) == 0:
            for key, index in zip(RUSAGE_KEYS, (16,17,2,3,7)):
                result[key] = int(record.values[index])
    except (OSError, AttributeError, ValueError):
        pass
    return result


def crash_report_count(directory, since):
    # Never open report contents or retain filenames. Delayed reports and
    # reports from another instance cannot be assigned to the selected PID.
    try:
        count = 0
        with os.scandir(directory) as entries:
            for index, entry in enumerate(entries):
                if index >= 4096:
                    return None
                if (re.fullmatch(r"(?:NCHUTraffic|NetGuard)[_-].+\.(?:ips|crash|hang|spin)", entry.name)
                        and entry.is_file(follow_symlinks=False)
                        and entry.stat(follow_symlinks=False).st_mtime >= since):
                    count += 1
        return count
    except OSError:
        return None


def resources(pid, since):
    """Counts and sampled totals only; unsupported host fields remain null."""
    result = {"open_descriptors": None, "thread_rows": None, "descendant_count": None,
              "descendant_rss_bytes": None, "zombie_descendants": None}
    result.update(native_resources(pid))
    result["matching_diagnostic_reports"] = crash_report_count(
        Path.home() / "Library/Logs/DiagnosticReports", since)
    try:
        raw = bounded_command(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-F", "f"])
        fds = {int(line[1:]) for line in raw.splitlines() if re.fullmatch(r"f[0-9]+", line)}
        if fds:
            result["open_descriptors"] = len(fds)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    try:
        raw = bounded_command(["/bin/ps", "-M", "-p", str(pid), "-o", "pid="])
        rows = raw.split()
        if rows and all(row == str(pid) for row in rows):
            result["thread_rows"] = len(rows)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    try:
        raw = bounded_command(["/bin/ps", "-axo", "pid=,ppid=,state=,rss="])
        tree = {}
        for line in raw.splitlines():
            fields = line.split()
            if len(fields) != 4:
                raise ValueError("unexpected process tree format")
            child, parent, state, rss = int(fields[0]), int(fields[1]), fields[2], int(fields[3])
            if child in tree or rss < 0:
                raise ValueError("ambiguous process tree")
            tree[child] = (parent, state, rss)
        if pid not in tree:
            raise ValueError("target missing")
        found = {pid}
        for _ in range(len(tree)):
            next_level = {child for child, row in tree.items() if row[0] in found} - found
            if not next_level:
                break
            found.update(next_level)
        found.remove(pid)
        result.update(descendant_count=len(found),
                      descendant_rss_bytes=sum(tree[p][2] * 1024 for p in found),
                      zombie_descendants=sum(tree[p][1].startswith("Z") for p in found))
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return result


def validate_resources(value):
    keys = {"open_descriptors", "thread_rows", "descendant_count",
            "descendant_rss_bytes", "zombie_descendants", "matching_diagnostic_reports", *RUSAGE_KEYS}
    if (not isinstance(value, dict) or set(value) != keys or any(
            v is not None and (type(v) is not int or v < 0) for v in value.values())):
        raise ValueError("invalid resource evidence")
    if (value["zombie_descendants"] is not None and
            (value["descendant_count"] is None or value["zombie_descendants"] > value["descendant_count"])):
        raise ValueError("invalid descendant counts")
    return value


def trend(values):
    samples = [v for v in values if v is not None]
    if not samples:
        return {"status": "unavailable", "samples": 0}
    return {"status": "review_required", "samples": len(samples), "initial": samples[0],
            "final": samples[-1], "maximum": max(samples), "minimum": min(samples),
            "net_change": samples[-1] - samples[0]}


def rollover_evidence(history, previous):
    """Lower bound only: a finalized row must retain already observed bytes."""
    day = previous["day"]
    row = history["days"].get(day)
    if history["status"] != "snapshot_validated" or row is None:
        return "unavailable_review_required"
    if row["received"] is None or row["sent"] is None:
        return "direction_unknown_review_required"
    if row["received"] < previous["received"] or row["sent"] < previous["sent"]:
        return "observed_lower_bound_mismatch"
    return "observed_lower_bound_met_review_required"
