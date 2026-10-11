#!/usr/bin/env bash
# Frozen audited persistent models, compiled separately under their original
# module name; never linked into the current application.
set -euo pipefail
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
fixture_output="${1:?Specify an absolute output executable path}"
case "$fixture_output" in /*) ;; *) echo "Output path must be absolute" >&2; exit 2 ;; esac
fixture_work="$(mktemp -d "${TMPDIR:-/tmp}/cloudstream-legacy-schema.XXXXXX")"
trap 'rm -rf "$fixture_work"' EXIT
cp "$fixture_dir/fixtures/legacy_identity_schema.swift.fixture" "$fixture_work/schema.swift"
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 -module-name CloudStream "$fixture_work/schema.swift" -o "$fixture_output"
