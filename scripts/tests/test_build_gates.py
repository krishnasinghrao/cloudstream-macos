"""Exercise failure propagation through the real log wrapper and Make recipe."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BuildGateTests(unittest.TestCase):
    def test_logged_command_preserves_failure_and_output(self):
        with tempfile.TemporaryDirectory() as work:
            log = Path(work) / "logs" / "build.log"
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/run_logged.sh"), str(log),
                 "bash", "-c", "echo compiler-failed; exit 73"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 73)
            self.assertIn("compiler-failed", log.read_text())

    def test_logged_command_preserves_success(self):
        with tempfile.TemporaryDirectory() as work:
            log = Path(work) / "build.log"
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/run_logged.sh"), str(log),
                 "bash", "-c", "echo build-passed"], capture_output=True,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(log.read_text(), "build-passed\n")

    def test_make_rejects_xcodebuild_failure(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            (root / "scripts").mkdir()
            shutil.copy2(ROOT / "Makefile", root / "Makefile")
            shutil.copy2(ROOT / "scripts/run_logged.sh", root / "scripts")
            fake = root / "xcodebuild"
            fake.write_text("#!/bin/bash\necho XCTest-failed\nexit 71\n")
            fake.chmod(0o755)
            result = subprocess.run(
                ["make", "test-client"], cwd=root,
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}"},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            logs = list((root / "client/build/test-results").glob("*/xcodebuild.log"))
            self.assertEqual(len(logs), 1)
            self.assertIn("XCTest-failed", logs[0].read_text())

    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler is not installed on this runner")
    def test_actual_swift_compiler_error_is_not_masked(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            source = root / "Invalid.swift"
            source.write_text('let invalid: Int = "not an integer"\n')
            log = root / "compiler.log"
            result = subprocess.run([
                "bash", str(ROOT / "scripts/run_logged.sh"), str(log),
                shutil.which("swiftc"), "-swift-version", "6", "-module-cache-path",
                str(root / "modules"), str(source), "-o", str(root / "invalid"),
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot convert value of type", log.read_text())


if __name__ == "__main__":
    unittest.main()
