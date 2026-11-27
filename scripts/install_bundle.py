#!/usr/bin/env python3
"""Fresh, user-owned macOS bundle installation; never upgrade or uninstall."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import tempfile

BUNDLE = "NCHUTraffic.app"
REQUIRED = ("Contents/Info.plist", "Contents/MacOS/NCHUTraffic",
            "Contents/Resources/traffic_monitor.py", "Contents/Resources/popover.html")
MAX_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_BUNDLE_ENTRIES = 4096


def validate_bundle(bundle):
    root_info = bundle.lstat()
    if (bundle.name != BUNDLE or not stat.S_ISDIR(root_info.st_mode) or
            root_info.st_uid != os.geteuid() or root_info.st_mode & 0o022):
        raise ValueError("not the expected user-owned application directory")

    def fail(error):
        raise error

    # Built bundles contain regular files and directories only. Reject links
    # instead of copying or following them into the installed bundle.
    entries = total = 0
    for root, dirs, files in os.walk(bundle, followlinks=False, onerror=fail):
        for name in dirs + files:
            info = (Path(root) / name).lstat()
            entries += 1
            if entries > MAX_BUNDLE_ENTRIES:
                raise ValueError("too many bundle entries")
            if not (stat.S_ISDIR(info.st_mode) or
                    (stat.S_ISREG(info.st_mode) and info.st_nlink == 1)):
                raise ValueError("unsupported bundle entry")
            if info.st_uid != os.geteuid() or info.st_mode & 0o022:
                raise ValueError("unsafe bundle entry owner or permissions")
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
                if total > MAX_BUNDLE_BYTES:
                    raise ValueError("oversized bundle")
    for relative in REQUIRED:
        if not stat.S_ISREG((bundle / relative).lstat().st_mode):
            raise ValueError("missing required bundle file")
    executable = bundle / REQUIRED[1]
    if not executable.stat().st_mode & stat.S_IXUSR:
        raise ValueError("bundle executable lacks owner execute permission")
    info_path = bundle / REQUIRED[0]
    if info_path.stat().st_size > 1024 * 1024:
        raise ValueError("oversized Info.plist")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if (not isinstance(info, dict) or
            info.get("CFBundleExecutable") != "NCHUTraffic" or
            info.get("CFBundleIdentifier") != "tw.edu.nchu.dorm.traffic" or
            info.get("CFBundlePackageType") != "APPL"):
        raise ValueError("unexpected bundle identity")


def bundle_fingerprint(bundle):
    """Bounded, local content identity; not code-signing or build provenance."""
    validate_bundle(bundle)
    entries = {}
    total = 0
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    def fail(error):
        raise error
    for root, dirs, files in os.walk(bundle, followlinks=False, onerror=fail):
        for name in sorted(dirs + files):
            path = Path(root) / name
            key = path.relative_to(bundle).as_posix()
            before = path.lstat()
            if len(entries) >= MAX_BUNDLE_ENTRIES:
                raise ValueError("too many bundle entries")
            if before.st_uid != os.geteuid() or before.st_mode & 0o022:
                raise ValueError("unsafe bundle entry")
            if stat.S_ISDIR(before.st_mode):
                entries[key] = ["directory"]
                continue
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise ValueError("unsupported bundle entry")
            fd = os.open(path, flags)
            with os.fdopen(fd, "rb") as stream:
                opened = os.fstat(stream.fileno())
                def identity(info):
                    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid,
                            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                if identity(opened) != identity(before):
                    raise ValueError("bundle file changed before read")
                digest = hashlib.sha256()
                count = 0
                while True:
                    chunk = stream.read(65536)
                    if not chunk:
                        break
                    total += len(chunk)
                    count += len(chunk)
                    if total > MAX_BUNDLE_BYTES:
                        raise ValueError("oversized bundle")
                    digest.update(chunk)
                if count != opened.st_size or identity(os.fstat(stream.fileno())) != identity(opened):
                    raise ValueError("bundle file changed during read")
                entries[key] = ["file", bool(opened.st_mode & stat.S_IXUSR), count, digest.hexdigest()]
    if not all(relative in entries for relative in REQUIRED):
        raise ValueError("incomplete bundle fingerprint")
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def review(source, destination_dir):
    """Read-only lifecycle preview; never grant upgrade/uninstall permission."""
    source = Path(source).absolute()
    destination_dir = Path(destination_dir).absolute()
    candidate = bundle_fingerprint(source)
    try:
        info = destination_dir.lstat()
    except FileNotFoundError:
        pass
    else:
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or
                info.st_mode & 0o022):
            raise ValueError("unsafe review destination")
    target = destination_dir / BUNDLE
    result = {"candidate_sha256": candidate, "installed_sha256": None,
              "operation": "fresh_install_candidate", "mutation_authorized": False}
    try:
        target.lstat()
    except FileNotFoundError:
        return result
    try:
        existing = bundle_fingerprint(target)
    except (OSError, ValueError, AttributeError, plistlib.InvalidFileException):
        result["operation"] = "existing_bundle_unverified"
        return result
    result["installed_sha256"] = existing
    result["operation"] = "identical_content" if existing == candidate else "different_content_review_required"
    return result


def publish_exclusive(stage_fd, destination_fd):
    # Darwin <stdio.h>: RENAME_EXCL = 0x00000004. Unlike os.rename,
    # renameatx_np refuses ALL existing destination entries, including empty
    # directories and dangling symlinks. There is no overwrite fallback.
    if sys.platform != "darwin":
        raise OSError("exclusive macOS bundle publication unavailable")
    rename = ctypes.CDLL(None, use_errno=True).renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                       ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    name = os.fsencode(BUNDLE)
    if rename(stage_fd, name, destination_fd, name, 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def install(source, destination_dir):
    """Stage and validate a fresh copy; do not replace any existing app."""
    source = Path(source).absolute()
    destination_dir = Path(destination_dir).absolute()
    candidate_identity = bundle_fingerprint(source)
    # Never stage inside the source tree; that would recursively copy staging.
    if destination_dir.resolve().is_relative_to(source.resolve()):
        raise ValueError("installation directory lies inside source bundle")
    destination_dir.mkdir(exist_ok=True, mode=0o700)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    destination_fd = os.open(destination_dir, flags)
    try:
        info = os.fstat(destination_fd)
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError("installation directory must be user-owned and not group/world writable")
        try:
            os.stat(BUNDLE, dir_fd=destination_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise FileExistsError("destination already exists; automatic upgrades are disabled")
        # The private same-parent staging directory is never an installed app.
        # Copy symlinks as links, then reject them in the staged validation.
        with tempfile.TemporaryDirectory(prefix=".netguard-install-", dir=destination_dir) as temp:
            stage = Path(temp)
            candidate = stage / BUNDLE
            shutil.copytree(source, candidate, symlinks=True)
            if (bundle_fingerprint(candidate) != candidate_identity or
                    bundle_fingerprint(source) != candidate_identity):
                raise ValueError("source or staged bundle content changed")
            stage_fd = os.open(stage, flags)
            try:
                current = destination_dir.lstat()
                if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                    raise ValueError("installation directory changed during staging")
                publish_exclusive(stage_fd, destination_fd)
            finally:
                os.close(stage_fd)
        return destination_dir / BUNDLE
    finally:
        os.close(destination_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination-dir", type=Path, required=True)
    parser.add_argument("--review", action="store_true", help="Read-only candidate/installed content comparison")
    args = parser.parse_args()
    if args.review:
        try:
            print(json.dumps(review(args.source, args.destination_dir), sort_keys=True))
        except (OSError, ValueError, AttributeError, plistlib.InvalidFileException):
            parser.exit(1, "Bundle review unavailable. No changes made.\n")
        return
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.exit(1, "Fresh installation requires macOS and a non-root user.\n")
    try:
        install(args.source, args.destination_dir)
    except (OSError, ValueError, AttributeError, plistlib.InvalidFileException):
        parser.exit(1, "Installation not confirmed. Existing apps are never replaced; inspect the destination before retrying.\n")
    print("Fresh application copy installed. Upgrade, uninstall and release acceptance remain unverified.")


if __name__ == "__main__":
    main()
