#!/usr/bin/env bash
#
# CloudStream macOS — fetch the self-contained JDK the app's runtime is
# linked from (Eclipse Temurin 17, Apple Silicon).
#
# Why: bundle_runtime.sh jlinks the engine's Java runtime from a JDK. With
# Homebrew's OpenJDK, that runtime loads libraries from /opt/homebrew and
# runs only on a Mac with the same Homebrew install ("native closure:
# not-portable"). Temurin's JDK is self-contained and notarized, so a runtime
# linked from it runs on every supported Mac. CI uses Temurin too
# (actions/setup-java); this gives local release builds the same JDK.
#
# Usage:   ./scripts/fetch_vendor_jdk.sh        (make build runs it if needed)
# Output:  client/build/vendor-jdk/<release>/ and vendor-jdk/java-home.txt,
#          which bundle_runtime.sh reads. scripts/clean.sh keeps this folder.
#
# Updating: take the release name, file name and SHA-256 from
#   https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=aarch64&image_type=jdk&os=mac&vendor=eclipse
# and change the three pins below together.
set -euo pipefail

RELEASE="jdk-17.0.21+9"
ARCHIVE="OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.21_9.tar.gz"
SHA256="78b08c7f5a0598242d5719c022e19479cb4a3aa45c37c19726a757a469ed1c15"
URL="https://github.com/adoptium/temurin17-binaries/releases/download/${RELEASE//+/%2B}/$ARCHIVE"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/client/build/vendor-jdk"
POINTER="$VENDOR_DIR/java-home.txt"
HOME_DIR="$VENDOR_DIR/$RELEASE/Contents/Home"

verify_home() {
    [[ -x "$1/bin/jlink" ]] || return 1
    codesign --verify --strict "$1/bin/java" 2>/dev/null || return 1
    [[ "$("$1/bin/java" -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.vendor =/ {print $2}')" == "Eclipse Adoptium" ]]
}

if [[ -f "$POINTER" ]] && [[ "$(head -1 "$POINTER")" == "$HOME_DIR" ]] && verify_home "$HOME_DIR"; then
    echo "==> Vendor JDK: $RELEASE (already present)"
    exit 0
fi

echo "==> Fetching vendor JDK $RELEASE (~186 MB) from Adoptium"
mkdir -p "$VENDOR_DIR"
work="$(mktemp -d "$VENDOR_DIR/.fetch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --retry 3 --output "$work/$ARCHIVE" "$URL"

actual="$(shasum -a 256 "$work/$ARCHIVE" | awk '{print $1}')"
if [[ "$actual" != "$SHA256" ]]; then
    echo "error: $ARCHIVE checksum mismatch (expected $SHA256, got $actual)" >&2
    exit 1
fi

mkdir -p "$work/unpacked"
tar -xzf "$work/$ARCHIVE" -C "$work/unpacked"
[[ -d "$work/unpacked/$RELEASE/Contents/Home" ]] || { echo "error: unexpected archive layout" >&2; exit 1; }
verify_home "$work/unpacked/$RELEASE/Contents/Home" || {
    echo "error: the unpacked JDK failed its signature or vendor check" >&2
    exit 1
}

rm -rf "$VENDOR_DIR/$RELEASE"
mv "$work/unpacked/$RELEASE" "$VENDOR_DIR/$RELEASE"
# Older releases are no longer referenced once the pointer moves.
find "$VENDOR_DIR" -mindepth 1 -maxdepth 1 -type d -name 'jdk-*' ! -name "$RELEASE" -exec rm -rf {} +
printf '%s\n' "$HOME_DIR" > "$POINTER"
echo "    $HOME_DIR"
