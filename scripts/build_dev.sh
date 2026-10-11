#!/usr/bin/env bash
#
# CloudStream macOS — one-command local build (no Apple Developer account needed).
#
#   ./scripts/build_dev.sh            build Release .app
#   ./scripts/build_dev.sh --launch   build, then smoke-launch and verify the engine
#
# Requirements: full Xcode (any recent 16+/26.x) at /Applications/Xcode.app or
# selected via xcode-select. Apple Developer ID is NOT required — the app is
# ad-hoc signed for local runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/client"
LAUNCH="${1:-}"

# --- 0. Locate Xcode ---------------------------------------------------------
if [[ -d "/Applications/Xcode.app" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [[ -n "${DEVELOPER_DIR:-}" ]] || xcodebuild -version > /dev/null 2>&1; then
    : # xcode-select already points at a full Xcode
else
    echo "error: full Xcode not found at /Applications/Xcode.app and xcode-select points at CLT." >&2
    echo "       Install Xcode, open it once (license + components), then re-run." >&2
    exit 1
fi
echo "==> Using $(xcodebuild -version | head -1)"

# --- 1. Regenerate project + build engine artifacts ---------------------------
step() { echo "==> $1"; }

step "Generating Xcode project (xcodegen)"
( cd "$CLIENT_DIR" && xcodegen generate )

step "Building daemon fat jar"
( cd "$REPO_ROOT" && ./gradlew :engine:jar :engine:sbom --console=plain -q )

step "Assembling jlink runtime + AppCDS"
"$REPO_ROOT/scripts/bundle_runtime.sh" "$REPO_ROOT/engine/build/libs/daemon.jar" > /dev/null
echo "    runtime + tools staged"

step "Preparing media binaries"
# shellcheck source=lib_artifact.sh
source "$REPO_ROOT/scripts/lib_artifact.sh"
prepare_media development

# --- 2. xcodebuild --------------------------------------------------------------
# Built in DerivedData only. Nothing is copied to dist until the bundle
# is signed and verified (step 4).
step "Building app (Release, Swift 6 strict concurrency)"
mkdir -p "$CLIENT_DIR/build/logs"
"$REPO_ROOT/scripts/run_logged.sh" "$CLIENT_DIR/build/logs/build_dev.log" \
    xcodebuild -project "$CLIENT_DIR/CloudStreamMac.xcodeproj" \
    -scheme CloudStreamMac \
    -configuration Release \
    -derivedDataPath "$CLIENT_DIR/build/DerivedData" \
    build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CS_ENGINE_PREPARED=1 > /dev/null

APP_BUNDLE="$CLIENT_DIR/build/DerivedData/Build/Products/Release/CloudStream.app"
[[ -d "$APP_BUNDLE" ]] || { echo "error: app bundle missing at $APP_BUNDLE" >&2; exit 1; }

# --- 3. Private candidate: sign, then verify -------------------------------------
# A copy, so the published app is never the directory Xcode keeps rewriting.
step "Signing and verifying a private candidate (ad-hoc, development)"
CANDIDATE_DIR="$(mktemp -d "$CLIENT_DIR/build/candidate.XXXXXX")"
trap 'rm -rf "$CANDIDATE_DIR"' EXIT
APP="$CANDIDATE_DIR/CloudStream.app"
ditto "$APP_BUNDLE" "$APP"
bash "$REPO_ROOT/scripts/stage_frameworks.sh" "$APP/Contents"
record_archive "$APP"
sign_bundle "$APP" -
verify_bundle "$APP" development
selftest_bundle "$APP"

# --- 4. Publish once, after verification -----------------------------------------
step "Publishing to dist"
ATTACH=()
while IFS= read -r line; do ATTACH+=("$line"); done < <(provenance_arguments "$APP")
PUBLISHED="$("$REPO_ROOT/scripts/publish_artifact.sh" --app "$APP" --mode development --closure "$NATIVE_CLOSURE" \
    ${ATTACH[@]+"${ATTACH[@]}"})"
echo "$PUBLISHED" | sed 's/^/    /'
GENERATION="$(sed -n 's/^generation=//p' <<<"$PUBLISHED")"
FINAL_APP="$GENERATION/CloudStream.app"
[[ -d "$FINAL_APP" ]] || { echo "error: the publisher did not report a generation" >&2; exit 1; }

echo
echo "======================================================================"
echo "  Development build published"
echo "  Output: $REPO_ROOT/dist/CloudStream.app -> $FINAL_APP ($(du -sh "$FINAL_APP" | cut -f1))"
echo "  Info:   $REPO_ROOT/dist/BUILD_INFO.json (native closure: $NATIVE_CLOSURE)"
echo "  Run:    open '$REPO_ROOT/dist/CloudStream.app'   (or: make run)"
echo "======================================================================"
echo

# --- 5. Optional smoke launch -----------------------------------------------------
# An isolated launch with its own temporary root; it fails this script when
# any criterion is unmet. Without --launch no smoke check ran, and we say so.
if [[ "$LAUNCH" == "--launch" ]]; then
    step "Smoke-launching (isolated root)"
    "$REPO_ROOT/scripts/smoke_launch.sh" "$FINAL_APP"
else
    echo "smoke: not run (pass --launch to run it)"
fi
