#!/usr/bin/env bash
#
# CloudStream macOS — the one publisher of dist.
#
#   publish_artifact.sh --app <CloudStream.app> --mode development|distribution
#                       [--dmg <CloudStream.dmg>] [--dist <dir>] [--build-id <id>]
#                       [--closure verified|not-portable] [--attach <file>]...
#
# --closure states what the build found for the native dependency closure.
# A development build may be published as not-portable (it runs on the Mac
# that built it); a distribution build must be verified.
# --attach copies inventory/provenance files (SBOM, media manifest, …) into
# the generation and lists them in BUILD_INFO.json.
#
# Takes a finished, already signed and verified app (and optionally its DMG),
# copies it into a private staging directory, verifies the copy, moves it to
# dist/generations/<buildID> and then atomically points
# dist/current at it. The stable names keep working through `current`:
#
#   dist/CloudStream.app  -> current/CloudStream.app
#   dist/CloudStream.dmg  -> current/CloudStream.dmg   (when a DMG exists)
#   dist/BUILD_INFO.json  -> current/BUILD_INFO.json
#
# Nothing unverified ever appears under those names, a failed run leaves the
# previous generation in place, and two publishers cannot interleave: the
# short publish step takes a lock (builds themselves are not locked).
#
# Prints `generation=<absolute path>` on success so callers consume exactly
# the generation they published.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP=""
DMG=""
MODE=""
DIST="${CS_DIST_DIR:-$REPO_ROOT/dist}"
BUILD_ID=""
CLOSURE="unchecked"
ATTACHMENTS=()
KEEP="${CS_DIST_KEEP_GENERATIONS:-3}"
LOCK_TIMEOUT="${CS_PUBLISH_LOCK_TIMEOUT:-120}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="${2:?}"; shift 2 ;;
        --dmg) DMG="${2:?}"; shift 2 ;;
        --mode) MODE="${2:?}"; shift 2 ;;
        --dist) DIST="${2:?}"; shift 2 ;;
        --build-id) BUILD_ID="${2:?}"; shift 2 ;;
        --closure) CLOSURE="${2:?}"; shift 2 ;;
        --attach) ATTACHMENTS+=("${2:?}"); shift 2 ;;
        *) echo "usage: $0 --app <App.app> --mode development|distribution [--dmg <file>] [--dist <dir>] [--build-id <id>]" >&2; exit 2 ;;
    esac
done
[[ "$MODE" == "development" || "$MODE" == "distribution" ]] || { echo "error: --mode must be development or distribution" >&2; exit 2; }
[[ -d "$APP" && -f "$APP/Contents/Info.plist" ]] || { echo "error: no app bundle at '$APP'" >&2; exit 1; }
[[ -z "$DMG" || -f "$DMG" ]] || { echo "error: no DMG at '$DMG'" >&2; exit 1; }
if [[ -z "$BUILD_ID" ]]; then
    BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)-$$"
