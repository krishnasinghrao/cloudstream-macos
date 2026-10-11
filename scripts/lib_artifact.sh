#!/usr/bin/env bash
# Shared steps of build_dev.sh and package_app.sh. Source it; do not run it.
#
#   prepare_media <development|distribution>   stage or accept media binaries
#   record_archive <App.app>                    record the engine's AppCDS archive
#                                               against the jar inside this bundle
#   sign_bundle <App.app> <identity or ->       sign every nested Mach-O, app last
#   verify_bundle <App.app> <mode>              signatures, closure, minimum macOS,
#                                               entry points; sets NATIVE_CLOSURE
#   selftest_bundle <App.app>                   the bundle's own engine, archive and
#                                               flags run a fixture extension in a
#                                               sandboxed worker
#
#   provenance_arguments <App.app>              prints --attach arguments for the
#                                               publisher (SBOM, runtime and media records)
#
# Every step fails the calling script on error (callers use `set -euo pipefail`).

ARTIFACT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_CLIENT="$(cd "$ARTIFACT_SCRIPTS/../client" && pwd)"

# Media binaries are trusted only through media-manifest.json: sources that
# match it, or a restage from the sources that exist. An ffmpeg file that
# merely exists is not evidence.
prepare_media() {
    local mode="$1"
    local prefix="${CS_MEDIA_PREFIX:-$ARTIFACT_CLIENT/build/media-stack}"
    local resources="$ARTIFACT_CLIENT/Resources"
    local ffmpeg="$prefix/bin/ffmpeg" mpv="$prefix/lib/libmpv.2.dylib"

    # 1. A media stack built for the app's minimum macOS: staged from it
    #    whenever the manifest does not already match.
    if [[ -x "$ffmpeg" && -f "$mpv" ]]; then
        if /usr/bin/python3 "$ARTIFACT_SCRIPTS/stage_media.py" check "$ffmpeg" "$mpv" "$resources" 2>/dev/null; then
            echo "    media: staged closure matches its manifest (media stack)"
        else
            echo "    media: staging from the media stack"
            "$ARTIFACT_SCRIPTS/bundle_media.sh" "$ffmpeg" "$mpv" "$resources"
        fi
        return 0
    fi
    if [[ "$mode" == "distribution" ]]; then
        echo "error: no media stack at $prefix — run scripts/build_media_stack.sh first" >&2
        return 1
    fi

    # 2. Development without a media stack: keep staged binaries whose
    #    closure verifies rather than replacing them with builds for this
    #    Mac's macOS. Their origin is not recorded, and we say so.
    if [[ -x "$resources/Binaries/ffmpeg" && -f "$resources/Binaries/libmpv.dylib" ]] \
        && /usr/bin/python3 "$ARTIFACT_SCRIPTS/verify_macho_closure.py" "$resources" --include Binaries --include Frameworks \
            --executable "$resources/Binaries/ffmpeg" > /dev/null; then
        echo "    warning: using staged media binaries whose origin is not recorded (no media stack found)." >&2
        echo "             Their closure verifies; run build_media_stack.sh before distributing anything." >&2
        return 0
    fi

    # 3. Development convenience: Homebrew builds, for this macOS only.
    ffmpeg="/opt/homebrew/bin/ffmpeg"; mpv="/opt/homebrew/opt/mpv/lib/libmpv.2.dylib"
    if [[ -x "$ffmpeg" && -f "$mpv" ]]; then
        echo "    warning: no media stack — staging Homebrew mpv/ffmpeg (runs on this macOS only)." >&2
        "$ARTIFACT_SCRIPTS/bundle_media.sh" "$ffmpeg" "$mpv" "$resources"
        return 0
    fi
    echo "error: no media sources and no verifiable staged media — run scripts/build_media_stack.sh" >&2
    return 1
}

# Records the engine's AppCDS archive in the finished bundle, before signing.
# JDK 17 accepts an archive only for the class path it was recorded with and
# the jar's exact size and modification time, so it is recorded here, against
# this bundle's jar, from Contents/Resources with the jar given as
# tools/daemon.jar — the way DaemonSupervisor launches it. ditto, Finder and
# zip keep modification times, so copies of the app keep a valid archive.
record_archive() {
    local resources="$1/Contents/Resources"
    rm -f "$resources/tools/daemon.jsa" "$resources/tools/daemon.cds.json"
    /usr/bin/python3 "$ARTIFACT_SCRIPTS/record_cds.py" --required --base "$resources" \
        "$resources/runtime/bin/java" "$resources/tools/daemon.jar" "$resources/tools/daemon.jsa" \
        | sed 's/^/    /'
}

