#!/usr/bin/env bash
#
# CloudStream macOS — build libmpv + ffmpeg from source for the app's
# minimum macOS version.
#
# Why: Homebrew bottles are compiled for the build machine's macOS, so
# bundling Homebrew's mpv/ffmpeg made every media binary require whatever
# macOS the packager ran (27.0), while the app declares 15.0. This script
# builds a lean, pinned stack instead:
#
#   ffmpeg (shared libs + CLI)  dav1d  freetype  fribidi  harfbuzz
#   libass (CoreText fonts)     uchardet  libplacebo (OpenGL)  libmpv
#
# Only what the player uses is enabled: vo=libmpv with the OpenGL render API
# (GPU scaling, colour conversion and HDR tone mapping) and the "sw" render
# API as a fallback, zero-copy VideoToolbox decoding (videotoolbox-gl, which
# needs mpv's Cocoa/Swift glue), CoreAudio/AVFoundation output, libass
# subtitles, and png/jpeg screenshots. No encoders beyond those, no Vulkan,
# no Lua/JavaScript, no Blu-ray/DVD.
#
# Usage:
#   ./build_media_stack.sh
# Env:
#   MACOS_MIN        minimum macOS (default: MACOSX_DEPLOYMENT_TARGET from client/project.yml)
#   CS_MEDIA_WORK    scratch directory for sources/builds (default: $TMPDIR/cs-media-work)
#   CS_MEDIA_PREFIX  install prefix (default: client/build/media-stack)
#   KEEP_SOURCES=1   keep source/build trees after installing (default: deleted, ~2 GB)
#
# Output: $CS_MEDIA_PREFIX/lib/libmpv.2.dylib and $CS_MEDIA_PREFIX/bin/ffmpeg,
# consumed by package_app.sh -> bundle_media.sh.
#
# Build tools: meson, ninja, pkg-config (pip install meson ninja pkgconf jinja2
# into a virtualenv works) and git. Homebrew libraries are deliberately never
# used: PKG_CONFIG_LIBDIR is pinned to this prefix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_DIR="$(cd "$SCRIPT_DIR/../client" && pwd)"

MACOS_MIN="${MACOS_MIN:-$(awk -F'"' '/MACOSX_DEPLOYMENT_TARGET:/ {print $2; exit}' "$CLIENT_DIR/project.yml")}"
[[ -n "$MACOS_MIN" ]] || { echo "error: could not read MACOSX_DEPLOYMENT_TARGET from project.yml" >&2; exit 1; }
ARCH="arm64"   # project.yml ARCHS: [arm64]
WORK="${CS_MEDIA_WORK:-${TMPDIR:-/tmp}/cs-media-work}"
PREFIX="${CS_MEDIA_PREFIX:-$CLIENT_DIR/build/media-stack}"
JOBS="$(sysctl -n hw.ncpu)"

# name | git url | tag | expected commit (tags can be moved; commits can't)
SOURCES=(
    "ffmpeg|https://github.com/FFmpeg/FFmpeg.git|n9.0.2|946fcce07b6dcd0331c8cc609192aeff5e1924f8"
    "dav1d|https://code.videolan.org/videolan/dav1d.git|1.5.4|54706fc6bc0cdecab7e9593974a4039cc038fca7"
    "freetype|https://gitlab.freedesktop.org/freetype/freetype.git|VER-2-14-3|0a0221a1347e2f1e07c395263540026e9a0aa7c7"
    "fribidi|https://github.com/fribidi/fribidi.git|v1.0.17|b93119f5fdc7ea47672cc304c1455ffa6dfe7536"
    "harfbuzz|https://github.com/harfbuzz/harfbuzz.git|14.5.0|863d3f7787c6df18d20e4535c5906bf3eb803bd5"
    "libass|https://github.com/libass/libass.git|0.17.5|4a05d8127f525943ebf45fdc6497c9e665947f0d"
    "uchardet|https://gitlab.freedesktop.org/uchardet/uchardet.git|v0.0.8|ae6302a016088ad07177f86d417b20010053632b"
    "libplacebo|https://code.videolan.org/videolan/libplacebo.git|v7.360.1|cee9b076f2c63104ccfd497fa79c39a867293ec4"
    "mpv|https://github.com/mpv-player/mpv.git|v0.41.0|41f6a645068483470267271e1d09966ca3b9f413"
)

step() { echo "==> $*"; }

for tool in git meson ninja pkg-config; do
    command -v "$tool" >/dev/null || { echo "error: '$tool' not found (see header for how to install build tools)" >&2; exit 1; }
done

export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
export CFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN -O2"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PATH="$PREFIX/bin:$PATH"

