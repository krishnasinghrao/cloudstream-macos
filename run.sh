#!/usr/bin/env bash
#
# Launches the clean, authoritative CloudStream macOS application.
# If no build exists in dist, it triggers a clean build first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_APP="$SCRIPT_DIR/dist/CloudStream.app"

if [[ ! -d "$DIST_APP" ]]; then
    echo "==> No active build found at dist/CloudStream.app."
    echo "==> Triggering build..."
    "$SCRIPT_DIR/scripts/build_dev.sh"
fi

echo "==> Launching $DIST_APP"
open "$DIST_APP"
