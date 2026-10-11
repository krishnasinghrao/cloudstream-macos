#!/usr/bin/env bash
#
# CloudStream macOS — media binary dependency closure (plan WS-6.1).
#
#   bundle_media.sh [ffmpeg] [libmpv.dylib] [staging dir]
#
# The staged `ffmpeg` and `libmpv.dylib` (from build_media_stack.sh) link
# against non-system dylibs. stage_media.py resolves every dependency the way
# dyld would (absolute, @rpath, @loader_path, @executable_path), copies the
# complete closure, rewrites and signs it, verifies that nothing resolves
# outside the staged tree, runs the staged ffmpeg, and writes
# media-manifest.json. Anything unresolved, or any failed rewrite or
# signature, fails this script; nothing is skipped or reduced to a warning.
#
# Output in the staging directory:
#   Binaries/ffmpeg, Binaries/libmpv.dylib, Frameworks/*.dylib, media-manifest.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MEDIA_PREFIX="${CS_MEDIA_PREFIX:-$SCRIPT_DIR/../client/build/media-stack}"
SOURCE_FFMPEG="${1:-$MEDIA_PREFIX/bin/ffmpeg}"
SOURCE_MPV="${2:-$MEDIA_PREFIX/lib/libmpv.2.dylib}"
STAGING="${3:-$SCRIPT_DIR/../client/Resources}"

arguments=(stage "$SOURCE_FFMPEG" "$SOURCE_MPV" "$STAGING")
# Empty identity -> ad-hoc signatures; release signing happens in package_app.sh.
if [[ -n "${CS_SIGNING_IDENTITY:-}" ]]; then arguments+=(--sign "$CS_SIGNING_IDENTITY"); fi
if [[ -n "${CS_MEDIA_MIN_OS:-}" ]]; then arguments+=(--min-os "$CS_MEDIA_MIN_OS"); fi
exec /usr/bin/python3 "$SCRIPT_DIR/stage_media.py" "${arguments[@]}"
