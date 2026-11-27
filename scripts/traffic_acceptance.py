#!/usr/bin/env python3
"""Evaluate redacted controlled traffic evidence; never generate network traffic."""
import argparse
import json
from pathlib import Path

LIMIT = 2**64 - 1
BOUNDARIES = {"physicalWire", "socketPayload"}


def evaluate(document):
    if not isinstance(document, dict) or document.get("schema_version") != 1 or type(document["schema_version"]) is not int:
        raise ValueError("unsupported schema")
    reference, observed = document["reference"], document["observed"]
    for row in (reference, observed):
        if not isinstance(row, dict) or row.get("boundary") not in BOUNDARIES:
            raise ValueError("invalid measurement boundary")
        for key in ("observation_id", "interface_id", "source_id"):
            val = row[key]
            if not isinstance(val, str) or not 1 <= len(val) <= 128 or not all(c.isascii() and (c.isalnum() or c in "._-") for c in val):
                raise ValueError("invalid redacted identity")
        for key in ("received", "sent"):
            if type(row[key]) is not int or not 0 <= row[key] <= LIMIT:
                raise ValueError("invalid byte count")
        if row.get("complete") is not True:
            raise ValueError("incomplete observation")
    for field in ("boundary", "observation_id", "interface_id"):
        if reference[field] != observed[field]:
            raise ValueError("incomparable observations")
    if reference["source_id"] == observed["source_id"]:
        raise ValueError("reference source must differ")
    result = {}
    for key in ("received", "sent"):
        expected, actual = reference[key], observed[key]
        error = abs(expected - actual)
        # 1% directional error, not rounded and not cancelled between directions.
        # A true zero reference can only match zero.
        within = error * 100 <= expected
        result[key] = {"reference_bytes": expected, "observed_bytes": actual, "absolute_error_bytes": error,
                       "relative_error_percent": error * 100 / expected if expected else None, "within_target": within}
    return {"schema_version": 1, "boundary": reference["boundary"], "target_percent": 1,
            "directions": result, "meets_numeric_target": all(r["within_target"] for r in result.values()),
            "independence": "caller_asserted_not_verified", "device_acceptance": "requires_independent_review"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    try:
        if args.evidence.stat().st_size > 65_536:
            raise ValueError("evidence too large")
        result = evaluate(json.loads(args.evidence.read_text(encoding="utf-8")))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(json.dumps({"status": "inconclusive", "reason": type(exc).__name__}))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0 if result["meets_numeric_target"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
