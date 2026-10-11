#!/usr/bin/env bash
#
# CloudStream macOS — release packaging (plan WS-6, audit A41–A43).
#
#   package_app.sh                  development DMG: ad-hoc signed, not notarized
#   package_app.sh --distribution   signed with Developer ID, notarized, stapled
#
# Pipeline: daemon fat jar -> jlink runtime(s) + AppCDS -> verified media
# closure -> Xcode Release archive -> private candidate -> nested signing ->
# verification (signatures, native closure, minimum macOS, entry points) ->
# DMG of that exact candidate -> notarization and stapling (distribution) ->
# one publication into dist through publish_artifact.sh.
#
# The two modes are explicit. Distribution fails before building anything if
# the signing identity or the notarization credentials cannot be used; it
# never falls back to an unsigned artifact. Nothing is written to dist
# until the candidate has passed every check, and a failed run leaves the
# previously published generation in place.
#
# Distribution environment:
#   CS_SIGNING_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   CS_KEYCHAIN_PROFILE   notarytool keychain profile name
#   CS_SIGNING_KEYCHAIN   optional keychain holding the identity (CI)
#
# Prints `generation=<path>`, `dmg=<path>` for callers (CI uploads that DMG).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT_DIR="$REPO_ROOT/client"
APP_NAME="CloudStream"
BUILD_DIR="$CLIENT_DIR/build/Release"
MODE="development"
for argument in "$@"; do
    case "$argument" in
        --distribution) MODE="distribution" ;;
        --development) MODE="development" ;;
        *) echo "usage: $0 [--development|--distribution]" >&2; exit 2 ;;
    esac
done
[[ "${CS_DISTRIBUTION:-0}" == "1" ]] && MODE="distribution"
SIGN_IDENTITY="${CS_SIGNING_IDENTITY:-}"
KEYCHAIN_PROFILE="${CS_KEYCHAIN_PROFILE:-}"

step() { echo "==> $1"; }
# shellcheck source=lib_artifact.sh
source "$REPO_ROOT/scripts/lib_artifact.sh"

# --- 0. Distribution prerequisites, before any work ---------------------------
if [[ "$MODE" == "distribution" ]]; then
    step "Checking signing and notarization credentials"
    [[ -n "$SIGN_IDENTITY" ]] || { echo "error: distribution needs CS_SIGNING_IDENTITY" >&2; exit 1; }
    [[ -n "$KEYCHAIN_PROFILE" ]] || { echo "error: distribution needs CS_KEYCHAIN_PROFILE" >&2; exit 1; }
    identities="$(security find-identity -v -p codesigning ${CS_SIGNING_KEYCHAIN:+"$CS_SIGNING_KEYCHAIN"} 2>/dev/null || true)"
    grep -qF "$SIGN_IDENTITY" <<<"$identities" || { echo "error: signing identity not found in the keychain: $SIGN_IDENTITY" >&2; exit 1; }
    # Setting a profile name is not enough: it must authenticate.
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" > /dev/null 2>&1 \
        || { echo "error: notarytool cannot use keychain profile '$KEYCHAIN_PROFILE'" >&2; exit 1; }
    export CS_DISTRIBUTION=1
    IDENTITY="$SIGN_IDENTITY"
else
    echo "==> Development packaging: ad-hoc signature, no notarization. Use --distribution for a release."
    IDENTITY="-"
fi

# --- 1. Daemon jar, runtime, media ----------------------------------------------
step "Building daemon fat jar (:engine:jar)"
# A release jar is compiled from clean: two clean builds of the same sources
# are byte-identical, an incrementally compiled one is not (measured; see
# docs/Dependency-Review.md).
if [[ "$MODE" == "distribution" ]]; then
    ( cd "$REPO_ROOT" && ./gradlew :engine:clean --console=plain -q )
fi
( cd "$REPO_ROOT" && ./gradlew :engine:jar :engine:sbom --console=plain -q )

step "Bundling minimal runtime (jlink + AppCDS)"
"$REPO_ROOT/scripts/bundle_runtime.sh" "$REPO_ROOT/engine/build/libs/daemon.jar"

step "Preparing media binaries"
prepare_media "$MODE"

# --- 2. Xcode Release archive ---------------------------------------------------
step "Generating Xcode project (xcodegen)"
( cd "$CLIENT_DIR" && xcodegen generate )

