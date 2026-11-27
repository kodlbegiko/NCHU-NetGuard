import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("install_bundle", ROOT / "scripts/install_bundle.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "build" / installer.BUNDLE
        for relative in installer.REQUIRED:
            file = self.source / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"fixture")
        (self.source / installer.REQUIRED[0]).write_bytes(plistlib.dumps({
            "CFBundleExecutable": "NCHUTraffic",
            "CFBundleIdentifier": "tw.edu.nchu.dorm.traffic",
            "CFBundlePackageType": "APPL",
        }))
        (self.source / installer.REQUIRED[1]).chmod(0o700)
        self.destination = self.root / "Applications"
        self.destination.mkdir(mode=0o700)

    def test_existing_directory_or_dangling_link_is_never_replaced(self):
        target = self.destination / installer.BUNDLE
        target.mkdir()
        marker = target / "old"
        marker.write_text("keep")
        with patch.object(installer, "publish_exclusive") as publish:
            with self.assertRaises(FileExistsError):
                installer.install(self.source, self.destination)
            publish.assert_not_called()
        self.assertEqual(marker.read_text(), "keep")
        marker.unlink()
        target.rmdir()
        target.symlink_to(self.root / "missing")
        with self.assertRaises(FileExistsError):
            installer.install(self.source, self.destination)
        self.assertTrue(target.is_symlink())

    def test_invalid_or_linked_source_fails_before_publication(self):
        binary = self.source / installer.REQUIRED[1]
        binary.chmod(0o600)
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination)
        binary.chmod(0o700)
        target = self.root / "outside"
        target.write_text("private")
        (self.source / "link").symlink_to(target)
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertEqual(target.read_text(), "private")

    def test_failed_publication_cleans_only_staging_and_keeps_source(self):
        with patch.object(installer, "publish_exclusive", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                installer.install(self.source, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])
        self.assertTrue((self.source / installer.REQUIRED[1]).exists())

    def test_unsafe_destination_rejected(self):
        self.destination.chmod(0o777)
        with self.assertRaises(ValueError):
            installer.install(self.source, self.destination)
        self.destination.chmod(0o700)
        link = self.root / "redirect"
        link.symlink_to(self.destination)
        with self.assertRaises(OSError):
            installer.install(self.source, link)
        self.assertEqual(list(self.destination.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "Darwin exclusive rename required")
    def test_real_fresh_publication_and_second_install_rejected(self):
        target = installer.install(self.source, self.destination)
        installer.validate_bundle(target)
        self.assertEqual((target / installer.REQUIRED[1]).read_bytes(), b"fixture")
        self.assertTrue((self.source / installer.REQUIRED[1]).exists())
        with self.assertRaises(FileExistsError):
            installer.install(self.source, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [target])

    @unittest.skipUnless(sys.platform == "darwin", "Darwin exclusive rename required")
    def test_real_publication_refuses_destination_created_after_preflight(self):
        target = self.destination / installer.BUNDLE
        real_publish = installer.publish_exclusive
        def race(stage_fd, destination_fd):
            target.mkdir()
            # An empty target directory would be replaceable by plain rename.
            real_publish(stage_fd, destination_fd)
        with patch.object(installer, "publish_exclusive", side_effect=race):
            with self.assertRaises(OSError):
                installer.install(self.source, self.destination)
        self.assertTrue(target.is_dir())
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(list(self.destination.iterdir()), [target])
        self.assertTrue((self.source / installer.REQUIRED[1]).exists())


if __name__ == "__main__":
    unittest.main()
