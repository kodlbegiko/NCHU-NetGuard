#!/usr/bin/env python3
"""Validate a local manual-evidence ledger; never grant formal acceptance."""
import argparse
import datetime as dt
import json
import re
from pathlib import Path
from run_all import BLOCKED_IDS, MANUAL_IDS

def validate(value):
    if not isinstance(value, dict) or type(value.get("schema_version")) is not int or value["schema_version"] != 1 or value.get("kind") != "manual_device_evidence":
        raise ValueError("schema")
    if not isinstance(value.get("commit_sha"), str) or not re.fullmatch(r"[0-9a-f]{40}", value["commit_sha"]):
        raise ValueError("commit")
    if value.get("review_status") != "review_required":
        raise ValueError("review status")
    environment = value.get("environment")
    if not isinstance(environment, dict) or set(environment) != {"os_version", "architecture", "hardware_model"} or any(
            not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9.,_-]{1,64}", v) for v in environment.values()):
        raise ValueError("environment")
    gates = value.get("gates")
    if not isinstance(gates, list) or len(gates) != len(MANUAL_IDS):
        raise ValueError("gate inventory")
    seen = set()
    counts = {}
    for gate in gates:
        if not isinstance(gate, dict) or set(gate) != {"id","outcome","observed_at","evidence_sha256","note"}:
            raise ValueError("gate shape")
        id = gate["id"]
        if not isinstance(id, str) or id not in MANUAL_IDS or id in seen:
            raise ValueError("gate id")
        seen.add(id)
        outcome = gate["outcome"]
        if outcome not in ("not_run", "blocked", "inconclusive", "observed_pass", "observed_fail"):
            raise ValueError("outcome")
        if id in BLOCKED_IDS and outcome == "observed_pass":
            raise ValueError("disabled capability cannot pass current matrix")
        hashes = gate["evidence_sha256"]
        if not isinstance(hashes, list) or len(hashes) > 32 or any(not isinstance(h, str) or not re.fullmatch(r"[0-9a-f]{64}",h) for h in hashes):
            raise ValueError("evidence digest")
        note = gate["note"]
        if not isinstance(note, str) or len(note) > 2000:
            raise ValueError("note")
        if outcome in ("observed_pass", "observed_fail", "inconclusive"):
            if not isinstance(gate["observed_at"], str) or not hashes:
                raise ValueError("observation requires date and evidence")
            when = dt.datetime.fromisoformat(gate["observed_at"].replace("Z","+00:00"))
            if when.tzinfo is None:
                raise ValueError("timezone required")
        counts[outcome] = counts.get(outcome, 0) + 1
    return {"commit_sha":value["commit_sha"],"counts":counts,"review_status":"review_required",
            "full_device_acceptance":False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ledger", type=Path)
    args = parser.parse_args()
    try:
        with args.ledger.open("rb") as file:
            raw = file.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise ValueError("too large")
        result = validate(json.loads(raw))
    except (OSError, ValueError, KeyError, TypeError, RecursionError):
        print("Invalid manual evidence ledger; no acceptance granted.")
        return 2
    print(json.dumps(result, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
