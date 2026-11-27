#!/usr/bin/env python3
"""Fresh, user-owned macOS bundle installation; never upgrade or uninstall."""
import argparse
import ctypes
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


def validate_bundle(bundle):
    if bundle.name != BUNDLE or not stat.S_ISDIR(bundle.lstat().st_mode):
        raise ValueError("not the expected application directory")

    def fail(error):
        raise error

    # Built bundles contain regular files and directories only. Reject links
    # instead of copying or following them into the installed bundle.
    for root, dirs, files in os.walk(bundle, followlinks=False, onerror=fail):
        for name in dirs + files:
            info = (Path(root) / name).lstat()
            if not (stat.S_ISDIR(info.st_mode) or
                    (stat.S_ISREG(info.st_mode) and info.st_nlink == 1)):
                raise ValueError("unsupported bundle entry")
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
    validate_bundle(source)
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
            validate_bundle(candidate)
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
    args = parser.parse_args()
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.exit(1, "Fresh installation requires macOS and a non-root user.\n")
    try:
        install(args.source, args.destination_dir)
    except (OSError, ValueError, AttributeError, plistlib.InvalidFileException):
        parser.exit(1, "Installation not confirmed. Existing apps are never replaced; inspect the destination before retrying.\n")
    print("Fresh application copy installed. Upgrade, uninstall and release acceptance remain unverified.")


if __name__ == "__main__":
    main()
