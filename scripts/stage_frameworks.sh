#!/usr/bin/env bash
# Preserve Xcode-owned runtime frameworks while moving staged native libraries
# to the conventional bundle directory before final signing.
set -euo pipefail
contents="${1:?usage: stage_frameworks.sh APP_CONTENTS}"
[[ -d "$contents" && "$contents" == */Contents ]] || { echo 'Invalid app Contents directory' >&2; exit 1; }
destination="$contents/Frameworks"
source="$contents/Resources/Frameworks"
if [[ -L "$destination" ]]; then
    [[ "$(readlink "$destination")" == "Resources/Frameworks" ]] || { echo 'Unexpected Frameworks symlink' >&2; exit 1; }
    rm "$destination"
fi
mkdir -p "$destination"
if [[ -d "$source" ]]; then
    ditto "$source" "$destination"
    rm -rf "$source"
fi
