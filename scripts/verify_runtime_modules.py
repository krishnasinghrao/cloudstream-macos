#!/usr/bin/env python3
"""Check compiled host JDK references against the jlink module closure.

Host classes are inspected independently of optional third-party backends in
the fat jar; those paths are covered by bundled-runtime conformance fixtures.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def required_modules(script: Path) -> set[str]:
    match = re.search(r'^REQUIRED_MODULES="([^"]+)"', script.read_text(), re.M)
    if not match:
        raise ValueError("No runtime module declaration")
    return set(match.group(1).split(","))


def module_closure(modules: set[str], java: str) -> set[str]:
    closure: set[str] = set()
    pending = list(modules)
    while pending:
        module = pending.pop()
        if module in closure:
            continue
        closure.add(module)
        described = subprocess.check_output([java, "--describe-module", module], text=True)
        for line in described.splitlines():
            fields = line.split()
            if fields and fields[0] == "requires" and "static" not in fields:
                pending.append(fields[1])
    return closure


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--classes", type=Path, required=True)
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("--jdk", type=Path)
    args = parser.parse_args()
    if not args.classes.is_dir() or not next(args.classes.rglob("*.class"), None):
        parser.error("Compiled host classes are missing; run the daemon build first")
    java = str(args.jdk / "bin/java") if args.jdk else shutil.which("java")
    jdeps = str(args.jdk / "bin/jdeps") if args.jdk else shutil.which("jdeps")
    if not java or not jdeps:
        parser.error("JDK java and jdeps are required")
    output = subprocess.check_output(
        [jdeps, "--multi-release", "17", "--ignore-missing-deps", "--print-module-deps", str(args.classes)],
        text=True,
    ).strip()
    dependencies = set(output.split(","))
    missing = dependencies - module_closure(required_modules(args.script), java)
    if missing:
        parser.error("Host classes require absent runtime modules: " + ", ".join(sorted(missing)))
    print("Host runtime module references verified: " + ", ".join(sorted(dependencies)))


if __name__ == "__main__":
    main()
