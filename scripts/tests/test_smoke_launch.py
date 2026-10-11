"""The smoke launch must fail for every unmet criterion and touch only its own processes."""
from pathlib import Path
import os
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SMOKE = ROOT / "scripts/smoke_launch.sh"

# A stand-in app. It honours the same contract as the real one: a private
# root, a status file naming the engine it owns, and engine output markers.
FAKE_APP = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, signal, subprocess, sys, time
    mode = os.environ.get("FAKE_MODE", "ok")
    root = os.environ["CS_TEST_ROOT"]
    assert os.environ["CS_IN_MEMORY_DB"] == "1"
    status = os.environ["CS_SMOKE_STATUS_FILE"]
    if mode == "dies":
        sys.exit(3)
    os.makedirs(os.path.join(root, "Logs"), exist_ok=True)
    log = open(os.path.join(root, "Logs", "daemon-stdout.log"), "a")
    def spawn():
        # A new session, so signals to the app do not reach the "engine".
        return subprocess.Popen(["/bin/sleep", "300"], start_new_session=True)
    engine = spawn()
    if mode != "nomarker":
        log.write("=== engine launch X started now safeMode=false ===\\n"); log.flush()
    def write(phase, pid, app=os.getpid(), ffmpeg=True):
        tmp = status + ".tmp"
        json.dump({"appPID": app, "generation": 3, "phase": phase, "enginePID": pid, "launchID": "L",
                   "ipcVersion": 6, "player": {"ffmpeg": ffmpeg, "libmpv": True}}, open(tmp, "w"))
        os.replace(tmp, status)
    def quit(*_):
        if mode != "orphan":
            engine.terminate(); engine.wait()
        if mode not in ("nomarker", "noexitmarker"):
            log.write("=== engine launch X ended now status=143 ===\\n"); log.flush()
        sys.exit(0)
    signal.signal(signal.SIGTERM, (lambda *_: None) if mode == "hangs" else quit)
    if mode == "never":
        write("restoring", engine.pid)
    elif mode == "failed":
        write("failed", engine.pid)
    elif mode == "stale":
        write("usable", engine.pid, app=1)          # another app's status
    elif mode == "foreign":
        write("usable", int(os.environ["FOREIGN_PID"]))   # an engine this app does not own
    elif mode == "noplayer":
        write("usable", engine.pid, ffmpeg=False)
    else:
        write("usable", engine.pid)
    print("ENGINE", engine.pid, flush=True)
    while True:
        time.sleep(0.1)
''')


class SmokeLaunchTests(unittest.TestCase):
    def run_smoke(self, mode, extra=None):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        app = Path(work.name) / "CloudStream"
        app.write_text(FAKE_APP)
        app.chmod(0o755)
        env = {**os.environ, "FAKE_MODE": mode, "TMPDIR": work.name,
               "CS_SMOKE_READY_TIMEOUT": "4", "CS_SMOKE_QUIT_TIMEOUT": "3", **(extra or {})}
        result = subprocess.run(["bash", str(SMOKE), str(app)], env=env, capture_output=True, text=True)
        roots = list(Path(work.name).glob("cloudstream-smoke.*"))
        return result, roots

    def engine_pid(self, roots):
        text = (roots[0] / "app.log").read_text()
        return int(text.split("ENGINE", 1)[1].split()[0])

    def assert_gone(self, pid):
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_healthy_launch_passes_and_leaves_nothing_behind(self):
        result, roots = self.run_smoke("ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("smoke: PASSED", result.stdout)
        self.assertEqual(roots, [], "the private root is removed after a pass")

    def test_every_unmet_criterion_fails_nonzero(self):
        expectations = {
            "dies": "exited before its engine was usable",
            "never": "was not usable within",
            "failed": "reported that its engine failed",
            "stale": "was not usable within",          # a status for another app pid is not this launch
            "noplayer": "no usable ffmpeg",
            "hangs": "did not quit within",
            "orphan": "outlived the app",
            "nomarker": "no start marker",
            "noexitmarker": "no exit marker",
        }
        for mode, message in expectations.items():
            with self.subTest(mode=mode):
                result, roots = self.run_smoke(mode)
                self.assertEqual(result.returncode, 1, f"{mode}: {result.stdout}{result.stderr}")
                self.assertIn(message, result.stderr)
                self.assertNotIn("PASSED", result.stdout)
                self.assertEqual(len(roots), 1, "evidence is kept after a failure")
                if mode != "dies":
                    # Whatever the outcome, this run's own engine is not left running.
                    self.assert_gone(self.engine_pid(roots))

    def test_an_engine_the_app_does_not_own_fails_and_is_never_signalled(self):
        unrelated = subprocess.Popen(["/bin/sleep", "300"], start_new_session=True)
        self.addCleanup(lambda: (unrelated.kill(), unrelated.wait()))
        result, _ = self.run_smoke("foreign", {"FOREIGN_PID": str(unrelated.pid)})
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not a child of the launched app", result.stderr)
        self.assertIsNone(unrelated.poll(), "another process is untouched even though the app named it")

    def test_an_unrelated_running_engine_does_not_satisfy_or_disturb_the_check(self):
        unrelated = subprocess.Popen(["/bin/sleep", "300"], start_new_session=True)
        self.addCleanup(lambda: (unrelated.kill(), unrelated.wait()))
        result, _ = self.run_smoke("never")
        self.assertEqual(result.returncode, 1)
        self.assertIsNone(unrelated.poll())

    def test_missing_executable_and_usage_are_errors(self):
        self.assertEqual(subprocess.run(["bash", str(SMOKE)], capture_output=True).returncode, 2)
        self.assertEqual(subprocess.run(["bash", str(SMOKE), "/nonexistent/CloudStream.app"], capture_output=True).returncode, 1)

    def test_build_script_reports_a_skipped_smoke_run_as_not_run(self):
        text = (ROOT / "scripts/build_dev.sh").read_text()
        self.assertIn('smoke_launch.sh" "$FINAL_APP"', text)
        self.assertIn("smoke: not run", text)
        self.assertNotIn("pgrep", text)
        self.assertNotIn('grep -q "daemon.ready"', text)


if __name__ == "__main__":
    unittest.main()