step "Building Xcode Release archive"
BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}-$BUILD_ID.xcarchive"
mkdir -p "$BUILD_DIR/logs"
"$REPO_ROOT/scripts/run_logged.sh" "$BUILD_DIR/logs/archive-$BUILD_ID.log" \
    xcodebuild -project "$CLIENT_DIR/CloudStreamMac.xcodeproj" \
    -scheme CloudStreamMac \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    archive -archivePath "$ARCHIVE_PATH" CS_ENGINE_PREPARED=1 > /dev/null
[[ -d "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" ]] || { echo "error: the archive has no app" >&2; exit 1; }

# --- 3. Private candidate ---------------------------------------------------------
# Everything below works on this copy. The archive is not modified and
# dist is not touched until the end.
CANDIDATE_DIR="$BUILD_DIR/candidate-$BUILD_ID"
rm -rf "$CANDIDATE_DIR"
mkdir -p "$CANDIDATE_DIR/dmg-root"
cleanup() { rm -rf "$CANDIDATE_DIR" "$ARCHIVE_PATH"; }
trap cleanup EXIT
APP="$CANDIDATE_DIR/dmg-root/${APP_NAME}.app"
ditto "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$APP"

# Load-command edits come first; nothing changes the bundle after signing.
step "Staging frameworks"
bash "$REPO_ROOT/scripts/stage_frameworks.sh" "$APP/Contents"
step "Recording the engine's class archive"
record_archive "$APP"

step "Signing ($MODE)"
sign_bundle "$APP" "$IDENTITY"

step "Verifying the candidate"
verify_bundle "$APP" "$MODE"
selftest_bundle "$APP"
if ! "$REPO_ROOT/scripts/check_min_os.sh" "$APP"; then
    if [[ "$MODE" == "development" && "${CS_ALLOW_MIN_OS_MISMATCH:-0}" == "1" ]]; then
        echo "==> WARNING: continuing despite a minimum-macOS mismatch (CS_ALLOW_MIN_OS_MISMATCH=1) — do not distribute this DMG"
    else
        exit 1
    fi
fi
# native-inventory.json sits beside the app during verification; it is not
# part of the disk image.
mv "$CANDIDATE_DIR/dmg-root/native-inventory.json" "$CANDIDATE_DIR/native-inventory.json" 2>/dev/null || true

# --- 4. DMG of the verified candidate -------------------------------------------
step "Creating DMG"
DMG_PATH="$CANDIDATE_DIR/${APP_NAME}.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$CANDIDATE_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" > /dev/null

# --- 5. Notarization (distribution) ---------------------------------------------
if [[ "$MODE" == "distribution" ]]; then
    step "Signing and notarizing the DMG (uploads to Apple; may take minutes)"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait \
        | tee "$BUILD_DIR/logs/notary-$BUILD_ID.log"
    grep -q "status: Accepted" "$BUILD_DIR/logs/notary-$BUILD_ID.log" || { echo "error: notarization was not accepted" >&2; exit 1; }
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature "$DMG_PATH"
fi

# --- 6. Publish once --------------------------------------------------------------
step "Publishing to dist"
# The publisher looks for the inventory beside the app.
cp "$CANDIDATE_DIR/native-inventory.json" "$CANDIDATE_DIR/dmg-root/native-inventory.json" 2>/dev/null || true
ATTACH=()
while IFS= read -r line; do ATTACH+=("$line"); done < <(provenance_arguments "$APP")
PUBLISHED="$("$REPO_ROOT/scripts/publish_artifact.sh" --app "$APP" --dmg "$DMG_PATH" --mode "$MODE" \
    --closure "$NATIVE_CLOSURE" --build-id "$BUILD_ID" ${ATTACH[@]+"${ATTACH[@]}"})"
GENERATION="$(sed -n 's/^generation=//p' <<<"$PUBLISHED")"
[[ -f "$GENERATION/${APP_NAME}.dmg" ]] || { echo "error: the publisher did not report a generation with a DMG" >&2; exit 1; }

echo
echo "Published $MODE artifact: $GENERATION/${APP_NAME}.dmg ($(du -h "$GENERATION/${APP_NAME}.dmg" | cut -f1))"
echo "Budget check (Rules.md §3: <180 MB uncompressed / <95 MB DMG):"
du -sh "$GENERATION/${APP_NAME}.app" 2>/dev/null || true
du -sh "$GENERATION/${APP_NAME}.app/Contents/Resources/runtime" "$GENERATION/${APP_NAME}.app/Contents/Resources/Binaries" \
    "$GENERATION/${APP_NAME}.app/Contents/Resources/tools" 2>/dev/null || true
echo "generation=$GENERATION"
echo "dmg=$GENERATION/${APP_NAME}.dmg"
