#!/usr/bin/env python3
"""Stage ffmpeg and libmpv with their complete non-system dependency closure.

    stage_media.py stage <ffmpeg> <libmpv.dylib> <staging dir> [--sign IDENTITY] [--min-os 15.0]
    stage_media.py check <ffmpeg> <libmpv.dylib> <staging dir>

`stage` builds Binaries/ and Frameworks/ in a private directory, then swaps
them into <staging dir>:

  * every dependency is resolved the way dyld would resolve it from the
    source location — absolute, @loader_path, @executable_path and @rpath —
    and a dependency that cannot be found is an error, not a skip;
  * every non-system dependency is copied and every reference to it rewritten
    to @rpath/<name>; a failed rewrite or signature is an error;
  * run paths that leave the bundle are removed, the bundle-relative ones
    added only when missing;
  * the result is checked by verify_macho_closure.py and by running the
    staged ffmpeg, and described in media-manifest.json.

`check` exits 0 only when the manifest matches both the given sources and the
staged files, so "an ffmpeg file exists" is never taken as proof.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
BUNDLE_RPATHS = ["@loader_path/../Frameworks", "@loader_path/../../Frameworks"]
MANIFEST = "media-manifest.json"


class StagingError(Exception):
    pass


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    if check and result.returncode != 0:
        raise StagingError(f"{' '.join(map(str, args))} failed: {(result.stderr or result.stdout).strip()}")
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_commands(path: Path) -> tuple[list[str], list[str], str | None]:
    """(dependencies, run paths, install name) of a Mach-O file."""
    dependencies, rpaths, install_name, command = [], [], None, ""
    for line in run("/usr/bin/otool", "-l", path).stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "cmd":
            command = parts[1]
        elif command == "LC_RPATH" and parts[:1] == ["path"]:
            rpaths.append(parts[1])
        elif command in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB") and parts[:1] == ["name"]:
            dependencies.append(parts[1])
        elif command == "LC_ID_DYLIB" and parts[:1] == ["name"]:
            install_name = parts[1]
    return list(dict.fromkeys(dependencies)), list(dict.fromkeys(rpaths)), install_name


def expand(token: str, loader: Path, executable: Path) -> Path | None:
    if token.startswith("@loader_path"):
        return Path(os.path.normpath(str(loader.parent) + token[len("@loader_path"):]))
    if token.startswith("@executable_path"):
        return Path(os.path.normpath(str(executable.parent) + token[len("@executable_path"):]))
    if token.startswith("/"):
        return Path(token)
    return None


def resolve(token: str, loader: Path, loader_rpaths: list[str], executable: Path, executable_rpaths: list[str]) -> Path | None:
    """Where `token`, referenced by `loader`, is found in the source tree."""
    if token.startswith("@rpath/"):
        tail = token[len("@rpath/"):]
        for owner, rpaths in ((loader, loader_rpaths), (executable, executable_rpaths)):
            for rpath in rpaths:
                base = expand(rpath, owner, executable)
                if base is not None and (base / tail).exists():
                    return (base / tail).resolve()
        return None
    target = expand(token, loader, executable)
    return target.resolve() if target is not None and target.exists() else None


def stage(ffmpeg: Path, libmpv: Path, staging: Path, identity: str | None, min_os: str | None) -> None:
    ffmpeg, libmpv = ffmpeg.resolve(), libmpv.resolve()
    for source in (ffmpeg, libmpv):
        if not source.is_file():
            raise StagingError(f"media source missing: {source}")
    staging.mkdir(parents=True, exist_ok=True)
    private = staging / f".media-staging-{os.getpid()}"
    shutil.rmtree(private, ignore_errors=True)
    binaries, frameworks = private / "Binaries", private / "Frameworks"
    binaries.mkdir(parents=True)
    frameworks.mkdir()
    try:
        _, executable_rpaths, _ = load_commands(ffmpeg)
        # staged file -> (source it was copied from, {token: staged name})
        plan: dict[Path, tuple[Path, dict[str, str]]] = {}
        copied: dict[Path, str] = {}     # source real path -> staged library name
        pending: list[tuple[Path, Path]] = []

        def add_primary(source: Path, destination: Path):
            shutil.copy2(source, destination)
            destination.chmod(0o755)
            plan[destination] = (source, {})
            pending.append((source, destination))

        add_primary(ffmpeg, binaries / "ffmpeg")
        add_primary(libmpv, binaries / "libmpv.dylib")

        while pending:
            source, destination = pending.pop()
            dependencies, rpaths, install_name = load_commands(source)
            for token in dependencies:
                if token.startswith(SYSTEM_PREFIXES) or token == install_name:
                    continue
                found = resolve(token, source, rpaths, ffmpeg, executable_rpaths)
                if found is None:
                    raise StagingError(f"{source}: dependency {token} does not resolve")
                if str(found).startswith(SYSTEM_PREFIXES):
                    continue
                name = copied.get(found)
                if name is None:
                    name = found.name
                    target = frameworks / name
                    if target.exists():
                        raise StagingError(f"two different libraries are both named {name}: {found} and another")
                    shutil.copy2(found, target)
                    target.chmod(0o644)
                    copied[found] = name
                    plan[target] = (found, {})
                    pending.append((found, target))
                plan[destination][1][token] = name

        for destination, (source, changes) in plan.items():
            is_library = destination.parent == frameworks or destination.name == "libmpv.dylib"
            if is_library:
                run("/usr/bin/install_name_tool", "-id", f"@rpath/{destination.name}", destination)
            for token, name in changes.items():
                if token != f"@rpath/{name}":
                    run("/usr/bin/install_name_tool", "-change", token, f"@rpath/{name}", destination)
            _, rpaths, _ = load_commands(destination)
            for rpath in rpaths:
                if rpath.startswith("/") and not rpath.startswith(SYSTEM_PREFIXES):
                    run("/usr/bin/install_name_tool", "-delete_rpath", rpath, destination)
            if destination.name == "ffmpeg":
                for rpath in BUNDLE_RPATHS:
                    if rpath not in rpaths:
                        run("/usr/bin/install_name_tool", "-add_rpath", rpath, destination)

        # Load commands are final: sign libraries first, the executable last.
        for destination in sorted(plan, key=lambda p: (p.name == "ffmpeg", str(p))):
            command = ["/usr/bin/codesign", "--force", "--sign", identity or "-"]
            if identity:
                command += ["--options", "runtime", "--timestamp"]
            run(*command, destination)

        verifier = [sys.executable, str(Path(__file__).with_name("verify_macho_closure.py")), str(private),
                    "--executable", str(binaries / "ffmpeg")]
        if min_os:
            verifier += ["--min-os", min_os]
        checked = subprocess.run(verifier, capture_output=True, text=True)
        if checked.returncode != 0:
            raise StagingError("staged media closure is incomplete:\n" + checked.stderr.strip())
        probe = subprocess.run([str(binaries / "ffmpeg"), "-version"], capture_output=True, text=True)
        if probe.returncode != 0:
            raise StagingError(f"staged ffmpeg does not start: {probe.stderr.strip()[:400]}")

        # build_media_stack.sh records what it built beside its prefix.
        provenance = ffmpeg.parent.parent / "media-provenance.json"
        manifest = {
            "sources": {"ffmpeg": {"path": str(ffmpeg), "sha256": sha256(ffmpeg)},
                        "libmpv": {"path": str(libmpv), "sha256": sha256(libmpv)}},
            "provenance": json.loads(provenance.read_text()) if provenance.is_file() else None,
            "minimumOS": min_os,
            "signing": "identity" if identity else "ad-hoc",
            "staged": {str(path.relative_to(private)): {"sha256": sha256(path), "from": str(source)}
                       for path, (source, _) in sorted(plan.items())},
        }
        # Swap in: old directories move aside first, so a failure never leaves
        # new binaries beside another build's libraries.
        retired = staging / f".media-retired-{os.getpid()}"
        shutil.rmtree(retired, ignore_errors=True)
        retired.mkdir()
        for name in ("Binaries", "Frameworks"):
            if (staging / name).exists():
                os.rename(staging / name, retired / name)
            os.rename(private / name, staging / name)
        (staging / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.rmtree(retired, ignore_errors=True)
        print(f"==> Staged media: {len(copied)} libraries + ffmpeg + libmpv into {staging}")
    finally:
        shutil.rmtree(private, ignore_errors=True)


def check(ffmpeg: Path, libmpv: Path, staging: Path) -> list[str]:
    """Reasons the staged media cannot be trusted; empty when it is current."""
    manifest_path = staging / MANIFEST
    if not manifest_path.is_file():
        return ["no media manifest: the staged files have no recorded origin"]
    try:
        manifest = json.loads(manifest_path.read_text())
    except ValueError:
        return ["the media manifest is unreadable"]
    problems = []
    for key, source in (("ffmpeg", ffmpeg), ("libmpv", libmpv)):
        recorded = manifest.get("sources", {}).get(key, {})
        if not source.is_file():
            problems.append(f"media source missing: {source}")
        elif sha256(source.resolve()) != recorded.get("sha256"):
            problems.append(f"{key} source changed since it was staged")
    staged = manifest.get("staged", {})
    for relative, entry in staged.items():
        path = staging / relative
        if not path.is_file():
            problems.append(f"staged file missing: {relative}")
        elif sha256(path) != entry.get("sha256"):
            problems.append(f"staged file changed: {relative}")
    for directory in ("Binaries", "Frameworks"):
        present = {f"{directory}/{p.name}" for p in (staging / directory).glob("*") if p.is_file()} if (staging / directory).is_dir() else set()
        for extra in sorted(present - set(staged)):
            problems.append(f"unrecorded file: {extra}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["stage", "check"])
    parser.add_argument("ffmpeg", type=Path)
    parser.add_argument("libmpv", type=Path)
    parser.add_argument("staging", type=Path)
    parser.add_argument("--sign")
    parser.add_argument("--min-os")
    arguments = parser.parse_args()
    if arguments.action == "check":
        problems = check(arguments.ffmpeg, arguments.libmpv, arguments.staging)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1 if problems else 0
    try:
        stage(arguments.ffmpeg, arguments.libmpv, arguments.staging, arguments.sign or None, arguments.min_os)
    except StagingError as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
