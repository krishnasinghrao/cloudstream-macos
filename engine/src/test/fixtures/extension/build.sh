#!/bin/sh
# Rebuilds the committed DEX test extensions. Requires JDK 17 and Android d8.
# Run from the repository root after `./gradlew :engine:classes`.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../../.." && pwd)"
out="$here/../../resources/extensions"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# kotlin-stdlib (for Continuation in suspend overrides): $KOTLIN_STDLIB or the Gradle cache.
stdlib="${KOTLIN_STDLIB:-$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib" -name 'kotlin-stdlib-2*.jar' ! -name '*sources*' | sort | tail -1)}"
[ -f "$stdlib" ] || { echo "kotlin-stdlib jar not found; set KOTLIN_STDLIB" >&2; exit 1; }
cp_lib="$root/library/build/libs/library-jvm-1.0.1.jar:$root/engine/build/classes/kotlin/main:$stdlib"
javac --release 17 -nowarn -cp "$cp_lib" -d "$work/classes" "$here"/src/fixture/*.java
D8="${D8:-d8}"
mkdir -p "$work/single" "$work/multi/a" "$work/multi/b"
# Single-DEX variants
"$D8" --release --min-api 21 --lib "$root/library/build/libs/library-jvm-1.0.1.jar" --classpath "$root/engine/build/classes/kotlin/main" --classpath "$stdlib" \
    --output "$work/single" "$work"/classes/fixture/*.class
# Multi-DEX: plugin class in classes.dex, provider in classes2.dex
"$D8" --release --min-api 21 --classpath "$work/classes" --classpath "$root/library/build/libs/library-jvm-1.0.1.jar" --classpath "$root/engine/build/classes/kotlin/main" --classpath "$stdlib" \
    --output "$work/multi/a" "$work/classes/fixture/FixturePlugin.class"
"$D8" --release --min-api 21 --classpath "$work/classes" --classpath "$root/library/build/libs/library-jvm-1.0.1.jar" --classpath "$root/engine/build/classes/kotlin/main" --classpath "$stdlib" \
    --output "$work/multi/b" "$work/classes/fixture/FixtureApi.class"
mkdir -p "$out"
package() { # name pluginClass dexdir [dex2dir] [requiresResources]
    dir="$work/pkg-$1"; mkdir -p "$dir"
    printf '{"name":"%s","pluginClassName":"%s","version":1,"requiresResources":%s}' "$1" "$2" "${5:-false}" > "$dir/manifest.json"
    cp "$3/classes.dex" "$dir/classes.dex"
    if [ -n "${4:-}" ]; then cp "$4/classes.dex" "$dir/classes2.dex"; fi
    (cd "$dir" && rm -f "$out/$1.cs3" && zip -X -q -D "$out/$1.cs3" manifest.json classes*.dex)
}
package fixture fixture.FixturePlugin "$work/single"
package failing fixture.FailingPlugin "$work/single"
package multidex fixture.FixturePlugin "$work/multi/a" "$work/multi/b"
package resources fixture.FixturePlugin "$work/single" "" true
package hostile fixture.HostilePlugin "$work/single"
package extractor-host fixture.ExtractorHostPlugin "$work/single"
package consumer fixture.ConsumerPlugin "$work/single"
package configurable fixture.ConfigurablePlugin "$work/single"
package credential fixture.CredentialPlugin "$work/single"
# Real compiled Android resources (RT-13): aapt2 compile + link against android.jar.
AAPT2="${AAPT2:-$(ls "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"/build-tools/*/aapt2 | tail -1)}"
ANDROID_JAR="${ANDROID_JAR:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}/platforms/android-35/android.jar}"
"$AAPT2" compile --dir "$here/resources/res" -o "$work/compiled.zip"
"$AAPT2" link -I "$ANDROID_JAR" --manifest "$here/resources/AndroidManifest.xml" -A "$here/resources/assets" \
    -o "$work/resources.apk" "$work/compiled.zip"
dir="$work/pkg-android-resources"; mkdir -p "$dir"
(cd "$dir" && unzip -q "$work/resources.apk" 'resources.arsc' 'res/*' 'assets/*')
printf '{"name":"%s","pluginClassName":"%s","version":1,"requiresResources":true}' android-resources fixture.ResourcePlugin > "$dir/manifest.json"
cp "$work/single/classes.dex" "$dir/classes.dex"
(cd "$dir" && rm -f "$out/android-resources.cs3" && zip -X -q -r -D "$out/android-resources.cs3" manifest.json classes.dex resources.arsc res assets)
ls -l "$out"
