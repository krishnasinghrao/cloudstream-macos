#!/usr/bin/env bash
# Executes old-schema compatibility, transactional migration tests and the
# download-finalization kill fixture (each kills a separate debug app process).
# The ordinary unit selection intentionally does not compile a second app model.
set -euo pipefail
test_script_dir="$(cd "$(dirname "$0")" && pwd)"
test_repo="$(cd "$test_script_dir/../.." && pwd)"
test_derived="${1:?Specify an absolute private DerivedData directory}"
case "$test_derived" in /*) ;; *) echo "DerivedData path must be absolute" >&2; exit 2 ;; esac
test_work="$(mktemp -d "${TMPDIR:-/tmp}/cloudstream-identity-tests.XXXXXX")"
test_run=""
trap 'rm -rf "$test_work"; if [ -n "$test_run" ]; then rm -f "$test_run"; fi' EXIT
bash "$test_script_dir/build_legacy_identity_fixture.sh" "$test_work/legacy-identity-tool"
xcodebuild -project "$test_repo/client/CloudStreamMac.xcodeproj" -scheme CloudStreamMac \
    -configuration Debug -derivedDataPath "$test_derived" -destination 'platform=macOS,arch=arm64' \
    build-for-testing CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES COMPILER_INDEX_STORE_ENABLE=NO
# __TESTROOT__ paths require the modified run file to remain beside Products.
test_run="$(python3 - "$test_derived/Build/Products" "$test_work/legacy-identity-tool" <<'PY'
from pathlib import Path
import plistlib
import sys
import uuid
products = Path(sys.argv[1])
originals = list(products.glob('CloudStreamMac_macosx*-arm64.xctestrun'))
if len(originals) != 1:
    raise SystemExit('Expected exactly one arm64 client xctestrun')
data = plistlib.loads(originals[0].read_bytes())
data['CloudStreamMacTests']['EnvironmentVariables']['CS_IDENTITY_LEGACY_TOOL'] = sys.argv[2]
data['CloudStreamMacTests']['EnvironmentVariables']['CS_IDENTITY_PROCESS_APP'] = str(products / 'Debug' / 'CloudStream.app' / 'Contents' / 'MacOS' / 'CloudStream')
output = products / ('CloudStreamMac-identity-' + str(uuid.uuid4()) + '.xctestrun')
with output.open('xb') as file:
    plistlib.dump(data, file)
print(output)
PY
)"
xcodebuild -xctestrun "$test_run" -derivedDataPath "$test_derived" \
    -destination 'platform=macOS,arch=arm64' test-without-building \
    -only-testing:CloudStreamMacTests/IdentityMigrationTests \
    -only-testing:CloudStreamMacTests/DownloadQueueEndToEndTests/testKilledFinalizationIsReconciledByTheNextProcessAtEveryBoundary
