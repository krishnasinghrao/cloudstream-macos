#!/usr/bin/env bash
#
# Deep cleanup script for CloudStream macOS.
# Purges stale build intermediates, DerivedData caches, duplicate binaries,
# and cleans temporary files to guarantee a 100% clean baseline.
#
# Kept: client/build/media-stack and client/build/vendor-jdk. They are the
# toolchain inputs (a from-source media build and the checksum-pinned JDK),
# not build outputs, and take long to recreate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Cleaning CloudStream macOS build artifacts & caches..."

# 1. Purge client build intermediates & DerivedData (preserving toolchain inputs)
if [[ -d "$REPO_ROOT/client/build" ]]; then
    echo "    Removing client/build intermediates (preserving media-stack, vendor-jdk)..."
    find "$REPO_ROOT/client/build" -mindepth 1 -maxdepth 1 ! -name "media-stack" ! -name "vendor-jdk" -exec rm -rf {} +
fi

# 2. Purge staged engine artifacts from the client resources
rm -rf "$REPO_ROOT/client/Resources/runtime" "$REPO_ROOT/client/Resources/tools"

# 3. Clean the Gradle builds (engine and library)
if [[ -f "$REPO_ROOT/gradlew" ]]; then
    echo "    Running gradle clean..."
    ( cd "$REPO_ROOT" && ./gradlew clean --console=plain -q 2>/dev/null || true )
fi
rm -rf "$REPO_ROOT/engine/build" "$REPO_ROOT/library/build" "$REPO_ROOT/build"

# 4. Purge Xcode global DerivedData for CloudStreamMac
XCODE_DD="$HOME/Library/Developer/Xcode/DerivedData"
if compgen -G "$XCODE_DD/CloudStreamMac-*" > /dev/null; then
    echo "    Purging stale Xcode global DerivedData for CloudStreamMac..."
    rm -rf "$XCODE_DD"/CloudStreamMac-*
fi

# 5. Remove lingering .DS_Store files and Python caches
find "$REPO_ROOT" -name ".DS_Store" -not -path "*/.git/*" -delete 2>/dev/null || true
find "$REPO_ROOT/scripts" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true

# 6. Purge dist/ if requested via --all
if [[ "${1:-}" == "--all" ]]; then
    if [[ -d "$REPO_ROOT/dist" ]]; then
        echo "    Removing dist directory..."
        rm -rf "$REPO_ROOT/dist"
    fi
fi

echo "==> Cleanup complete. Clean slate established."
