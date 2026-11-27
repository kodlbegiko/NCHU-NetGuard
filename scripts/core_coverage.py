#!/usr/bin/env python3
"""Report line coverage for production Swift Sources only; no release claim."""
import argparse
import json
import re
from pathlib import Path


def summarize(root, report):
    root = Path(root).resolve()
    expected = {p.relative_to(root).as_posix() for p in (root / "Sources").rglob("*.swift") if p.is_file()}
    if not expected:
        raise ValueError("no production sources")
    rows = {}
    for dataset in report["data"]:
        for file in dataset["files"]:
            try:
                path = Path(file["filename"]).resolve().relative_to(root).as_posix()
            except ValueError:
                continue
            if path not in expected:
                continue
            lines = file["summary"]["lines"]
            count, covered = lines["count"], lines["covered"]
            if type(count) is not int or type(covered) is not int or not 0 <= covered <= count:
                raise ValueError("invalid coverage count")
            if path in rows:
                raise ValueError("ambiguous duplicate coverage file")
            rows[path] = count, covered
    # LLVM legitimately omits a source containing only module compatibility
    # typealiases/imports. Limit the exception to that exact path and verify
    # every non-comment line is a non-executable declaration.
    excluded = []
    alias = "Sources/NetGuardCore/ModuleCompatibility.swift"
    if alias in expected and alias not in rows:
        contents = (root / alias).read_text(encoding="utf-8")
        lines = [line.strip() for line in contents.splitlines()
                 if line.strip() and not line.strip().startswith("//")]
        pattern = r"(?:#if SWIFT_PACKAGE|#endif|import [A-Za-z_]\w*|(?:public|package) typealias [A-Za-z_]\w* = [A-Za-z_]\w*\.[A-Za-z_]\w*)"
        if lines and lines[0] == "#if SWIFT_PACKAGE" and lines[-1] == "#endif" and all(re.fullmatch(pattern, line) for line in lines):
            excluded.append(alias)
    missing = sorted(expected - rows.keys() - set(excluded))
    count = sum(v[0] for v in rows.values())
    covered = sum(v[1] for v in rows.values())
    percentage = 100 * covered / count if count else None
    # Missing files are not silently assumed to have zero executable lines.
    meets_target = not missing and count > 0 and covered * 100 >= count * 90
    return {
        "source_files": len(expected), "reported_files": len(rows),
        "missing_sources": missing, "verified_non_executable_sources": excluded, "executable_lines": count,
        "covered_lines": covered, "reported_line_coverage_percent": percentage,
        "complete_inventory": not missing, "target_percent": 90,
        "meets_target": meets_target,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--require-target", action="store_true",
                        help="Fail when complete production-source coverage >=90% is not demonstrated")
    args = parser.parse_args()
    try:
        if args.report.stat().st_size > 256 * 1024 * 1024:
            raise ValueError("coverage report too large")
        result = summarize(args.root, json.loads(args.report.read_text(encoding="utf-8")))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        # Do not print host paths or raw report contents.
        print("coverage_evidence_invalid=" + type(exc).__name__)
        return 1
    print(json.dumps(result, sort_keys=True))
    if not result["meets_target"]:
        print("::warning::Core coverage target not demonstrated; R5 release gate remains open.")
        if args.require_target:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
