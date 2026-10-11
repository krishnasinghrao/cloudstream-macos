#!/usr/bin/env bash
# Player startup / resume / A-V sync benchmarks (PlayerStartupBenchmarkTests)
# against a local CDN simulator: generates the media once into $CS_BENCH_DIR
# (default /tmp/cs-bench), serves it with and without byte ranges, and runs
# the benchmark class with CS_MPV_BENCH=1. The "YouTube" inputs are a local
# split stream with the same shape: one video-only file and five audio formats.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
ffmpeg="${CS_FIXTURE_FFMPEG:-$(command -v ffmpeg || true)}"
[ -x "$ffmpeg" ] || { echo "error: ffmpeg not found (set CS_FIXTURE_FFMPEG)" >&2; exit 1; }
dir="${CS_BENCH_DIR:-/tmp/cs-bench}"
trap 'bench_cleanup' EXIT
# shellcheck source=scripts/lib_bench_media.sh
. "$repo/scripts/lib_bench_media.sh"

mkdir -p "$repo/client/build/test-results"
result_dir="$(mktemp -d "$repo/client/build/test-results/bench.XXXXXX")"
TEST_RUNNER_CS_MPV_BENCH=1 TEST_RUNNER_CS_BENCH_BASE="$base" TEST_RUNNER_CS_BENCH_BASE_NORANGE="$norange" \
TEST_RUNNER_CS_YT_DIR="$dir" TEST_RUNNER_CS_IN_MEMORY_DB=1 \
"$repo/scripts/run_logged.sh" "$result_dir/xcodebuild.log" \
xcodebuild -project "$repo/client/CloudStreamMac.xcodeproj" -scheme CloudStreamMac -destination 'platform=macOS' \
    test -only-testing:CloudStreamMacTests/PlayerStartupBenchmarkTests \
    -resultBundlePath "$result_dir/tests.xcresult" -derivedDataPath "$repo/client/build/DerivedData"
