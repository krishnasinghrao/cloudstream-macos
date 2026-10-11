#!/usr/bin/env bash
#
# CloudStream macOS — isolated smoke launch of one built app.
#
#   scripts/smoke_launch.sh <path to CloudStream.app or its executable>
#
# Launches the app with a private temporary root (engine data, library,
# preferences, downloads and logs), then requires all of:
#   * the launched app stays alive;
#   * that app reports its own engine connection as usable (it verifies the
#     engine over its authenticated endpoint before saying so);
#   * the engine it names is running and is a child of the launched app;
#   * the player prerequisites (ffmpeg, libmpv) are present in the bundle;
#   * after the app is asked to quit, the app and that engine exit in time;
#   * the engine log holds this launch's start and exit markers.
# Any unmet criterion exits nonzero. Only the launched app and its own
# children are ever signalled; other CloudStream processes are not touched and no
# production data is read or written.
#
# Exit status: 0 passed, 1 failed, 2 usage error. "Not run" is not a pass:
# callers that skip the smoke launch must say so themselves.
set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <CloudStream.app | executable>" >&2
    exit 2
fi
target="$1"
if [[ -d "$target" ]]; then target="$target/Contents/MacOS/CloudStream"; fi
if [[ ! -x "$target" ]]; then
    echo "smoke: FAILED — no executable at $target" >&2
    exit 1
fi

ready_timeout="${CS_SMOKE_READY_TIMEOUT:-90}"
quit_timeout="${CS_SMOKE_QUIT_TIMEOUT:-30}"
root="$(mktemp -d "${TMPDIR:-/tmp}/cloudstream-smoke.XXXXXX")"
status_file="$root/smoke-status.json"
app_pid=""
engine_pid=""
owned_engine=""   # set only after the engine is proven to be the app's child
passed=0

field() { # field <json key path> — prints the value or nothing
    /usr/bin/python3 - "$status_file" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    value = json.load(open(sys.argv[1]))
    for key in sys.argv[2].split('.'):
        value = value[key]
    print('' if value is None else (str(value).lower() if isinstance(value, bool) else value))
except Exception:
    pass
PY
}

alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }

cleanup() {
    # Only the app this run started and that app's own children are stopped.
    # Children are listed while the app still exists, because parentage is
    # the proof of ownership; an engine PID is honoured only if it was one.
    local children=""
    if alive "$app_pid"; then
        children="$(pgrep -P "$app_pid" 2>/dev/null || true)"
        kill -TERM "$app_pid" 2>/dev/null
        local waited=0
        while alive "$app_pid" && (( waited < 20 )); do sleep 0.25; waited=$((waited + 1)); done
        if alive "$app_pid"; then
            # Stop children before killing their parent, while ownership is clear.
            for child in $children; do alive "$child" && kill -KILL "$child" 2>/dev/null; done
            kill -KILL "$app_pid" 2>/dev/null
        fi
    fi
    for child in $children $owned_engine; do
        alive "$child" && kill -KILL "$child" 2>/dev/null
    done
    # Reap the app we launched and give its killed children time to disappear.
    # A successful kill only queues a signal; returning immediately races callers.
    if [[ -n "$app_pid" ]]; then wait "$app_pid" 2>/dev/null || true; fi
    for child in $children $owned_engine; do
        local waited=0
        while alive "$child" && (( waited < 20 )); do sleep 0.1; waited=$((waited + 1)); done
    done
    if [[ "$passed" == 1 ]]; then rm -rf "$root"; else echo "smoke: evidence kept in $root" >&2; fi
}
trap cleanup EXIT

fail() {
    echo "smoke: FAILED — $1" >&2
    if [[ -f "$root/app.log" ]]; then tail -20 "$root/app.log" >&2 || true; fi
    exit 1
}

CS_IN_MEMORY_DB=1 CS_TEST_ROOT="$root" CS_SMOKE_STATUS_FILE="$status_file" \
    "$target" > "$root/app.log" 2>&1 &
app_pid=$!
echo "smoke: launched pid $app_pid with private root $root"

deadline=$((SECONDS + ready_timeout))
phase=""
while (( SECONDS < deadline )); do
    alive "$app_pid" || fail "the app exited before its engine was usable"
    if [[ "$(field appPID)" == "$app_pid" ]]; then
        phase="$(field phase)"
        [[ "$phase" == "usable" ]] && break
        [[ "$phase" == "failed" ]] && fail "the app reported that its engine failed"
    fi
    sleep 0.5
done
[[ "$phase" == "usable" ]] || fail "the engine was not usable within ${ready_timeout}s (last phase: ${phase:-none})"

engine_pid="$(field enginePID)"
[[ -n "$engine_pid" ]] || fail "the app reported a usable engine without naming its process"
alive "$engine_pid" || fail "the engine the app named (pid $engine_pid) is not running"
parent="$(ps -o ppid= -p "$engine_pid" 2>/dev/null | tr -d ' ')"
[[ "$parent" == "$app_pid" ]] || fail "engine pid $engine_pid is not a child of the launched app (parent: ${parent:-unknown})"
owned_engine="$engine_pid"
[[ "$(field player.ffmpeg)" == "true" ]] || fail "the bundle has no usable ffmpeg"
[[ "$(field player.libmpv)" == "true" ]] || fail "the bundle has no libmpv"
echo "smoke: engine pid $engine_pid usable (generation $(field generation), IPC $(field ipcVersion))"

kill -TERM "$app_pid" 2>/dev/null
deadline=$((SECONDS + quit_timeout))
while alive "$app_pid" && (( SECONDS < deadline )); do sleep 0.25; done
alive "$app_pid" && fail "the app did not quit within ${quit_timeout}s"
app_pid=""
deadline=$((SECONDS + 10))
while alive "$engine_pid" && (( SECONDS < deadline )); do sleep 0.25; done
alive "$engine_pid" && fail "the engine (pid $engine_pid) outlived the app: orphan"
owned_engine=""

log="$root/Logs/daemon-stdout.log"
grep -q "=== engine launch .* started" "$log" 2>/dev/null || fail "the engine log has no start marker for this launch ($log)"
grep -q "=== engine launch .* ended" "$log" 2>/dev/null || fail "the engine log has no exit marker for this launch ($log)"

passed=1
echo "smoke: PASSED"
