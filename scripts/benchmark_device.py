#!/usr/bin/env python3
"""Read-only measurement of an explicitly selected running NetGuard process.
No launch, traffic generation, configuration changes or network queries."""
import argparse
import json
import math
import platform
import re
import subprocess
import time
from pathlib import Path

def cpu_seconds(value):
    # macOS ps TIME: [days-][hours:]minutes:seconds[.fraction].
    match = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)", value)
    if not match:
        raise ValueError("unsupported ps CPU time")
    days, hours, minutes, seconds = match.groups()
    result = int(days or 0)*86400 + int(hours or 0)*3600 + int(minutes)*60 + float(seconds)
    if not math.isfinite(result) or float(seconds) >= 60:
        raise ValueError("invalid CPU time")
    return result

def probe(pid, field):
    return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", field + "="],
                                   timeout=2, text=True).strip()

def sample(pid):
    executable = probe(pid, "comm")
    if Path(executable).name != "NCHUTraffic":
        raise RuntimeError("Selected process is not the NetGuard executable.")
    identity = (executable, probe(pid, "lstart"))
    cpu = cpu_seconds(probe(pid, "time"))
    rss = int(probe(pid, "rss"))
    confirmed = (probe(pid, "comm"), probe(pid, "lstart"))
    if rss <= 0 or not identity[1] or confirmed != identity:
        raise RuntimeError("Invalid sample or process identity changed")
    return identity, time.monotonic(), cpu, rss

def summarize(samples):
    first, last = samples[0], samples[-1]
    elapsed = last[1] - first[1]
    if elapsed <= 0 or any(a[0] != first[0] for a in samples) or any(
            b[1] <= a[1] or b[2] < a[2] for a,b in zip(samples, samples[1:])):
        raise RuntimeError("Process identity or monotonic counters changed.")
    # Relative-time aggregates only; no process names, PID or absolute paths.
    # A sampled RSS peak is not proof of a leak or monotonic growth.
    windows = []
    begin = 0
    for index in range(1, len(samples)):
        if samples[index][1] - samples[begin][1] >= 60 or index == len(samples)-1:
            part = samples[begin:index+1]
            seconds = part[-1][1] - part[0][1]
            windows.append({
                "start_seconds": round(part[0][1] - first[1], 3),
                "end_seconds": round(part[-1][1] - first[1], 3),
                "samples": len(part),
                "average_cpu_percent_one_core": round(100*(part[-1][2]-part[0][2])/seconds, 4),
                "min_rss_bytes": min(row[3] for row in part)*1024,
                "max_rss_bytes": max(row[3] for row in part)*1024,
                "end_rss_bytes": part[-1][3]*1024})
            begin = index
    peak = max(samples, key=lambda row: row[3])
    return {"duration_seconds": round(elapsed,3), "samples": len(samples),
            "average_cpu_percent_one_core": round(100*(last[2]-first[2])/elapsed,4),
            "max_rss_bytes": peak[3]*1024,
            "min_rss_bytes": min(s[3] for s in samples)*1024,
            "initial_rss_bytes": first[3]*1024,
            "final_rss_bytes": last[3]*1024,
            "peak_at_seconds": round(peak[1]-first[1], 3),
            "max_sample_gap_seconds": round(max(b[1]-a[1] for a,b in zip(samples,samples[1:])),3),
            "relative_windows": windows,
            "measurement": "process CPU-time delta and maximum sampled RSS; excludes other processes",
            "idle_cpu_target_percent": 0.5, "rss_target_bytes": 80_000_000}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--interval", type=int, default=5)
    args=parser.parse_args()
    if platform.system()!="Darwin" or args.pid<=0 or not 10<=args.seconds<=3600 or not 1<=args.interval<=60 or args.interval>args.seconds:
        parser.error("Requires macOS, explicit positive PID and bounded sample window.")
    samples=[sample(args.pid)]
    deadline=samples[0][1]+args.seconds
    while time.monotonic()<deadline:
        time.sleep(max(0,min(args.interval,deadline-time.monotonic())))
        samples.append(sample(args.pid))
    result=summarize(samples)
    result["machine"]=platform.machine()
    result["macos"]=platform.mac_ver()[0]
    result["hardware_model"]=subprocess.check_output(["/usr/sbin/sysctl","-n","hw.model"],text=True,timeout=2).strip()
    print(json.dumps(result, indent=2))

if __name__=="__main__":
    main()
