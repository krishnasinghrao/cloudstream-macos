"""Fault-injected subprocess fixtures for the real build-time recorder."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "record_cds.py"
spec = importlib.util.spec_from_file_location("record_cds", SCRIPT)
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)

FAKE_JAVA = r'''#!/usr/bin/env python3
import http.server,json,os,pathlib,signal,socketserver,sys,threading
args=sys.argv[1:]
root=pathlib.Path(next(v.split('=',1)[1] for v in args if v.startswith('-Dcs.cloudstream.home=')))
archive=pathlib.Path(next(v.split('=',1)[1] for v in args if v.startswith('-XX:ArchiveClassesAtExit=')))
token=sys.stdin.readline().strip()
options=json.loads(sys.stdin.readline())
capture=pathlib.Path(os.environ['CDS_TEST_CAPTURE'])
capture.write_text(json.dumps({'root':str(root),'safeMode':options['safeMode'],
  'isolation':options['isolation'],'policy':options['policy'],'args':args,
  'tokenLength':len(token),'env':{k:v for k,v in os.environ.items() if k in
  ('CS_DAEMON_OPTIONS','CS_DAEMON_TOKEN','JAVA_TOOL_OPTIONS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS','CLASSPATH')}}))
stop=threading.Event()
if os.environ.get('CDS_TEST_HANG'):
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    stop.wait()
else:
    class Health(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200);self.end_headers()
            self.wfile.write(json.dumps({'safeMode':options['safeMode'],'isolation':{'mode':options['isolation']}}).encode())
        def log_message(self,*args): pass
    class FastServer(http.server.ThreadingHTTPServer):
        def server_bind(self):
            socketserver.TCPServer.server_bind(self)
            self.server_name = '127.0.0.1'
            self.server_port = self.server_address[1]
    server=FastServer(('127.0.0.1',0),Health)
    server.daemon_threads=True
    threading.Thread(target=server.serve_forever,daemon=True).start()
    print(json.dumps({'event':'daemon.listening','fields':{'port':server.server_port}}),flush=True)
    signal.signal(signal.SIGTERM,lambda *args:stop.set())
    stop.wait()
    archive.write_bytes(b'fixture archive')
    try:
        server.shutdown();server.server_close()
    except Exception:
        pass
    sys.exit(int(os.environ.get('CDS_TEST_EXIT_CODE','0')))
'''


class RecordingTests(unittest.TestCase):
    def fixture(self, work):
        root = Path(work)
        java = root / "runtime/bin/java"
        java.parent.mkdir(parents=True)
        java.write_text(FAKE_JAVA)
        java.chmod(0o755)
        modules = root / "runtime/lib/modules"
        modules.parent.mkdir()
        modules.write_bytes(b"modules")
        jar = root / "daemon.jar"
        jar.write_bytes(b"jar")
        return root, java, jar, root / "tools/daemon.jsa"

    def test_recording_ignores_inherited_options_and_removes_private_root(self):
        with tempfile.TemporaryDirectory() as work:
            root, java, jar, archive = self.fixture(work)
            capture = root / "capture.json"
            with patch.dict(os.environ, {"CDS_TEST_CAPTURE": str(capture),
                 "CS_DAEMON_OPTIONS": '{"safeMode":false,"isolation":"in-process"}',
                 "CS_DAEMON_TOKEN": "old-secret", "JAVA_TOOL_OPTIONS": "poisoned",
                 "JDK_JAVA_OPTIONS": "poisoned", "_JAVA_OPTIONS": "poisoned", "CLASSPATH": "poisoned"}):
                self.assertTrue(recorder.record(java, jar, archive, startup_seconds=15, shutdown_seconds=10))
            launch = json.loads(capture.read_text())
            self.assertTrue(launch["safeMode"])
            self.assertEqual(launch["isolation"], "worker")
            self.assertTrue(launch["policy"]["requireSandbox"])
            self.assertEqual(launch["env"], {})
            self.assertNotIn("old-secret", " ".join(launch["args"]))
            self.assertEqual(launch["tokenLength"], 64)
            self.assertFalse(Path(launch["root"]).exists())
            metadata = json.loads(archive.with_suffix(".cds.json").read_text())
            self.assertEqual(metadata["jarSha256"], recorder.digest(jar))
            self.assertEqual(metadata["archiveSha256"], recorder.digest(archive))

    def test_base_records_with_the_jar_relative_to_it(self):
        with tempfile.TemporaryDirectory() as work:
            root, java, _, archive = self.fixture(work)
            jar = root / "tools/daemon.jar"
            jar.parent.mkdir()
            jar.write_bytes(b"jar")
            capture = root / "capture.json"
            with patch.dict(os.environ, {"CDS_TEST_CAPTURE": str(capture)}):
                self.assertTrue(recorder.record(java, jar, archive, base=root, startup_seconds=15, shutdown_seconds=10))
            args = json.loads(capture.read_text())["args"]
            self.assertEqual(args[args.index("-jar") + 1], "tools/daemon.jar")

    def test_never_ready_process_is_killed_and_stale_archive_removed(self):
        with tempfile.TemporaryDirectory() as work:
            root, java, jar, archive = self.fixture(work)
            archive.parent.mkdir()
            archive.write_bytes(b"stale")
            capture = root / "capture.json"
            with patch.dict(os.environ, {"CDS_TEST_CAPTURE": str(capture), "CDS_TEST_HANG": "1"}):
                self.assertFalse(recorder.record(java, jar, archive, startup_seconds=2, shutdown_seconds=0.1))
            self.assertFalse(archive.exists())
            self.assertFalse(archive.with_suffix(".cds.json").exists())
            self.assertFalse(Path(json.loads(capture.read_text())["root"]).exists())

    def test_engine_that_exits_with_an_error_is_not_recorded(self):
        with tempfile.TemporaryDirectory() as work:
            root, java, jar, archive = self.fixture(work)
            capture = root / "capture.json"
            with patch.dict(os.environ, {"CDS_TEST_CAPTURE": str(capture), "CDS_TEST_EXIT_CODE": "1"}), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertFalse(recorder.record(java, jar, archive, startup_seconds=15, shutdown_seconds=10))
            self.assertFalse(archive.exists(), "an archive from a failed shutdown is never kept")
            self.assertFalse(archive.with_suffix(".cds.json").exists())

    def test_missing_executable_cannot_leave_stale_archive(self):
        with tempfile.TemporaryDirectory() as work:
            root, java, jar, archive = self.fixture(work)
            archive.parent.mkdir()
            archive.write_bytes(b"stale")
            with self.assertRaises(OSError):
                recorder.record(root / "missing-java", jar, archive)
            self.assertFalse(archive.exists())

    def test_listening_port_ignores_partial_lines(self):
        with tempfile.TemporaryDirectory() as work:
            log = Path(work) / "recording.log"
            log.write_text('{"event":"daemon.listening","fields":{"port":')
            self.assertIsNone(recorder.listening_port(log))
            log.write_text('{"event":"daemon.listening","fields":{"port":12345}}\n')
            self.assertEqual(recorder.listening_port(log), 12345)


if __name__ == "__main__":
    unittest.main()
