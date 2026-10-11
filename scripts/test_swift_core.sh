#!/usr/bin/env bash
# Test real Swift sources without app initialization or distribution build phases.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
suite="${1:-}"
sources=(
    App/AppEnvironment.swift App/ManagedExtensionPolicy.swift
    Services/DaemonClient.swift Services/EngineDemand.swift Services/EngineTransport.swift
    Services/ExtensionPreferenceChanges.swift
    Services/Contracts/LibraryIdentity.swift Services/Contracts/DaemonServiceContracts.swift
    ViewModels/ExtensionsStore.swift
)
case "$suite" in
    extensions)
        tests=(ExtensionsStoreTests.swift)
        ;;
    backup)
        sources+=(
            Models/WatchType.swift Models/LibraryViewOptions.swift Models/SubtitleStyle.swift
            Services/Contracts/LibraryPagePolicy.swift
            Services/UserPreferences.swift Services/Playback/LinkRanker.swift
            Services/Backup/BackupDocument.swift Services/Backup/BackupPreferencePolicy.swift
            Services/Backup/BackupFilePolicy.swift
        )
        tests=(BackupValidationTests.swift)
        ;;
    *) echo "usage: test_swift_core.sh <extensions|backup>" >&2; exit 64 ;;
esac
test_root="$(mktemp -d "${TMPDIR:-/tmp}/cloudstream-${suite}-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/Sources/CloudStream" "$test_root/Tests/CloudStreamTests"
cp "$repo_root"/client/Sources/Models/IPC/*.swift "$test_root/Sources/CloudStream/"
for source in "${sources[@]}"; do
    cp "$repo_root/client/Sources/$source" "$test_root/Sources/CloudStream/"
done
for test in "${tests[@]}"; do
    cp "$repo_root/client/Tests/$test" "$test_root/Tests/CloudStreamTests/"
done
cat > "$test_root/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CloudStreamCoreTests", platforms: [.macOS(.v15)],
    targets: [.target(name: "CloudStream"), .testTarget(name: "CloudStreamTests", dependencies: ["CloudStream"])])
PACKAGE
# Keep compiler/package-manager caches in the owned test root too.
export CLANG_MODULE_CACHE_PATH="$test_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$test_root/ModuleCache"
swift test --package-path "$test_root" --cache-path "$test_root/cache" \
    --config-path "$test_root/config" --security-path "$test_root/security" --disable-sandbox
