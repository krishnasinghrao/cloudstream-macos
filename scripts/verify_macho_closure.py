#!/usr/bin/env python3
"""Prove that every Mach-O under a directory loads only from that directory or the system.

For each Mach-O file below ROOT this resolves every load command the way dyld
would: absolute paths, @loader_path, @executable_path and @rpath (using the
binary's own LC_RPATH entries and those of the executables that can load it).
It fails on a dependency that does not resolve, resolves outside ROOT, on a
run path pointing outside ROOT, on a wrong architecture, and on a binary that
needs a newer macOS than --min-os.

    verify_macho_closure.py <root> [--min-os 15.0] [--arch arm64]
                            [--executable <path>]... [--include <subdir>]...
                            [--inventory out.json]

--include limits which files are checked to those below the named
subdirectories of ROOT; dependencies may still resolve anywhere in ROOT.

--executable names the programs that load the libraries (default: every
MH_EXECUTE found). The inventory lists every Mach-O with its SHA-256,
architectures, minimum macOS and resolved dependencies.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
          b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def run(*args: str) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    if magic not in MAGICS:
        return False
    # Java class files share the fat magic; `file` tells them apart.
    return "Mach-O" in run("/usr/bin/file", "-b", str(path))


def version_tuple(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split(".") if part.isdigit())


class Binary:
    def __init__(self, path: Path):
        self.path = path
        self.archs = run("/usr/bin/lipo", "-archs", str(path)).split()
        commands = run("/usr/bin/otool", "-l", str(path)).splitlines()
        self.rpaths: list[str] = []
        self.dependencies: list[str] = []
        self.install_name: str | None = None
        self.min_os: str | None = None
        self.filetype = ""
        header = run("/usr/bin/otool", "-hv", str(path))
        for kind in ("EXECUTE", "DYLIB", "BUNDLE"):
            if f" {kind} " in header:
                self.filetype = kind
                break
        command = ""
        for line in commands:
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "cmd":
                command = parts[1]
            elif command == "LC_RPATH" and parts[:1] == ["path"]:
                self.rpaths.append(parts[1])
            elif command in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB") \
                    and parts[:1] == ["name"]:
                self.dependencies.append(parts[1])
            elif command == "LC_ID_DYLIB" and parts[:1] == ["name"]:
                self.install_name = parts[1]
            elif command == "LC_BUILD_VERSION" and parts[:1] == ["minos"] and self.min_os is None:
                self.min_os = parts[1]
            elif command == "LC_VERSION_MIN_MACOSX" and parts[:1] == ["version"] and self.min_os is None:
                self.min_os = parts[1]
        self.dependencies = list(dict.fromkeys(self.dependencies))
        self.rpaths = list(dict.fromkeys(self.rpaths))


def expand(token: str, loader: Path, executable: Path | None) -> Path | None:
    if token.startswith("@loader_path"):
        return Path(os.path.normpath(str(loader.parent) + token[len("@loader_path"):]))
    if token.startswith("@executable_path"):
        if executable is None:
            return None
        return Path(os.path.normpath(str(executable.parent) + token[len("@executable_path"):]))
    if token.startswith("/"):
        return Path(os.path.normpath(token))
    return None


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root)
        return True
    except ValueError:
        return False


def verify(root: Path, min_os: str | None, arch: str | None, executables: list[Path] | None,
           include: list[str] | None = None):
    root = root.resolve()
    scopes = [root / name for name in include] if include else [root]
    binaries = [Binary(p) for scope in scopes for p in sorted(scope.rglob("*"))
                if p.is_file() and not p.is_symlink() and is_macho(p)]
    loaders = [b for b in binaries if b.filetype == "EXECUTE"]
    if executables:
        wanted = {p.resolve() for p in executables}
        loaders = [b for b in loaders if b.path.resolve() in wanted]
        missing = wanted - {b.path.resolve() for b in loaders}
        if missing:
            raise SystemExit(f"error: not a Mach-O executable under the root: {sorted(map(str, missing))}")
    errors: list[str] = []
    inventory = []
    for binary in binaries:
        relative = binary.path.relative_to(root)
        # Who can be the main executable when this file is loaded.
        mains = [binary] if binary.filetype == "EXECUTE" else loaders
        if arch and arch not in binary.archs:
            errors.append(f"{relative}: architecture {'/'.join(binary.archs)} lacks {arch}")
        if min_os and binary.min_os and version_tuple(binary.min_os) > version_tuple(min_os):
            errors.append(f"{relative}: requires macOS {binary.min_os}, newer than {min_os}")
        for rpath in binary.rpaths:
            if rpath.startswith("/") and not rpath.startswith(SYSTEM_PREFIXES) and not inside(Path(rpath), root):
                errors.append(f"{relative}: run path leaves the bundle: {rpath}")
        resolved_dependencies = []
        for dependency in binary.dependencies:
            if dependency.startswith(SYSTEM_PREFIXES):
                resolved_dependencies.append({"name": dependency, "system": True})
                continue
            candidates: list[Path] = []
            if dependency.startswith("@rpath/"):
                tail = dependency[len("@rpath/"):]
                # dyld searches the run paths of the whole loader chain.
                stack = [(binary, main) for main in (mains or [None])] + [(main, main) for main in mains]
                for owner, main in stack:
                    if owner is None:
                        continue
                    for rpath in owner.rpaths:
                        base = expand(rpath, owner.path, main.path if main else None)
                        if base is not None:
                            candidates.append(base / tail)
                # A JDK's native libraries name @rpath/libjvm.dylib without a
                # run path that reaches it: the java launcher loads
                # lib/server/libjvm.dylib first, and dyld reuses that image by
                # its install name (vendor JDKs such as Temurin ship this way).
                if tail == "libjvm.dylib":
                    for ancestor in binary.path.parents:
                        if ancestor.name == "lib" and (ancestor / "server/libjvm.dylib").is_file():
                            candidates.append(ancestor / "server/libjvm.dylib")
                            break
            elif dependency.startswith("@executable_path"):
                for main in mains:
                    target = expand(dependency, binary.path, main.path)
                    if target is not None:
                        candidates.append(target)
            else:
                target = expand(dependency, binary.path, None)
                if target is not None:
                    candidates.append(target)
            existing = [c for c in dict.fromkeys(candidates) if c.exists()]
            internal = [c for c in existing if inside(c, root)]
            if internal:
                resolved_dependencies.append({"name": dependency, "path": str(internal[0].resolve().relative_to(root))})
            elif existing:
                errors.append(f"{relative}: {dependency} resolves outside the bundle: {existing[0]}")
            else:
                errors.append(f"{relative}: {dependency} does not resolve")
        inventory.append({
            "path": str(relative),
            "sha256": hashlib.sha256(binary.path.read_bytes()).hexdigest(),
            "type": binary.filetype or "OTHER",
            "architectures": binary.archs,
            "minimumOS": binary.min_os,
            "installName": binary.install_name,
            "runPaths": binary.rpaths,
            "dependencies": resolved_dependencies,
        })
    return inventory, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", type=Path)
    parser.add_argument("--min-os")
    parser.add_argument("--arch")
    parser.add_argument("--executable", type=Path, action="append")
    parser.add_argument("--include", action="append")
    parser.add_argument("--inventory", type=Path)
    arguments = parser.parse_args()
    if not arguments.root.is_dir():
        print(f"error: {arguments.root} is not a directory", file=sys.stderr)
        return 2
    try:
        inventory, errors = verify(arguments.root, arguments.min_os, arguments.arch, arguments.executable, arguments.include)
    except RuntimeError as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 2
    if arguments.inventory:
        arguments.inventory.parent.mkdir(parents=True, exist_ok=True)
        arguments.inventory.write_text(json.dumps({"root": arguments.root.name, "binaries": inventory}, indent=2) + "\n")
    if not inventory:
        print(f"error: no Mach-O files under {arguments.root}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    if errors:
        print(f"error: {len(errors)} problems in {len(inventory)} Mach-O files under {arguments.root}", file=sys.stderr)
        return 1
    print(f"==> native closure verified: {len(inventory)} Mach-O files load only from the bundle or the system")
    return 0


if __name__ == "__main__":
    sys.exit(main())
