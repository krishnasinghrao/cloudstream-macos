"""End-to-end check of the split-stream relay (audit A35).

The real engine jar relays a video-only and an audio-only file that sit behind
different cookies; the real mpv plays the same merged manifest the app builds,
starting from a seek. Skipped when the jar, Java, mpv or ffmpeg is missing.
"""
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

REPO = Path(__file__).resolve().parents[2]
JAR = REPO / "engine/build/libs/daemon.jar"
LAUNCH_OPTIONS = {
    "safeMode": True,
    "isolation": "worker",
    "policy": {"allowedRepositories": [], "allowUserRepositories": False,
               "allowCommunityTier": False, "allowDeveloperExtensions": False,
               "requireSandbox": True, "safeModeOnly": True},
}
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def java_binary():
    home = os.environ.get("JAVA_HOME")
    if not home:
        found = subprocess.run(["/usr/libexec/java_home", "-v", "17"], capture_output=True, text=True)
        home = found.stdout.strip() if found.returncode == 0 else ""
    binary = Path(home) / "bin/java" if home else None
    return binary if binary and binary.is_file() else None


MISSING = [name for name, present in (("daemon.jar", JAR.is_file()), ("java 17", java_binary()),
                                      ("mpv", shutil.which("mpv")), ("ffmpeg", shutil.which("ffmpeg"))) if not present]


