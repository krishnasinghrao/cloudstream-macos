#!/usr/bin/env bash
# Isolated tests for the real backup and preference policies.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec bash "$script_dir/test_swift_core.sh" backup
