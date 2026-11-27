#!/usr/bin/env python3
"""Record local candidate content identity; never build, install, tag or release."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

from install_bundle import bundle_fingerprint

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = {"legacy": "build/NCHUTraffic.app", "module": "build/module/NCHUTraffic.app"}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, stderr=subprocess.DEVNULL,
                                   timeout=15, text=True).strip()


def revision(expected_sha):
    sha = git("rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or sha != expected_sha:
        raise ValueError("unexpected source revision")
    if git("status", "--porcelain=v1", "--untracked-files=normal"):
        raise ValueError("candidate checkout is dirty")
    return sha


def describe(app):
    digest = bundle_fingerprint(app)
    with (app / "Contents/Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    short = metadata.get("CFBundleShortVersionString")
    build = metadata.get("CFBundleVersion")
    if (not isinstance(short, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", short)
            or len(short) > 32 or
            (build is not None and (not isinstance(build, str) or len(build) > 32 or
                                    not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", build)))):
        raise ValueError("invalid bundle version metadata")
    if bundle_fingerprint(app) != digest:
        raise ValueError("candidate content changed during inventory")
    return {"sha256": digest, "bundle_short_version": short, "bundle_build_version": build}


def collect(expected_sha):
    sha = revision(expected_sha)
    bundles = {name: describe(ROOT / path) for name, path in VARIANTS.items()}
    if revision(expected_sha) != sha:
        raise ValueError("source revision changed during inventory")
    versions = {(v["bundle_short_version"], v["bundle_build_version"]) for v in bundles.values()}
    if len(versions) != 1:
        raise ValueError("build variants disagree on version metadata")
    return {"schema_version": 1, "kind": "candidate_content_inventory", "commit_sha": sha,
            "bundles": bundles, "provenance": "content_identity_only_not_signed",
            "full_device_acceptance": False, "release_authorized": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-sha", required=True)
    args = parser.parse_args()
    try:
        result = collect(args.expected_sha)
    except (OSError, ValueError, subprocess.SubprocessError, AttributeError, plistlib.InvalidFileException) as error:
        parser.exit(1, "Candidate inventory unavailable: " + type(error).__name__ + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