mkdir -p "$WORK" "$PREFIX"
step "Building media stack for macOS $MACOS_MIN ($ARCH) into $PREFIX"

fetch() {
    local name="$1" url="$2" tag="$3" commit="$4"
    local dir="$WORK/$name"
    if [[ ! -d "$dir/.git" ]]; then
        step "Fetching $name $tag"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules "$url" "$dir"
    fi
    local actual
    actual="$(git -C "$dir" rev-parse HEAD)"
    if [[ "$actual" != "$commit" ]]; then
        echo "error: $name $tag is at $actual, expected $commit — refusing to build" >&2
        exit 1
    fi
}

source_dir() { echo "$WORK/$1"; }

meson_build() {
    local name="$1"; shift
    step "Building $name"
    local src
    src="$(source_dir "$name")"
    rm -rf "$src/_build"
    meson setup "$src/_build" "$src" \
        --prefix="$PREFIX" --libdir=lib \
        --buildtype=release --default-library=shared \
        --wrap-mode=nodownload \
        -Db_ndebug=true \
        "$@" >"$WORK/$name.configure.log" 2>&1 \
        || { tail -40 "$WORK/$name.configure.log" >&2; exit 1; }
    ninja -C "$src/_build" -j"$JOBS" install >"$WORK/$name.build.log" 2>&1 \
        || { tail -40 "$WORK/$name.build.log" >&2; exit 1; }
}

for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url tag commit <<<"$entry"
    fetch "$name" "$url" "$tag" "$commit"
done

# --- Libraries ---------------------------------------------------------------

meson_build dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false

meson_build freetype -Dzlib=disabled -Dbzip2=disabled -Dpng=disabled \
    -Dharfbuzz=disabled -Dbrotli=disabled

meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false

meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dchafa=disabled -Dicu=disabled -Dcoretext=enabled \
    -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled \
    -Dutilities=disabled -Dbenchmark=disabled

meson_build libass -Dfontconfig=disabled -Dcoretext=enabled \
    -Ddirectwrite=disabled -Dlibunibreak=disabled -Dtest=disabled \
    -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

step "Building uchardet"
UCHARDET_SRC="$(source_dir uchardet)"
rm -rf "$UCHARDET_SRC/_build"
cmake -S "$UCHARDET_SRC" -B "$UCHARDET_SRC/_build" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
    -DBUILD_BINARY=OFF -DBUILD_STATIC=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >"$WORK/uchardet.configure.log" 2>&1 \
    || { tail -40 "$WORK/uchardet.configure.log" >&2; exit 1; }
cmake --build "$UCHARDET_SRC/_build" -j"$JOBS" --target install >"$WORK/uchardet.build.log" 2>&1 \
    || { tail -40 "$WORK/uchardet.build.log" >&2; exit 1; }

# FFmpeg's DASH demuxer needs libxml2. Use the copy macOS itself ships
# (/usr/lib/libxml2.2.dylib, updated with the OS) rather than bundling another;
# this .pc file exists only for FFmpeg's configure and is not installed.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
LIBXML2_PC_DIR="$WORK/sdk-pkgconfig"
mkdir -p "$LIBXML2_PC_DIR"
LIBXML2_VERSION="$(awk -F'"' '/#define LIBXML_DOTTED_VERSION/ {print $2; exit}' "$SDK_PATH/usr/include/libxml2/libxml/xmlversion.h")"
[[ -n "$LIBXML2_VERSION" ]] || { echo "error: libxml2 headers not found in $SDK_PATH" >&2; exit 1; }
cat >"$LIBXML2_PC_DIR/libxml-2.0.pc" <<EOF
Name: libXML
Description: libXML library version2 (macOS SDK)
Version: $LIBXML2_VERSION
Libs: -L$SDK_PATH/usr/lib -lxml2
Cflags: -I$SDK_PATH/usr/include/libxml2
EOF

step "Building ffmpeg"
FFMPEG_SRC="$(source_dir ffmpeg)"
(
    cd "$FFMPEG_SRC"
    make distclean >/dev/null 2>&1 || true
    PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR:$LIBXML2_PC_DIR" ./configure \
        --prefix="$PREFIX" \
        --arch="$ARCH" --target-os=darwin \
        --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
        --enable-shared --disable-static \
        --disable-autodetect \
        --enable-videotoolbox --enable-audiotoolbox \
        --enable-securetransport --enable-zlib \
        --enable-libdav1d --enable-libxml2 \
        --disable-encoders --enable-encoder=png,mjpeg \
        --disable-devices --disable-indevs --disable-outdevs \
        --disable-programs --enable-ffmpeg \
        --disable-doc --disable-debug \
        --disable-libxcb --disable-sdl2 --disable-xlib
) >"$WORK/ffmpeg.configure.log" 2>&1 || { tail -40 "$WORK/ffmpeg.configure.log" >&2; exit 1; }
make -C "$FFMPEG_SRC" -j"$JOBS" >"$WORK/ffmpeg.build.log" 2>&1 || { tail -40 "$WORK/ffmpeg.build.log" >&2; exit 1; }
make -C "$FFMPEG_SRC" install >>"$WORK/ffmpeg.build.log" 2>&1 || { tail -40 "$WORK/ffmpeg.build.log" >&2; exit 1; }