# Signs inside-out. `-` is an ad-hoc development signature; anything else is a
# Developer ID identity and also gets a timestamp. Every build gets the
# Hardened Runtime (security audit hardening note), so a development build runs
# under the same code-signing restrictions as a release. Load commands must be
# final before this runs.
sign_bundle() {
    local app="$1" identity="$2"
    local contents="$app/Contents"
    local -a options=(--force --sign "$identity" --options runtime)
    if [[ "$identity" != "-" ]]; then options+=(--timestamp); fi

    local -a nested=()
    while IFS= read -r -d '' file; do
        file -b "$file" | grep -q "Mach-O" && nested+=("$file")
    done < <(find "$contents/Frameworks" "$contents/Resources" -type f -print0 2>/dev/null)

    local file
    for file in "${nested[@]}"; do
        case "$file" in
            */bin/java)
                # java needs its own entitlements (JIT); the app's do not propagate.
                # Under the Hardened Runtime every build needs them, ad-hoc included.
                codesign "${options[@]}" --entitlements "$ARTIFACT_CLIENT/java.entitlements" "$file" ;;
            *)
                # Executables that load bundled libraries (ffmpeg, jspawnhelper).
                if [[ "$identity" == "-" ]] && file -b "$file" | grep -q "executable"; then
                    codesign "${options[@]}" --entitlements "$ARTIFACT_CLIENT/adhoc-tool.entitlements" "$file"
                else
                    codesign "${options[@]}" "$file"
                fi ;;
        esac
    done
    codesign "${options[@]}" --entitlements "$ARTIFACT_CLIENT/CloudStreamMac.entitlements" "$app"
    echo "    signed ${#nested[@]} nested binaries and the app ($([[ "$identity" == "-" ]] && echo ad-hoc || echo "$identity"))"
}

# Verifies the finished bundle. Sets NATIVE_CLOSURE to verified/not-portable
# and writes native-inventory.json beside the app.
verify_bundle() {
    local app="$1" mode="$2"
    local contents="$app/Contents"
    local minimum
    minimum="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$contents/Info.plist")"

    codesign --verify --deep --strict "$app"
    local file
    while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q "Mach-O"; then
            codesign --verify --strict "$file" || { echo "error: bad signature: $file" >&2; return 1; }
        fi
    done < <(find "$contents/Frameworks" "$contents/Resources" -type f -print0 2>/dev/null)

    NATIVE_CLOSURE="verified"
    local problems
    problems="$(mktemp "${TMPDIR:-/tmp}/cloudstream-closure.XXXXXX")"
    if ! /usr/bin/python3 "$ARTIFACT_SCRIPTS/verify_macho_closure.py" "$app" --arch arm64 --min-os "$minimum" \
            --inventory "$(dirname "$app")/native-inventory.json" 2> "$problems"; then
        if [[ "$mode" == "distribution" ]]; then
            cat "$problems" >&2; rm -f "$problems"
            echo "error: a distribution build must load only from its bundle and run on macOS $minimum" >&2
            return 1
        fi
        NATIVE_CLOSURE="not-portable"
        echo "    warning: this build is not portable (it will run on this Mac only):" >&2
        sed 's/^/      /' "$problems" | head -12 >&2
    fi
    rm -f "$problems"

    # Entry points really start from inside the bundle.
    local java
    for java in "$contents/Resources/runtime/bin/java" "$contents/Resources/runtime-"*/bin/java; do
        [[ -x "$java" ]] || continue
        "$java" -version > /dev/null 2>&1 || { echo "error: bundled java does not start: $java" >&2; return 1; }
    done
    "$contents/Resources/Binaries/ffmpeg" -version > /dev/null 2>&1 || { echo "error: bundled ffmpeg does not start" >&2; return 1; }
    [[ -f "$contents/Resources/Binaries/libmpv.dylib" ]] || { echo "error: bundled libmpv is missing" >&2; return 1; }
    echo "    verified: signatures, entry points, native closure ($NATIVE_CLOSURE), minimum macOS $minimum"
}

# Runs the finished bundle's own engine — its runtime, jar and archive, with
# DaemonSupervisor's flags, from Contents/Resources — through the packaging
# self-test: translate an embedded extension, then search, details and links
# in a sandboxed worker. -Xshare:on makes the engine and the worker refuse to
# start when the archive does not load, so a stale archive fails the build
# instead of silently costing startup time.
selftest_bundle() {
    local resources="$1/Contents/Resources" home output
    home="$(mktemp -d "${TMPDIR:-/tmp}/cloudstream-selftest.XXXXXX")"
    mkdir -p "$home/tmp"
    # Flags mirror DaemonSupervisor.makeBundledLaunch; change both together.
    if ! output="$(cd "$resources" && env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS -u _JAVA_OPTIONS -u CLASSPATH \
            runtime/bin/java --add-modules=jdk.incubator.foreign --enable-native-access=ALL-UNNAMED \
            -XX:TieredStopAtLevel=1 -Xms16m -Xmx192m -XX:MaxDirectMemorySize=64m \
            -XX:+UseSerialGC -XX:+ExitOnOutOfMemoryError \
            -XX:SharedArchiveFile="$resources/tools/daemon.jsa" -Xshare:on \
            -Djava.net.useSystemProxies=true \
            -Dcs.cloudstream.home="$home" -Djava.io.tmpdir="$home/tmp" \
            -jar tools/daemon.jar --self-test 2>&1)"; then
        echo "$output" | tail -20 >&2
        rm -rf "$home"
        echo "error: the finished app's engine failed its self-test" >&2
        return 1
    fi
    rm -rf "$home"
    if ! grep -q "sandboxed=true" <<<"$output"; then
        echo "$output" >&2
        echo "error: the self-test worker did not run sandboxed" >&2
        return 1
    fi
    echo "    self-test (bundle engine, archive loaded, sandboxed worker): $(tail -1 <<<"$output")"
}

# Inventory and provenance files that exist for this build, as publisher
# arguments, one per line.
provenance_arguments() {
    local app="$1" file
    for file in "$app/Contents/Resources/tools/sbom.cdx.json" \
                "$app/Contents/Resources/tools/runtime-provenance.json" \
                "$ARTIFACT_CLIENT/Resources/media-manifest.json"; do
        if [[ -f "$file" ]]; then printf '%s\n%s\n' "--attach" "$file"; fi
    done
}
