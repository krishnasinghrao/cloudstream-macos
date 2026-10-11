#!/usr/bin/env bash
# The complete client suite in one run, every gated tier provisioned:
#   - live libmpv tests (CS_MPV_ENGINE_TESTS) with fixtures in /tmp;
#   - large-library measurements (CS_LARGE_LIBRARY_TESTS);
#   - player benchmarks against two local CDN simulators (CS_MPV_BENCH, ...);
#   - live extension playback (CS_LIVE_PLAYBACK_TESTS): links resolved by an
#     Android-compiled extension in a sandboxed engine worker
#     (LocalMediaLinksTest) pointing at the local CDN;
#   - old-schema identity compatibility and process-kill fixtures (the frozen
#     legacy tool and a separate debug app process);
#   - the UI tests.
# Fails when any test fails or is skipped.
#
# Usage: run_full_client_tests.sh [absolute DerivedData directory]
# CS_FULL_ONLY_TESTING="Target/Class Target/Class/test" runs only those, with
# the same provisioning (to reproduce one failure).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
derived="${1:-$repo/client/build/DerivedData-full}"
case "$derived" in /*) ;; *) echo "DerivedData path must be absolute" >&2; exit 2 ;; esac
ffmpeg="${CS_FIXTURE_FFMPEG:-$(command -v ffmpeg || true)}"
[ -x "$ffmpeg" ] || { echo "error: ffmpeg not found (set CS_FIXTURE_FFMPEG)" >&2; exit 1; }
dir="${CS_BENCH_DIR:-/tmp/cs-bench}"
links=/tmp/cs_live_links.json
work="$(mktemp -d "${TMPDIR:-/tmp}/cloudstream-full-tests.XXXXXX")"
xctestrun=""
# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
    bench_cleanup 2>/dev/null || true
    rm -rf "$work"
    if [ -n "$xctestrun" ]; then rm -f "$xctestrun"; fi
}
trap cleanup EXIT

echo "==> Engine jar (the client's end-to-end tests launch it)"
(cd "$repo" && ./gradlew :engine:jar --console=plain -q)

echo "==> Live player fixtures"
CS_FIXTURE_FFMPEG="$ffmpeg" "$repo/scripts/make_player_fixtures.sh"

echo "==> Local CDN media and simulators"
# shellcheck source=scripts/lib_bench_media.sh
. "$repo/scripts/lib_bench_media.sh"

echo "==> Extension links from a sandboxed worker"
rm -f "$links"
(cd "$repo" && ./gradlew :engine:test --tests 'com.lagradost.macos.LocalMediaLinksTest' --rerun-tasks \
    "-Dcs.exportLinks=$links" "-Dcs.exportOrigin=$base" --console=plain -q)
[ -s "$links" ] || { echo "error: the extension exported no links" >&2; exit 1; }

echo "==> Frozen legacy identity tool"
bash "$repo/scripts/tests/build_legacy_identity_fixture.sh" "$work/legacy-identity-tool"

echo "==> Building for testing"
xcodebuild -project "$repo/client/CloudStreamMac.xcodeproj" -scheme CloudStreamMac \
    -configuration Debug -derivedDataPath "$derived" -destination 'platform=macOS,arch=arm64' \
    build-for-testing CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES COMPILER_INDEX_STORE_ENABLE=NO -quiet

# __TESTROOT__ paths require the modified run file to remain beside Products.
xctestrun="$(python3 -I - "$derived/Build/Products" "$work/legacy-identity-tool" "$base" "$norange" "$dir" <<'PY'
from pathlib import Path
import plistlib
import sys
import uuid
products, tool, base, norange, media = Path(sys.argv[1]), *sys.argv[2:]
originals = list(products.glob('CloudStreamMac_macosx*-arm64.xctestrun'))
if len(originals) != 1:
    raise SystemExit('Expected exactly one arm64 client xctestrun')
data = plistlib.loads(originals[0].read_bytes())
data['CloudStreamMacTests']['EnvironmentVariables'].update({
    'CS_MPV_ENGINE_TESTS': '1',
    'CS_LARGE_LIBRARY_TESTS': '1',
    'CS_MPV_BENCH': '1',
    'CS_BENCH_BASE': base,
    'CS_BENCH_BASE_NORANGE': norange,
    'CS_YT_DIR': media,
    'CS_LIVE_PLAYBACK_TESTS': '1',
    'CS_IDENTITY_LEGACY_TOOL': tool,
    'CS_IDENTITY_PROCESS_APP': str(products / 'Debug' / 'CloudStream.app' / 'Contents' / 'MacOS' / 'CloudStream'),
})
output = products / ('CloudStreamMac-full-' + str(uuid.uuid4()) + '.xctestrun')
with output.open('xb') as file:
    plistlib.dump(data, file)
print(output)
PY
)"

echo "==> Running every client and UI test"
mkdir -p "$repo/client/build/test-results"
result_dir="$(mktemp -d "$repo/client/build/test-results/full.XXXXXX")"
selection=()
for name in ${CS_FULL_ONLY_TESTING:-}; do selection+=("-only-testing:$name"); done
status=0
"$repo/scripts/run_logged.sh" "$result_dir/xcodebuild.log" \
    xcodebuild -xctestrun "$xctestrun" -derivedDataPath "$derived" \
    -destination 'platform=macOS,arch=arm64' test-without-building ${selection[@]+"${selection[@]}"} \
    -resultBundlePath "$result_dir/tests.xcresult" || status=$?

summary="$(xcrun xcresulttool get test-results summary --path "$result_dir/tests.xcresult")"
python3 -I - "$summary" <<'PY'
import json
import sys
summary = json.loads(sys.argv[1])
counts = {key: summary.get(key, 0) for key in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')}
print('full client run:', counts)
for failure in summary.get('testFailures', []):
    print('FAILED', failure.get('testIdentifierString'), '-', failure.get('failureText', '')[:300])
if counts['skippedTests']:
    raise SystemExit('skipped tests are failures in the full run')
PY
echo "Results: $result_dir"
exit "$status"
