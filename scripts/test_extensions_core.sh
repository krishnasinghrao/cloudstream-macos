#!/usr/bin/env bash
# Isolated tests for the real extension store, client and IPC values.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec bash "$script_dir/test_swift_core.sh" extensions
