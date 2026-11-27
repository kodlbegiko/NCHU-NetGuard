#!/usr/bin/env python3
"""Record explicitly selected redacted manual observations in a private local session."""
import argparse
import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

from run_all import ROOT, BLOCKED_IDS, MANUAL_IDS, environment, new_run, now, revision, write_json
from record_manual import validate
from verify_report import owned_directory, read_private, strict_json

CAP = 16 * 1024 * 1024
OBSERVED = ("observed_pass", "observed_fail", "inconclusive")

def initial_ledger(sha, env):
    result = {"schema_version": 1, "kind": "manual_device_evidence",
              "commit_sha": sha, "environment": {key: env[key] for key in
                  ("os_version", "architecture", "hardware_model")},
              "gates": [{"id": id, "outcome": "blocked" if id in BLOCKED_IDS else "not_run",
                         "observed_at": None, "evidence_sha256": [], "note": ""} for id in MANUAL_IDS],
              "review_status": "review_required"}
    validate(result)
    return result

def create_session(directory, sha, env):
    ledger = initial_ledger(sha, env)
    owned_directory(directory)
    if (directory / "ledger.json").exists():
        raise ValueError("session already initialized")
    (directory / "evidence").mkdir(mode=0o700)
    write_json(directory / "ledger.json", ledger)
    return ledger

@contextmanager
def session_lock(directory):
    owned_directory(directory)
    owned_directory(directory / "evidence")
    fd = os.open(directory / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
            info.st_uid != os.geteuid() or info.st_mode & 0o077):
            raise ValueError("unsafe lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)

def read_selected(path):
    # Explicit input may originate outside the private directory. Never follow
    # symlinks or read devices, FIFOs, oversized or foreign-owned files.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
            info.st_size > CAP):
            raise ValueError("unsafe input")
        data = source.read(CAP + 1)
        after = os.fstat(source.fileno())
        if (not data or len(data) > CAP or
            (info.st_size, info.st_mtime_ns, info.st_ctime_ns) !=
            (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise ValueError("empty, oversized or changing input")
        return data

def store_evidence(directory, data):
    digest = hashlib.sha256(data).hexdigest()
    path = directory / "evidence" / (digest + ".bin")
    # Atomic exclusive creation; if a prior copy exists verify its bytes.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        if read_private(path, CAP) != data:
            raise ValueError("existing evidence mismatch")
    else:
        try:
            with os.fdopen(fd, "wb") as dest:
                dest.write(data)
                dest.flush()
                os.fsync(dest.fileno())
        except BaseException:
            path.unlink()
            raise
    return digest

def read_ledger(directory):
    ledger = strict_json(read_private(directory / "ledger.json", 256 * 1024))
    validate(ledger)
    return ledger

def verify_evidence(directory, ledger):
    hashes = {digest for gate in ledger["gates"] for digest in gate["evidence_sha256"]}
    for digest in hashes:
        data = read_private(directory / "evidence" / (digest + ".bin"), CAP)
        if not data or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("evidence digest mismatch")
    result = validate(ledger)
    result.update(verified_evidence_files=len(hashes),
                  integrity_scope="local_consistency_only_not_authenticity")
    return result

def record(directory, sha, gate_id, outcome, selected, note=""):
    if gate_id not in MANUAL_IDS or gate_id in BLOCKED_IDS or outcome not in OBSERVED:
        raise ValueError("invalid or disabled gate")
    if not 1 <= len(selected) <= 8 or not isinstance(note, str) or len(note) > 2000:
        raise ValueError("invalid evidence or note")
    with session_lock(directory):
        ledger = read_ledger(directory)
        if ledger["commit_sha"] != sha:
            raise ValueError("session revision mismatch")
        verify_evidence(directory, ledger)
        gate = next(g for g in ledger["gates"] if g["id"] == gate_id)
        if gate["outcome"] != "not_run":
            # Keep the first observation immutable; re-test in a new session.
            raise ValueError("gate already recorded")
        # Validate all selected inputs before writing any new evidence files.
        # A later disk/write error can leave an unreferenced private blob;
        # only ledger-referenced evidence is counted.
        inputs = [read_selected(path) for path in selected]
        hashes = sorted({store_evidence(directory, data) for data in inputs})
        gate.update(outcome=outcome, observed_at=now(), evidence_sha256=hashes, note=note)
        validate(ledger)
        write_json(directory / "ledger.json", ledger)
        return verify_evidence(directory, ledger)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init")
    record_parser = sub.add_parser("record")
    record_parser.add_argument("session", type=Path)
    record_parser.add_argument("gate", choices=MANUAL_IDS)
    record_parser.add_argument("--outcome", required=True, choices=OBSERVED)
    record_parser.add_argument("--evidence", required=True, action="append", type=Path)
    record_parser.add_argument("--note", default="")
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("session", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "init":
            sha, clean = revision()
            env = environment()
            if not clean or env["os"] != "Darwin" or env["hardware_model"] is None:
                raise ValueError("requires clean macOS checkout and hardware model")
            directory = new_run("manual-")
            create_session(directory, sha, env)
            print(str(directory.relative_to(ROOT)))
        elif args.command == "record":
            sha, clean = revision()
            if not clean:
                raise ValueError("dirty checkout")
            result = record(args.session, sha, args.gate, args.outcome, args.evidence, args.note)
            print(json.dumps(result, indent=2))
        else:
            with session_lock(args.session):
                result = verify_evidence(args.session, read_ledger(args.session))
            print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, RecursionError, subprocess.SubprocessError):
        print("Manual session rejected: check revision, private files, gate status and evidence.", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
