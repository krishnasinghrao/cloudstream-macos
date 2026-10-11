#!/usr/bin/env bash
#
# CloudStream macOS — minimal JRE assembly (Roadmap Phase 5, Task 1).
#
# Assembles a stripped OpenJDK runtime via jlink into the client resources and
# the base Class-Data Sharing archive (the daemon's own archive is recorded in
# the finished app by lib_artifact.sh record_archive).
#
# Usage: ./bundle_runtime.sh [path-to-daemon.jar]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_JAR="${1:-$REPO_ROOT/engine/build/libs/daemon.jar}"
OUTPUT_DIR="${CS_RUNTIME_OUTPUT_DIR:-$REPO_ROOT/client/Resources/runtime}"

# A self-contained vendor JDK (Temurin) unpacked into client/build/vendor-jdk
# is preferred over the system JDK: Homebrew's links /opt/homebrew libraries,
# so its runtime runs only on a Mac with the same Homebrew install.
VENDOR_JDK_POINTER="$REPO_ROOT/client/build/vendor-jdk/java-home.txt"
VENDOR_JDK=""
if [[ -f "$VENDOR_JDK_POINTER" ]]; then
    VENDOR_JDK="$(head -1 "$VENDOR_JDK_POINTER")"
    [[ -x "$VENDOR_JDK/bin/jlink" ]] && codesign --verify --strict "$VENDOR_JDK/bin/java" 2>/dev/null || VENDOR_JDK=""
fi
JDK_DIR="${CS_RUNTIME_JDK:-${VENDOR_JDK:-${JAVA_HOME:-$(/usr/libexec/java_home -v 17 2>/dev/null)}}}"
echo "==> JDK: $JDK_DIR"
JLINK="$JDK_DIR/bin/jlink"
if [[ ! -x "$JLINK" ]]; then
    echo "error: JDK 17 with jlink not found (set JAVA_HOME to a JDK 17+)" >&2
    exit 1
fi

# jdk.zipfs: dex2jar writes translated extensions through the zip filesystem.
# jdk.charsets: providers decode pages in legacy (non-UTF) encodings.
# Management modules preserve SystemClock CPU time and ActivityManager memory APIs.
# jdk.incubator.foreign: F_FULLFSYNC for durable commits (engine FullFsync.java).
REQUIRED_MODULES="java.base,java.logging,java.naming,java.net.http,java.sql,java.xml,java.desktop,jdk.unsupported,jdk.crypto.ec,jdk.zipfs,jdk.charsets,java.management,jdk.management,jdk.incubator.foreign"

echo "==> Assembling minimal OpenJDK runtime (~35 MB) via jlink"
rm -rf "$OUTPUT_DIR"
"$JLINK" \
    --add-modules "$REQUIRED_MODULES" \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --compress=2 \
    --output "$OUTPUT_DIR"

JAVA_BIN="$OUTPUT_DIR/bin/java"

# The image must be what the app expects: JDK 17 for this machine's
# architecture. A runtime of another architecture would only fail at launch.
RUNTIME_ARCH="$(uname -m)"
lipo -archs "$JAVA_BIN" | tr ' ' '\n' | grep -qx "$RUNTIME_ARCH" || { echo "error: bundled java is not $RUNTIME_ARCH" >&2; exit 1; }
"$JAVA_BIN" -version 2>&1 | head -1 | grep -q '"17\.' || { echo "error: bundled runtime is not Java 17: $("$JAVA_BIN" -version 2>&1 | head -1)" >&2; exit 1; }

# Native closure: a JDK built against a package manager's libraries (Homebrew
# OpenJDK links java.desktop against /opt/homebrew) produces an image that
# only runs on Macs with those libraries. That is allowed for a development
# build on this Mac and refused for a distribution build (CS_DISTRIBUTION=1).
RUNTIME_PORTABLE=true
RUNTIME_PROBLEMS="$(mktemp "${TMPDIR:-/tmp}/cloudstream-runtime-closure.XXXXXX")"
if ! python3 "$REPO_ROOT/scripts/verify_macho_closure.py" "$OUTPUT_DIR" --arch "$RUNTIME_ARCH" > /dev/null 2> "$RUNTIME_PROBLEMS"; then
    RUNTIME_PORTABLE=false
    if [[ "${CS_DISTRIBUTION:-0}" == "1" ]]; then
        cat "$RUNTIME_PROBLEMS" >&2
        echo "error: the JDK at $JDK_DIR is not self-contained; use a vendor JDK 17 (for example Temurin) for distribution builds" >&2
        rm -f "$RUNTIME_PROBLEMS"
        exit 1
    fi
    echo "    warning: this runtime loads libraries from outside the app and will only run on this Mac:" >&2
    sed 's/^/      /' "$RUNTIME_PROBLEMS" | head -12 >&2
fi

