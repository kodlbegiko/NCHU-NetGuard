#!/usr/bin/env python3
"""Lifecycle rehearsal on internally created private temporary copies only.

No application launches, user installations, login items or actual user data.
Synthetic old-version marker and synthetic data are not migration evidence.
"""
import argparse
import ctypes
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

from install_bundle import BUNDLE, bundle_fingerprint, install, publish_exclusive


def observed_state(active, retained, old, new):
    if old == new:
        return "conflict"
    if (active, retained) == (old, new):
        return "original"
    if (active, retained) == (new, old):
        return "exchanged"
    return "conflict"


def swap_private_copies(left, right):
    if sys.platform != "darwin":
        raise OSError("Darwin atomic swap unavailable")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    left_fd = os.open(left, flags)
    try:
        right_fd = os.open(right, flags)
        try:
            for fd in (left_fd, right_fd):
                info = os.fstat(fd)
                if info.st_uid != os.geteuid() or info.st_mode & 0o077:
                    raise ValueError("rehearsal directory must be private")
            rename = ctypes.CDLL(None, use_errno=True).renameatx_np
            rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                               ctypes.c_char_p, ctypes.c_uint]
            rename.restype = ctypes.c_int
            name = os.fsencode(BUNDLE)
            # Darwin RENAME_SWAP: either both directory entries swap or neither.
            if rename(left_fd, name, right_fd, name, 0x00000002) != 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error))
        finally:
            os.close(right_fd)
    finally:
        os.close(left_fd)


def checked_swap(active, retained, old, new, expected_state):
    if expected_state not in ("original", "exchanged"):
        raise ValueError("invalid expected lifecycle state")
    state = observed_state(bundle_fingerprint(active / BUNDLE),
                           bundle_fingerprint(retained / BUNDLE), old, new)
    if state != expected_state:
        raise ValueError("unexpected bundle identity; preserve both copies")
    swap_private_copies(active, retained)
    target = "exchanged" if expected_state == "original" else "original"
    state = observed_state(bundle_fingerprint(active / BUNDLE),
                           bundle_fingerprint(retained / BUNDLE), old, new)
    if state != target:
        raise ValueError("post-swap state unverified")


def rehearse(app):
    source = Path(app).absolute()
    new = bundle_fingerprint(source)
    # No destination argument; all mutations remain in the internal temp tree.
    with tempfile.TemporaryDirectory(prefix="netguard-lifecycle-") as folder:
        root = Path(folder)
        fixture_root = root / "old-fixture"
        fixture_root.mkdir(mode=0o700)
        fixture = fixture_root / BUNDLE
        shutil.copytree(source, fixture, symlinks=True)
        marker = fixture / "Contents" / "Resources" / "netguard-rehearsal-only.txt"
        with marker.open("xb") as stream:
            stream.write(b"synthetic prior revision; never launched")
        old = bundle_fingerprint(fixture)
        if old == new:
            raise ValueError("fixture identities must differ")
        active, retained = root / "active", root / "retained"
        install(fixture, active)
        install(source, retained)
        data_dir = root / "synthetic-user-data"
        data_dir.mkdir(mode=0o700)
        data = data_dir / "history.json"
        sentinel = b'{"synthetic":true,"history":[17,29]}'
        data.write_bytes(sentinel)

        # Before-swap refusal: incorrect expected state changes neither copy.
        try:
            checked_swap(active, retained, old, new, "exchanged")
        except ValueError:
            pass
        else:
            raise ValueError("unexpected state accepted")
        if observed_state(bundle_fingerprint(active / BUNDLE),
                          bundle_fingerprint(retained / BUNDLE), old, new) != "original":
            raise ValueError("preflight altered the copies")

        checked_swap(active, retained, old, new, "original")
        # Simulated failed post-upgrade acceptance: recover original content
        # only if both expected identities are still present.
        checked_swap(active, retained, old, new, "exchanged")
        if data.read_bytes() != sentinel:
            raise ValueError("synthetic data changed during exchange/rollback")

        # Changed retained copy must block another swap, not overwrite it.
        extra = retained / BUNDLE / "Contents" / "Resources" / "conflict.txt"
        with extra.open("xb") as stream:
            stream.write(b"synthetic external change")
        conflict = bundle_fingerprint(retained / BUNDLE)
        try:
            checked_swap(active, retained, old, new, "original")
        except ValueError:
            pass
        else:
            raise ValueError("conflicting copy accepted")
        if (bundle_fingerprint(active / BUNDLE) != old or
                bundle_fingerprint(retained / BUNDLE) != conflict):
            raise ValueError("conflict changed either copy")

        # Uninstall rehearsal is a non-destructive exclusive move, not deletion.
        quarantine = root / "quarantine"
        quarantine.mkdir(mode=0o700)
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        active_fd = os.open(active, flags)
        try:
            quarantine_fd = os.open(quarantine, flags)
            try:
                publish_exclusive(active_fd, quarantine_fd)
            finally:
                os.close(quarantine_fd)
        finally:
            os.close(active_fd)
        if (list(active.iterdir()) or bundle_fingerprint(quarantine / BUNDLE) != old or
                bundle_fingerprint(retained / BUNDLE) != conflict or
                data.read_bytes() != sentinel or bundle_fingerprint(source) != new):
            raise ValueError("quarantine rehearsal failed preservation checks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.exit(1, "Requires macOS atomic directory exchange.\n")
    try:
        rehearse(args.app)
    except (OSError, ValueError, AttributeError) as error:
        parser.exit(1, "Isolated lifecycle rehearsal failed: " + type(error).__name__ + "\n")
    print("NETGUARD_LIFECYCLE_REHEARSAL_OK exchange rollback conflict quarantine synthetic-data")


if __name__ == "__main__":
    main()
