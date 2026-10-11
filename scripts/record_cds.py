#!/usr/bin/env python3
"""Optional, isolated AppCDS recording with bounded process ownership.

Nothing inherited from a developer's engine configuration is trusted. The
engine binds port zero and announces its actual port in this launch's log.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

LAUNCH_OPTIONS = {
    "safeMode": True,
    "isolation": "worker",
    "policy": {"allowedRepositories": [], "allowUserRepositories": False,
               "allowCommunityTier": False, "allowDeveloperExtensions": False,
               "requireSandbox": True, "safeModeOnly": True},
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


# 0: the engine's own shutdown; -15 / 143: SIGTERM as Python and the JVM report it.
CLEAN_EXIT_STATUSES = (0, -15, 143)


def listening_port(log: Path) -> int | None:
    try:
        text = log.read_text(errors="replace")
    except (OSError, UnicodeError):
        return None
    for line in text.splitlines():
        try:
            event = json.loads(line)
            if isinstance(event, dict) and event.get("event") == "daemon.listening":
                port = int(event["fields"]["port"])
                if 0 < port <= 65535:
                    return port
        except (ValueError, TypeError, KeyError, IndexError):
            continue
    return None


def ready(port: int) -> bool:
    try:
        # Do not use a developer HTTP proxy for an owned loopback process.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f"http://127.0.0.1:{port}/health", timeout=2.0) as response:
            health = json.loads(response.read(64 * 1024))
        return isinstance(health, dict) and health.get("safeMode") is True and isinstance(health.get("isolation"), dict) and health["isolation"].get("mode") == "worker"
    except (OSError, ValueError, urllib.error.URLError):
        return False


def wait_for_archive(path: Path, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if path.is_file() and path.stat().st_size > 0:
                return True
        except OSError:
            pass
        time.sleep(0.05)
    return False


def record(java: Path, jar: Path, archive: Path, *, base: Path | None = None,
           startup_seconds: float = 30, shutdown_seconds: float = 12) -> bool:
    """With `base`, the engine runs from that directory with the jar given
    relative to it. JDK 17 matches the archive against the class path as
    written, so only a relative recording survives the app being copied."""
    archive.parent.mkdir(parents=True, exist_ok=True)
    metadata = archive.with_suffix(".cds.json")
    archive.unlink(missing_ok=True)
    metadata.unlink(missing_ok=True)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("CS_DAEMON_") and key not in
                   {"JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH"}}
    healthy = False
    forced = False
    process = None
    jar_path = jar.resolve()
    working_dir = base.resolve() if base else None
    jar_argument = (
        Path(os.path.relpath(jar_path, working_dir)).as_posix()
        if working_dir
        else jar_path.as_posix()
    )
    try:
        with tempfile.TemporaryDirectory(prefix="cloudstream-cds-") as temporary:
            root = Path(temporary)
            (root / "tmp").mkdir(mode=0o700)
            log = root / "recording.log"
            with log.open("wb") as output:
                process = subprocess.Popen(
                    [
                        str(java.resolve()),
                        "--add-modules=jdk.incubator.foreign",
                        "--enable-native-access=ALL-UNNAMED",
                        "-XX:TieredStopAtLevel=1",
                        "-Xms16m",
                        "-Xmx128m",
                        "-XX:+UseSerialGC",
                        f"-XX:ArchiveClassesAtExit={archive.resolve()}",
                        f"-Dcs.cloudstream.home={root}",
                        f"-Djava.io.tmpdir={root / 'tmp'}",
                        "-jar",
                        jar_argument,
                        "0",
                    ],
                    stdin=subprocess.PIPE,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    env=environment,
                    cwd=str(working_dir) if working_dir else None,
                )
                try:
                    process.stdin.write(
                        (
                            secrets.token_hex(32)
                            + "\n"
                            + json.dumps(LAUNCH_OPTIONS)
                            + "\n"
                        ).encode()
                    )
                    process.stdin.flush()
                    deadline = time.monotonic() + startup_seconds
                    while process.poll() is None and time.monotonic() < deadline:
                        try:
                            output.flush()
                        except OSError:
                            pass
                        port = listening_port(log)
                        if port and ready(port):
                            healthy = True
                            break
                        time.sleep(0.05)
                finally:
                    # Closing stdin first lets the daemon perform its normal shutdown.
                    if process.stdin is not None:
                        try:
                            process.stdin.close()
                        except (BrokenPipeError, OSError, ValueError):
                            pass

                    if process.poll() is None:
                        process.terminate()

                    try:
                        process.wait(timeout=shutdown_seconds)
                    except subprocess.TimeoutExpired:
                        forced = True
                        process.kill()
                        process.wait(timeout=5)

            # The archive is written by the JVM during shutdown, so inspect it only
            # after the child process has fully exited.
            archive_ready = False
            if healthy and not forced:
                archive_ready = wait_for_archive(archive, max(2.0, shutdown_seconds))
            else:
                try:
                    archive_ready = archive.is_file() and archive.stat().st_size > 0
                except OSError:
                    archive_ready = False

            valid = (
                healthy
                and not forced
                and archive_ready
                and process.returncode in CLEAN_EXIT_STATUSES
            )
            if valid:
                modules = java.resolve().parent.parent / "lib/modules"
                metadata.write_text(json.dumps({"version": 1, "jarSha256": digest(jar),
                                                "modulesSha256": digest(modules), "archiveSha256": digest(archive)}, sort_keys=True) + "\n")
                return True
            else:
                log_text = ""
                try:
                    log_text = log.read_text(errors="replace")
                except OSError:
                    pass
                sys.stderr.write(
                    f"\n[RECORD_FAILED] healthy={healthy} forced={forced} "
                    f"archive_ready={archive_ready} returncode={process.returncode if process else None} "
                    f"archive_exists={archive.is_file()}\n"
                    f"[RECORD_LOG]\n{log_text[-20000:]}\n"
                )
    finally:
        # KeyboardInterrupt, IO failure or rejected health cannot leave a stale
        # archive that the app mistakes for a verified current generation.
        if not metadata.is_file():
            archive.unlink(missing_ok=True)
    return False


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("java", type=Path)
    parser.add_argument("jar", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--base", type=Path, help="run from here with the jar path relative to it")
    parser.add_argument("--required", action="store_true", help="exit nonzero when no archive was recorded")
    args = parser.parse_args()
    try:
        success = record(args.java, args.jar, args.archive, base=args.base)
    except (OSError, ValueError, subprocess.SubprocessError):
        success = False
    print("AppCDS recorded with isolated safe-mode engine" if success else
          "warning: AppCDS unavailable; the runtime remains usable without it")
    if args.required and not success:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