meson_build libplacebo -Dvulkan=disabled -Dopengl=enabled -Dd3d11=disabled \
    -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled -Ddovi=enabled \
    -Dlibdovi=disabled -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false

meson_build mpv -Dlibmpv=true -Dcplayer=false -Dtests=false \
    -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled \
    -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled -Drubberband=disabled \
    -Dlcms2=disabled -Dvapoursynth=disabled -Dzimg=disabled -Djpeg=disabled \
    -Duchardet=enabled -Dlibavdevice=disabled \
    -Dgl=enabled -Dgl-cocoa=enabled -Dcocoa=enabled -Dswift-build=enabled -Dvulkan=disabled \
    -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled -Dmacos-touchbar=disabled \
    -Dvideotoolbox-gl=enabled -Dvideotoolbox-pl=disabled \
    -Dcoreaudio=enabled -Davfoundation=enabled -Daudiounit=disabled \
    -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled

# --- Verify --------------------------------------------------------------------

step "Verifying minimum macOS of every built binary"
"$SCRIPT_DIR/check_min_os.sh" --min "$MACOS_MIN" "$PREFIX/lib" "$PREFIX/bin/ffmpeg"

step "Checking the streaming demuxers extensions return"
DEMUXERS="$("$PREFIX/bin/ffmpeg" -hide_banner -demuxers 2>/dev/null)"
for demuxer in dash hls mov; do
    grep -Eq "^ D[ d]* ${demuxer}[ ,]" <<<"$DEMUXERS" \
        || { echo "error: ffmpeg was built without the $demuxer demuxer" >&2; exit 1; }
done

step "Checking that nothing links Homebrew"
if otool -L "$PREFIX"/lib/*.dylib "$PREFIX/bin/ffmpeg" | grep -q '/opt/homebrew\|/usr/local/'; then
    otool -L "$PREFIX"/lib/*.dylib "$PREFIX/bin/ffmpeg" | grep '/opt/homebrew\|/usr/local/' >&2
    echo "error: a built binary links a Homebrew library" >&2
    exit 1
fi

# --- Provenance ------------------------------------------------------------------
# What was built, from which commits, with which flags and tools. The licence
# and configuration lines are ffmpeg's own report of this build, not what
# upstream could have been configured to include.
step "Writing media-provenance.json"
python3 - "$PREFIX/media-provenance.json" "$MACOS_MIN" "$ARCH" "$0" "$PREFIX/bin/ffmpeg" "${SOURCES[@]}" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
output, minimum, arch, script, ffmpeg, *sources = sys.argv[1:]
def first_line(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    return (result.stdout or result.stderr).splitlines()[0].strip() if (result.stdout or result.stderr) else None
version = subprocess.run([ffmpeg, "-hide_banner", "-version"], capture_output=True, text=True).stdout.splitlines()
licence = subprocess.run([ffmpeg, "-hide_banner", "-L"], capture_output=True, text=True).stdout.splitlines()
pathlib.Path(output).write_text(json.dumps({
    "minimumOS": minimum,
    "architecture": arch,
    "buildScriptSha256": hashlib.sha256(pathlib.Path(script).read_bytes()).hexdigest(),
    "flags": {key: os.environ.get(key) for key in ("CFLAGS", "LDFLAGS", "MACOSX_DEPLOYMENT_TARGET")},
    "tools": {"meson": first_line("meson", "--version"), "ninja": first_line("ninja", "--version"),
              "compiler": first_line("cc", "--version"), "git": first_line("git", "--version")},
    "sources": [dict(zip(("name", "url", "tag", "commit"), entry.split("|"))) for entry in sources],
    "ffmpegConfiguration": next((line for line in version if line.startswith("configuration:")), None),
    "ffmpegLicence": licence[0].strip() if licence else None,
}, indent=2) + "\n")
PY

if [[ "${KEEP_SOURCES:-0}" != "1" ]]; then
    step "Removing source and build trees ($(du -sh "$WORK" | cut -f1))"
    rm -rf "$WORK"
fi

echo "Done: $PREFIX/lib/libmpv.2.dylib, $PREFIX/bin/ffmpeg (macOS $MACOS_MIN+, $ARCH)"