fi
[[ "$BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: invalid build id" >&2; exit 2; }

APP_NAME="$(basename "$APP")"
EXECUTABLE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[[ -x "$EXECUTABLE" ]] || { echo "error: the app has no executable" >&2; exit 1; }

# --- 1. The input must already be a finished artifact ------------------------
verify_app() { # verify_app <bundle>
    codesign --verify --deep --strict "$1" 2>&1 || { echo "error: the signature of $1 does not verify" >&2; return 1; }
    if [[ "$MODE" == "distribution" ]]; then
        local details
        details="$(codesign -dvv "$1" 2>&1)"
        grep -q "Authority=Developer ID Application" <<<"$details" || { echo "error: distribution needs a Developer ID signature" >&2; return 1; }
        grep -q "flags=.*runtime" <<<"$details" || { echo "error: distribution needs the Hardened Runtime" >&2; return 1; }
    fi
}
[[ "$CLOSURE" == "verified" || "$CLOSURE" == "not-portable" || "$CLOSURE" == "unchecked" ]] || { echo "error: invalid --closure" >&2; exit 2; }
if [[ "$MODE" == "distribution" && "$CLOSURE" != "verified" ]]; then
    echo "error: distribution needs a verified native closure" >&2; exit 1
fi
verify_app "$APP"
if [[ "$MODE" == "distribution" ]]; then
    [[ -n "$DMG" ]] || { echo "error: distribution publishes a notarized DMG" >&2; exit 1; }
    xcrun stapler validate "$DMG" > /dev/null 2>&1 || { echo "error: the DMG has no valid notarization ticket" >&2; exit 1; }
fi

mkdir -p "$DIST/generations"
STAGING="$DIST/generations/.staging-$BUILD_ID"
LOCK="$DIST/.publish.lock"
have_lock=0
cleanup() {
    rm -rf "$STAGING"
    if [[ "$have_lock" == 1 ]]; then rm -rf "$LOCK"; fi
}
trap cleanup EXIT

# --- 2. Stage and verify a private copy --------------------------------------
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME"
verify_app "$STAGING/$APP_NAME"
if [[ -n "$DMG" ]]; then cp -p "$DMG" "$STAGING/CloudStream.dmg"; fi
if [[ -f "$APP/../native-inventory.json" ]]; then cp -p "$APP/../native-inventory.json" "$STAGING/native-inventory.json"; fi
mkdir -p "$STAGING/provenance"
for attachment in ${ATTACHMENTS[@]+"${ATTACHMENTS[@]}"}; do
    [[ -f "$attachment" ]] || { echo "error: no file to attach at '$attachment'" >&2; exit 1; }
    cp -p "$attachment" "$STAGING/provenance/$(basename "$attachment")"
done

/usr/bin/python3 - "$STAGING" "$APP_NAME" "$MODE" "$BUILD_ID" "$REPO_ROOT" "$CLOSURE" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys, datetime
stage, app_name, mode, build_id, repo, closure = sys.argv[1:7]
stage = pathlib.Path(stage)
contents = stage / app_name / "Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()
def tree(path):
    # One digest for a directory: its relative names and file digests, sorted.
    digest = hashlib.sha256()
    for item in sorted(p for p in path.rglob("*") if p.is_file() and not p.is_symlink()):
        digest.update(str(item.relative_to(path)).encode() + b"\0" + sha(item).encode() + b"\n")
    return digest.hexdigest()
def git(*args):
    result = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None
def optional(path, fn):
    return fn(path) if path.exists() else None
resources = contents / "Resources"
signature = subprocess.run(["codesign", "-dvv", str(stage / app_name)], capture_output=True, text=True).stderr
authority = next((line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("Authority=")), None)
manifest = {
    "appName": info.get("CFBundleDisplayName") or info.get("CFBundleName"),
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "buildID": build_id,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "gitCommit": git("rev-parse", "HEAD"),
    "gitDirty": bool(git("status", "--porcelain")),
    "architecture": subprocess.run(["lipo", "-archs", str(contents / "MacOS" / info["CFBundleExecutable"])],
                                   capture_output=True, text=True).stdout.split(),
    "minimumOS": info.get("LSMinimumSystemVersion"),
    "signingMode": mode,
    "nativeClosure": closure,
    "signingAuthority": authority or "ad-hoc",
    "hashes": {
        "executable": sha(contents / "MacOS" / info["CFBundleExecutable"]),
        "daemonJar": optional(resources / "tools" / "daemon.jar", sha),
        "runtimeModules": optional(resources / "runtime" / "lib" / "modules", sha),
        "frameworks": optional(contents / "Frameworks", tree),
        "mediaBinaries": optional(resources / "Binaries", tree),
        "dmg": optional(stage / "CloudStream.dmg", sha),
    },
    "nativeInventory": "native-inventory.json" if (stage / "native-inventory.json").exists() else None,
    "provenance": {item.name: sha(item) for item in sorted((stage / "provenance").iterdir())},
}
(stage / "BUILD_INFO.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY

# --- 3. Publish under the lock -----------------------------------------------
waited=0
until mkdir "$LOCK" 2>/dev/null; do
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
        rm -rf "$LOCK"   # the publisher that held it is gone
        continue
    fi
    (( waited >= LOCK_TIMEOUT )) && { echo "error: another publisher holds $LOCK" >&2; exit 1; }
    sleep 1; waited=$((waited + 1))
done
have_lock=1
echo $$ > "$LOCK/pid"

GENERATION="$DIST/generations/$BUILD_ID"
[[ ! -e "$GENERATION" ]] || { echo "error: generation $BUILD_ID already exists" >&2; exit 1; }
mv "$STAGING" "$GENERATION"

/usr/bin/python3 - "$DIST" "$BUILD_ID" "$APP_NAME" "$KEEP" <<'PY'
import os, pathlib, shutil, sys, time
dist, build_id, app_name, keep = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
generation = dist / "generations" / build_id

def point(link: pathlib.Path, target: str):
    """Atomically make `link` a symlink to `target` (rename over the old one)."""
    temporary = link.with_name(f".{link.name}.{os.getpid()}")
    if temporary.is_symlink() or temporary.exists():
        temporary.unlink()
    os.symlink(target, temporary)
    os.replace(temporary, link)

# A real directory/file from the older, non-atomic publishers is kept as a
# generation of its own, never deleted, before the stable name becomes a link.
legacy = dist / "generations" / f"legacy-{time.strftime('%Y%m%dT%H%M%S')}"
for name in (app_name, "CloudStream.dmg", "BUILD_INFO.json"):
    path = dist / name
    if path.exists() and not path.is_symlink():
        legacy.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(legacy / name))

point(dist / "current", f"generations/{build_id}")       # the single switch
point(dist / app_name, f"current/{app_name}")
point(dist / "BUILD_INFO.json", "current/BUILD_INFO.json")
dmg = dist / "CloudStream.dmg"
if (generation / "CloudStream.dmg").exists():
    point(dmg, "current/CloudStream.dmg")
elif dmg.is_symlink():
    dmg.unlink()        # this generation has no DMG; do not offer a stale one

# Keep the newest generations; the one just published is always among them.
published = sorted((p for p in (dist / "generations").iterdir() if p.is_dir() and not p.name.startswith((".", "legacy-"))),
                   key=lambda p: p.stat().st_mtime, reverse=True)
for old in published[max(keep, 1):]:
    if old.resolve() != generation.resolve():
        shutil.rmtree(old, ignore_errors=True)
PY

echo "==> Published $MODE build $BUILD_ID"
echo "generation=$GENERATION"
