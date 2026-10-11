#!/usr/bin/env bash
# Generates the media fixtures the live player tests read from /tmp
# (client/Tests/PlayerEngineLiveTests.swift, PlayerAudioPipelineTests.swift).
# Needs an ffmpeg with lavfi, libx264, libx265 and aac (CS_FIXTURE_FFMPEG,
# else the one on PATH). Existing fixtures are kept unless --force is given.
set -euo pipefail
ffmpeg="${CS_FIXTURE_FFMPEG:-$(command -v ffmpeg || true)}"
[ -x "$ffmpeg" ] || { echo "error: ffmpeg not found (set CS_FIXTURE_FFMPEG)" >&2; exit 1; }
force="${1:-}"
run() { "$ffmpeg" -hide_banner -loglevel error -y "$@"; }
make_fixture() { # path, then ffmpeg arguments
    local path="$1"; shift
    if [ -s "$path" ] && [ "$force" != "--force" ]; then return; fi
    echo "==> $path"
    run "$@" "$path.partial.mp4"
    mv "$path.partial.mp4" "$path"
}
# A few seconds of H.264 + stereo AAC.
make_fixture /tmp/test_stereo.mp4 -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -ac 2 -shortest
# White top half, black bottom half: catches a flipped renderer.
make_fixture /tmp/test_orientation.mp4 -f lavfi -i "color=c=white:size=640x360:rate=30,drawbox=x=0:y=180:w=640:h=180:color=black:t=fill" \
    -f lavfi -i anullsrc=r=48000:cl=stereo -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest
# Mid-grey PQ signal (~92 nits) in BT.2020: tone mapping makes it light grey.
make_fixture /tmp/test_hdr10.mp4 -f lavfi -i "color=c=0x808080:size=1280x720:rate=24" -t 3 \
    -vf "format=yuv420p10le" -c:v libx265 -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -tag:v hvc1
# 4K HEVC Main10 PQ for the GPU/CPU cost measurement.
make_fixture /tmp/test_4k_hdr10.mp4 -f lavfi -i "testsrc2=size=3840x2160:rate=24" -t 4 \
    -vf "format=yuv420p10le" -c:v libx265 -preset ultrafast -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -tag:v hvc1
# 1920x1080 H.264 High, BT.709, 24 fps.
make_fixture /tmp/test_1080p.mp4 -f lavfi -i "testsrc2=size=1920x1080:rate=24" -t 4 \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709
echo "Player fixtures ready."