class Origin(http.server.BaseHTTPRequestHandler):
    """Range-capable files, each behind its own cookie."""
    files = {}      # path -> (bytes, required cookie)
    seen = []       # (path, cookie, range, other header names)
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        data, cookie = self.files.get(self.path, (None, None))
        Origin.seen.append((self.path, self.headers.get("Cookie"), self.headers.get("Range"),
                            sorted(name.lower() for name in self.headers.keys())))
        if data is None or self.headers.get("Cookie") != cookie:
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start, end = 0, len(data) - 1
        requested = self.headers.get("Range")
        if requested:
            first, _, last = requested.removeprefix("bytes=").partition("-")
            start = int(first)
            end = int(last) if last else end
        self.send_response(206 if requested else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        try:
            self.wfile.write(data[start:end + 1])
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def edl_quoted(value: str) -> str:
    return f"%{len(value.encode())}%{value}"


def split_manifest(video: str, audio: str) -> str:
    """The manifest PlaybackResource.split builds for one audio track."""
    return "edl://" + ";".join(["!no_clip", "!no_chapters", edl_quoted(video),
                                "!new_stream", "!no_clip", "!no_chapters", edl_quoted(audio)])


@unittest.skipIf(MISSING, "needs " + ", ".join(MISSING))
class RelayPlaybackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="cloudstream-relay-"))
        (cls.work / "tmp").mkdir(mode=0o700)
        quiet = ["ffmpeg", "-v", "error", "-y"]
        subprocess.run(quiet + ["-f", "lavfi", "-i", "testsrc=size=320x180:rate=24:duration=20", "-an",
                                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24", str(cls.work / "video.mp4")], check=True)
        subprocess.run(quiet + ["-f", "lavfi", "-i", "sine=frequency=440:duration=20", "-vn",
                                "-c:a", "aac", str(cls.work / "audio.m4a")], check=True)
        Origin.files = {"/video.mp4": ((cls.work / "video.mp4").read_bytes(), "v=1"),
                        "/audio.m4a": ((cls.work / "audio.m4a").read_bytes(), "a=2")}
        # An HLS rendition whose playlist and segments all need cookie h=3.
        (cls.work / "hls").mkdir()
        subprocess.run(quiet + ["-f", "lavfi", "-i", "testsrc=size=320x180:rate=24:duration=12", "-an",
                                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "24", "-f", "hls", "-hls_time", "2",
                                "-hls_list_size", "0", "-hls_segment_filename", str(cls.work / "hls/seg%03d.ts"),
                                str(cls.work / "hls/index.m3u8")], check=True)
        for item in (cls.work / "hls").iterdir():
            Origin.files["/hls/" + item.name] = (item.read_bytes(), "h=3")
        cls.origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        threading.Thread(target=cls.origin.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.origin.server_port}"

        cls.token = secrets.token_hex(32)
        cls.log = cls.work / "engine.log"
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("CS_DAEMON_") and key not in
                       {"JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH"}}
        cls.output = cls.log.open("wb")
        cls.engine = subprocess.Popen([str(java_binary()), "-Xmx256m", "-Dcs.test.relayAllowsLoopback=true",
                                       f"-Dcs.cloudstream.home={cls.work / 'home'}",
                                       f"-Djava.io.tmpdir={cls.work / 'tmp'}", "-jar", str(JAR), "0"],
                                      stdin=subprocess.PIPE, stdout=cls.output, stderr=subprocess.STDOUT, env=environment)
        cls.engine.stdin.write((cls.token + "\n" + json.dumps(LAUNCH_OPTIONS) + "\n").encode())
        cls.engine.stdin.flush()
        cls.port = None
        deadline = time.monotonic() + 40
        while cls.engine.poll() is None and time.monotonic() < deadline and cls.port is None:
            for line in cls.log.read_text(errors="replace").splitlines():
                try:
                    event = json.loads(line)
                    if event.get("event") == "daemon.listening":
                        cls.port = int(event["fields"]["port"])
                except (ValueError, TypeError, KeyError, AttributeError):
                    continue
            time.sleep(0.1)
        if cls.port is None:
            cls.tearDownClass()
            raise RuntimeError("the engine did not start listening")

    @classmethod
    def tearDownClass(cls):
        if cls.engine.poll() is None:
            cls.engine.terminate()
            try:
                cls.engine.wait(timeout=12)
            except subprocess.TimeoutExpired:
                cls.engine.kill()
                cls.engine.wait(timeout=5)
        cls.engine.stdin.close()
        cls.output.close()
        cls.origin.shutdown()
        cls.origin.server_close()
        shutil.rmtree(cls.work, ignore_errors=True)

    def call(self, path, body):
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=json.dumps(body).encode(),
                                         headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        with OPENER.open(request, timeout=10) as response:
            return json.loads(response.read())

    def play(self, manifest):
        """Plays seconds 12–14 with the player's one global header set; returns (exit code, output)."""
        result = subprocess.run(["mpv", "--no-config", "--vo=null", "--ao=null", "--start=12", "--length=2",
                                 "--http-header-fields=Cookie: v=1", "--msg-level=all=warn,term-msg=info",
                                 "--term-playing-msg=TRACKS video=${video-codec} audio=${audio-codec} at=${=time-pos}",
                                 "--", manifest], capture_output=True, text=True, timeout=90)
        return result.returncode, result.stdout + result.stderr

    def test_split_stream_behind_different_cookies_plays_and_seeks_through_the_relay(self):
        # Control: loaded directly, the audio origin gets the video's cookie and refuses.
        Origin.seen.clear()
        _, direct = self.play(split_manifest(self.base + "/video.mp4", self.base + "/audio.m4a"))
        self.assertTrue(any(path == "/audio.m4a" and cookie == "v=1" for path, cookie, _, _ in Origin.seen),
                        "the fixture did not see the leak the relay exists to prevent")
        self.assertNotIn("audio=AAC", direct)

        Origin.seen.clear()
        session = self.call("/media/relay", {"resources": [
            {"url": self.base + "/video.mp4", "headers": {"Cookie": "v=1"}},
            {"url": self.base + "/audio.m4a", "headers": {"Cookie": "a=2"}}]})
        addresses = [f"http://127.0.0.1:{self.port}{path}" for path in session["paths"]]
        code, output = self.play(split_manifest(*addresses))
        self.assertEqual(code, 0, output)
        self.assertIn("video=H.264", output)
        self.assertIn("audio=AAC", output)
        position = float(output.split(" at=")[1].split()[0])
        self.assertGreaterEqual(position, 11.0, "playback started at the seek target, not at zero")

        video = [entry for entry in Origin.seen if entry[0] == "/video.mp4"]
        audio = [entry for entry in Origin.seen if entry[0] == "/audio.m4a"]
        self.assertTrue(video and audio)
        self.assertEqual({cookie for _, cookie, _, _ in video}, {"v=1"})
        self.assertEqual({cookie for _, cookie, _, _ in audio}, {"a=2"}, "the audio origin never saw the video's cookie")
        self.assertTrue(any(requested and not requested.startswith("bytes=0-") for _, _, requested, _ in video + audio),
                        "seeking reached the origin as a range request")
        for _, _, _, names in video + audio:
            self.assertNotIn("authorization", names)

        self.call("/media/relay/revoke", {"sessionId": session["sessionId"]})
        with self.assertRaises(urllib.error.HTTPError) as refused:
            OPENER.open(addresses[0], timeout=10)
        self.assertEqual(refused.exception.code, 404)
        refused.exception.close()

    def test_hls_behind_a_cookie_plays_through_the_rewritten_playlist(self):
        Origin.seen.clear()
        session = self.call("/media/relay", {"resources": [{"url": self.base + "/hls/index.m3u8", "headers": {"Cookie": "h=3"}}]})
        address = f"http://127.0.0.1:{self.port}{session['paths'][0]}"
        result = subprocess.run(["mpv", "--no-config", "--vo=null", "--ao=null", "--start=6", "--length=2",
                                 "--http-header-fields=Cookie: wrong", "--msg-level=all=warn,term-msg=info",
                                 "--term-playing-msg=TRACKS video=${video-codec} at=${=time-pos}", "--", address],
                                capture_output=True, text=True, timeout=90)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("video=H.264", output)
        segments = [entry for entry in Origin.seen if entry[0].startswith("/hls/seg")]
        self.assertTrue(segments, "segments were read")
        self.assertEqual({cookie for _, cookie, _, _ in segments}, {"h=3"}, "every segment request carried the provider cookie")
        self.call("/media/relay/revoke", {"sessionId": session["sessionId"]})


if __name__ == "__main__":
    unittest.main()
