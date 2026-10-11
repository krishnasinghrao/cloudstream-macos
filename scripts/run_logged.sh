#!/usr/bin/env bash
# Run a command with an inspectable raw log, preserving pipeline failures.
set -euo pipefail
if [[ $# -lt 2 ]]; then
    echo "usage: run_logged.sh <log-path> <command> [arguments...]" >&2
    exit 64
fi
log_path="$1"
shift
mkdir -p "$(dirname "$log_path")"
status=0
"$@" 2>&1 | tee "$log_path" || status=$?
exit "$status"
