#!/usr/bin/env python3
"""Local CDN simulator for the player startup benchmarks.

Serves a directory over HTTP on 127.0.0.1, with byte ranges (default) or with
ranges ignored (--no-range, like a host that cannot seek). Prints the bound
port on stdout, then serves until killed.
"""
import argparse
import http.server
import os
import re
import socketserver
import sys

RANGE = re.compile(r"bytes=(\d*)-(\d*)$")
TYPES = {".mp4": "video/mp4", ".m4a": "audio/mp4", ".webm": "audio/webm", ".m3u8": "application/vnd.apple.mpegurl",
         ".ts": "video/mp2t"}


def handler(root, ranges):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def resolve(self):
            path = os.path.normpath(self.path.split("?", 1)[0]).lstrip("/")
            full = os.path.realpath(os.path.join(root, path))
            if not full.startswith(os.path.realpath(root) + os.sep) or not os.path.isfile(full):
                return None
            return full

        def do_HEAD(self):
            self.respond(head=True)

        def do_GET(self):
            self.respond(head=False)

        def respond(self, head):
            full = self.resolve()
            if full is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            size = os.path.getsize(full)
            start, end, status = 0, size - 1, 200
            match = RANGE.match(self.headers.get("Range", "")) if ranges else None
            if match and (match.group(1) or match.group(2)):
                if match.group(1):
                    start = int(match.group(1))
                    end = min(int(match.group(2)), size - 1) if match.group(2) else size - 1
                else:
                    start = max(0, size - int(match.group(2)))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206
            self.send_response(status)
            self.send_header("Content-Type", TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))
            self.send_header("Content-Length", str(end - start + 1))
            if ranges:
                self.send_header("Accept-Ranges", "bytes")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            with open(full, "rb") as source:
                source.seek(start)
                remaining = end - start + 1
                try:
                    while remaining > 0:
                        chunk = source.read(min(65536, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass

    return Handler


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--no-range", action="store_true")
    args = parser.parse_args()
    server = Server(("127.0.0.1", 0), handler(args.root, not args.no_range))
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
