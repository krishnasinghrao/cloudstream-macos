#!/usr/bin/env bash
# Shared by run_player_benchmarks.sh and run_full_client_tests.sh: generates the
# local CDN media once into $dir (ffmpeg in $ffmpeg), starts two CDN simulators
# (with and without byte ranges) in the calling shell, and sets $base and
# $norange. The caller's EXIT trap must run bench_cleanup.
# shellcheck disable=SC2154,SC2034 # $repo, $dir and $ffmpeg come from the caller, which uses $base and $norange.
servers=""
bench_cleanup() { for pid in $servers; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done; }
mkdir -p "$dir/hls" "$dir/yt"
run() { "$ffmpeg" -hide_banner -loglevel error -y "$@"; }
make_once() { # output, then ffmpeg arguments
    local out="$1"; shift
    [ -s "$out" ] && return
    echo "==> $out"
    run "$@" "$out.partial.${out##*.}"
    mv "$out.partial.${out##*.}" "$out"
}
# 15 minutes, so resume points at 600 s exist; small frames keep files modest.
video=(-f lavfi -i "testsrc2=size=640x360:rate=24" -t 900)
tone=(-f lavfi -i "sine=frequency=440:sample_rate=48000" -t 900)
make_once "$dir/muxed.mp4" "${video[@]}" "${tone[@]}" -c:v libx264 -preset ultrafast -g 48 -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart -shortest
make_once "$dir/muxed_moovend.mp4" -i "$dir/muxed.mp4" -c copy
make_once "$dir/v.mp4" -i "$dir/muxed.mp4" -an -c copy -movflags +faststart
make_once "$dir/a1.m4a" -i "$dir/muxed.mp4" -vn -c:a aac -b:a 128k -movflags +faststart
make_once "$dir/a2.m4a" -i "$dir/muxed.mp4" -vn -c:a aac -b:a 64k -movflags +faststart
if [ ! -s "$dir/hls/index.m3u8" ]; then
    echo "==> $dir/hls"
    run -i "$dir/muxed.mp4" -c copy -f hls -hls_time 6 -hls_playlist_type vod \
        -hls_segment_filename "$dir/hls/seg%04d.ts" "$dir/hls/index.m3u8"
fi
# The split "YouTube" stream, in the order the tests label it.
make_once "$dir/yt/video.mp4" -i "$dir/v.mp4" -c copy -movflags +faststart
make_once "$dir/yt/audio0.m4a" -i "$dir/muxed.mp4" -vn -c:a aac -b:a 48k -movflags +faststart
make_once "$dir/yt/audio1.m4a" -i "$dir/muxed.mp4" -vn -c:a aac -b:a 128k -movflags +faststart
make_once "$dir/yt/audio2.webm" -i "$dir/muxed.mp4" -vn -c:a libopus -b:a 50k
make_once "$dir/yt/audio3.webm" -i "$dir/muxed.mp4" -vn -c:a libopus -b:a 70k
make_once "$dir/yt/audio4.webm" -i "$dir/muxed.mp4" -vn -c:a libopus -b:a 160k

start_server() { # port file, extra args; runs in this shell so cleanup can stop it
    local out="$1"; shift
    python3 -I "$repo/scripts/bench_cdn.py" "$dir" "$@" >"$out" &
    servers="$servers $!"
    for _ in $(seq 1 50); do [ -s "$out" ] && break; sleep 0.1; done
    [ -s "$out" ] || { echo "error: benchmark server did not start" >&2; exit 1; }
}
ports="$(mktemp -d)"
start_server "$ports/range"
start_server "$ports/norange" --no-range
port="$(head -1 "$ports/range")"
norange="http://127.0.0.1:$(head -1 "$ports/norange")"
rm -rf "$ports"
base="http://127.0.0.1:$port"
echo "$base/yt/video.mp4" > "$dir/yt_video.txt"
index=0
for audio in audio0.m4a audio1.m4a audio2.webm audio3.webm audio4.webm; do
    echo "$base/yt/$audio" > "$dir/yt_audio$index.txt"
    index=$((index + 1))
done
rm -f "$dir"/yt_audio5.txt "$dir"/yt_audio6.txt "$dir"/yt_audio7.txt