# Gate: every required module is present, and the real extension translation
# path works on this runtime (a missing module otherwise fails only at install).
for module in ${REQUIRED_MODULES//,/ }; do
    "$JAVA_BIN" --list-modules | grep -q "^$module@" || { echo "error: runtime is missing $module" >&2; exit 1; }
done
if [[ -f "$DAEMON_JAR" ]]; then
    echo "==> Extension translation self-test on the bundled runtime"
    "$JAVA_BIN" -jar "$DAEMON_JAR" --self-test || { echo "error: extension self-test failed on the bundled runtime" >&2; exit 1; }
fi

# Staging destination — DaemonSupervisor loads tools/daemon.jar + tools/daemon.jsa.
TOOLS_DIR="${CS_RUNTIME_TOOLS_DIR:-$REPO_ROOT/client/Resources/tools}"

# Application CDS: only the base archive is generated here. The daemon's own
# archive is recorded later, against the jar inside the finished app
# (lib_artifact.sh record_archive): JDK 17 rejects an archive whose jar path or
# modification time differs, and Xcode's resource copy changes both.
if [[ ! -f "$OUTPUT_DIR/lib/server/classes.jsa" ]]; then
    echo "==> Generating base CDS archive (java -Xshare:dump)"
    "$JAVA_BIN" -Xshare:dump > /dev/null 2>&1 || echo "    warning: base CDS dump failed (non-fatal)"
fi

# Stage the daemon jar into the client bundle layout.
if [[ -f "$DAEMON_JAR" ]]; then
    mkdir -p "$TOOLS_DIR"
    rm -f "$TOOLS_DIR/daemon.jsa" "$TOOLS_DIR/daemon.cds.json"
    if ! cmp -s "$DAEMON_JAR" "$TOOLS_DIR/daemon.jar"; then
        cp "$DAEMON_JAR" "$TOOLS_DIR/daemon.jar"
    fi
    echo "==> Staged daemon artifacts into $TOOLS_DIR"
else
    echo "==> daemon.jar not found at $DAEMON_JAR (build it with :engine:jar)"
fi

# Software bill of materials (plan T8.4): the daemon's dependency SBOM plus the
# bundled runtime, shipped inside the app as tools/sbom.cdx.json.
DAEMON_SBOM="$(dirname "$DAEMON_JAR")/../sbom/daemon.cdx.json"
if [[ -f "$DAEMON_SBOM" && -f "$OUTPUT_DIR/release" ]]; then
    python3 - "$DAEMON_SBOM" "$OUTPUT_DIR" "$TOOLS_DIR/sbom.cdx.json" <<'PY'
import hashlib, json, pathlib, sys
sbom = json.loads(pathlib.Path(sys.argv[1]).read_text())
runtime = pathlib.Path(sys.argv[2])
release = dict(line.split("=", 1) for line in (runtime / "release").read_text().splitlines() if "=" in line)
version = release.get("JAVA_VERSION", "unknown").strip('"')
vendor = release.get("IMPLEMENTOR", "unknown").strip('"')
modules = hashlib.sha256((runtime / "lib" / "modules").read_bytes()).hexdigest()
sbom["components"].append({"type": "platform", "group": vendor, "name": "openjdk-runtime", "version": version,
    "purl": f"pkg:generic/openjdk-runtime@{version}", "bom-ref": "openjdk-runtime",
    "description": "jlink image; modules: " + release.get("MODULES", "").strip('"'),
    "hashes": [{"alg": "SHA-256", "content": modules}]})
pathlib.Path(sys.argv[3]).write_text(json.dumps(sbom, indent=2) + "\n")
print(f"==> SBOM: {len(sbom['components'])} components -> {sys.argv[3]}")
PY
else
    echo "==> SBOM skipped (run :engine:sbom first)"
fi

# Where this runtime came from, next to the SBOM (never inside the image, so
# the CDS/module hashes are unaffected).
mkdir -p "$TOOLS_DIR"
python3 - "$OUTPUT_DIR" "$JDK_DIR" "$REQUIRED_MODULES" "$RUNTIME_PORTABLE" "$RUNTIME_PROBLEMS" "$TOOLS_DIR/runtime-provenance.json" <<'PY'
import hashlib, json, pathlib, sys
runtime, jdk, modules, portable, problems, output = sys.argv[1:7]
runtime = pathlib.Path(runtime)
release = dict(line.split("=", 1) for line in (runtime / "release").read_text().splitlines() if "=" in line)
source = dict(line.split("=", 1) for line in (pathlib.Path(jdk) / "release").read_text().splitlines() if "=" in line) \
    if (pathlib.Path(jdk) / "release").exists() else {}
clean = lambda value: value.strip().strip('"') if value else None
pathlib.Path(output).write_text(json.dumps({
    "jdkHome": jdk,
    "implementor": clean(source.get("IMPLEMENTOR") or release.get("IMPLEMENTOR")),
    "javaVersion": clean(release.get("JAVA_VERSION")),
    "javaRuntimeVersion": clean(source.get("JAVA_RUNTIME_VERSION")),
    "source": clean(source.get("SOURCE")),
    "requestedModules": modules.split(","),
    "imageModules": clean(release.get("MODULES")),
    "modulesSha256": hashlib.sha256((runtime / "lib" / "modules").read_bytes()).hexdigest(),
    "selfContained": portable == "true",
    "closureProblems": [line.strip() for line in pathlib.Path(problems).read_text().splitlines() if line.strip()][:50],
}, indent=2) + "\n")
PY
rm -f "$RUNTIME_PROBLEMS"

echo "==> Runtime size: $(du -sh "$OUTPUT_DIR" | cut -f1)"
echo "Done. Minimal JRE bundled at $OUTPUT_DIR"
