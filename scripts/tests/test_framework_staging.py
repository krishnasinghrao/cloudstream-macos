import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "stage_frameworks.sh"


class FrameworkStagingTests(unittest.TestCase):
    def test_real_directory_preserves_xcode_runtime_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as root:
            contents = pathlib.Path(root) / "App.app/Contents"
            source = contents / "Resources/Frameworks"
            source.mkdir(parents=True)
            (source / "libmpv.dylib").write_bytes(b"native")
            destination = contents / "Frameworks"
            destination.mkdir()
            (destination / "libclang_rt.tsan_osx_dynamic.dylib").write_bytes(b"sanitizer")
            for _ in range(2):
                subprocess.run(["bash", str(SCRIPT), str(contents)], check=True)
            self.assertEqual((destination / "libmpv.dylib").read_bytes(), b"native")
            self.assertEqual((destination / "libclang_rt.tsan_osx_dynamic.dylib").read_bytes(), b"sanitizer")
            self.assertFalse(source.exists())
            self.assertFalse(destination.is_symlink())

    def test_legacy_symlink_is_migrated(self):
        with tempfile.TemporaryDirectory() as root:
            contents = pathlib.Path(root) / "App.app/Contents"
            source = contents / "Resources/Frameworks"
            source.mkdir(parents=True)
            (source / "libmpv.dylib").write_bytes(b"native")
            (contents / "Frameworks").symlink_to("Resources/Frameworks")
            subprocess.run(["bash", str(SCRIPT), str(contents)], check=True)
            self.assertEqual((contents / "Frameworks/libmpv.dylib").read_bytes(), b"native")
            self.assertFalse((contents / "Frameworks").is_symlink())

    def test_unexpected_symlink_is_rejected_without_touching_target(self):
        with tempfile.TemporaryDirectory() as root:
            contents = pathlib.Path(root) / "App.app/Contents"
            contents.mkdir(parents=True)
            other = pathlib.Path(root) / "other"
            other.mkdir()
            (contents / "Frameworks").symlink_to(other)
            result = subprocess.run(["bash", str(SCRIPT), str(contents)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((contents / "Frameworks").is_symlink())
            self.assertTrue(other.exists())
