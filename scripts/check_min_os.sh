#!/bin/bash
# Fails when any Mach-O requires a newer macOS than the app supports. Such a
# binary can reference symbols that don't exist on older systems, so the app
# would fail to launch on the older systems it claims to support.
#
# usage: check_min_os.sh <App.app>                  (limit = LSMinimumSystemVersion)
#        check_min_os.sh --min <version> <path>...  (files or directories)
set -euo pipefail

if [ "${1:-}" = "--min" ]; then
    TARGET="${2:?usage: check_min_os.sh --min <version> <path>...}"
    shift 2
    [ $# -gt 0 ] || { echo "usage: check_min_os.sh --min <version> <path>..." >&2; exit 2; }
    ROOTS=("$@")
    STRIP=""
else
    APP="${1:?usage: check_min_os.sh <App.app>}"
    TARGET=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
    ROOTS=("$APP/Contents")
    STRIP="$APP/"
fi

newer() { # true when version $1 > version $2
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

bad=0
checked=0
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q "Mach-O" || continue
    checked=$((checked + 1))
    minos=$(otool -l "$file" | awk '
        /LC_BUILD_VERSION/      { mode = "build" }
        /LC_VERSION_MIN_MACOSX/ { mode = "legacy" }
        mode == "build"  && $1 == "minos"   { print $2; exit }
        mode == "legacy" && $1 == "version" { print $2; exit }')
    [ -z "$minos" ] && continue
    if newer "$minos" "$TARGET"; then
        echo "  requires macOS $minos: ${file#"$STRIP"}" >&2
        bad=$((bad + 1))
    fi
done < <(find "${ROOTS[@]}" -type f -print0)

if [ "$bad" -gt 0 ]; then
    echo "error: $bad of $checked binaries need a newer macOS than the app's minimum ($TARGET)." >&2
    echo "Rebuild them with MACOSX_DEPLOYMENT_TARGET=$TARGET (scripts/build_media_stack.sh), or raise the app's deployment target." >&2
    exit 1
fi
echo "==> minimum macOS check passed ($checked binaries run on $TARGET)"
