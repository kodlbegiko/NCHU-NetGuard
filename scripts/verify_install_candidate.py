#!/usr/bin/env python3
"""Verify actual built bundles in private temporary directories only.

Never installs into Applications, launches an app, performs upgrades, or
modifies user settings. Not device lifecycle or code-signing acceptance.
"""
import argparse
from pathlib import Path
import tempfile

from install_bundle import BUNDLE, bundle_fingerprint, install, review


def verify(app, root):
    source = Path(app).absolute()
    expected = bundle_fingerprint(source)
    dest = root / "isolated-apps"
    before = review(source, dest)
    if before["operation"] != "fresh_install_candidate" or dest.exists():
        raise ValueError("fresh candidate preflight failed")
    installed = install(source, dest)
    if installed != dest / BUNDLE or bundle_fingerprint(installed) != expected:
        raise ValueError("installed content does not match built source")
    after = review(source, dest)
    if (after["operation"] != "identical_content" or
            after["installed_sha256"] != expected or after["mutation_authorized"]):
        raise ValueError("installed candidate identity review failed")
    try:
        install(source, dest)
    except FileExistsError:
        pass
    else:
        raise ValueError("second install did not refuse existing bundle")
    if (bundle_fingerprint(installed) != expected or
            bundle_fingerprint(source) != expected or list(dest.iterdir()) != [installed]):
        raise ValueError("existing copy/source changed or staging remained")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", action="append", type=Path, required=True)
    args = parser.parse_args()
    try:
        for app in args.app:
            with tempfile.TemporaryDirectory(prefix="netguard-install-check-") as folder:
                verify(app, Path(folder))
    except (OSError, ValueError, AttributeError) as error:
        parser.exit(1, "Isolated built-bundle verification failed: " + type(error).__name__ + "\n")
    print("NETGUARD_ISOLATED_INSTALL_OK bundles=" + str(len(args.app)))


if __name__ == "__main__":
    main()
