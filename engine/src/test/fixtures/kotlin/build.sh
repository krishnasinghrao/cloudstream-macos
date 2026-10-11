#!/bin/sh
# Pin: repository Kotlin 2.4.0, Android API 35/build-tools 37, JVM 11, min API 21.
# Compiler task uses the Android SDK before host stubs; fixture runs offline.
set -eu
task_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$task_dir/../../../../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[ -n "$sdk_root" ] || { echo 'Set ANDROID_SDK_ROOT to rebuild Kotlin DEX fixtures' >&2; exit 1; }
(cd "$repo_root" && ./gradlew --offline :engine:compileRuntimeFixtureKotlin :engine:writeRuntimeFixtureClasspath --console=plain)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
classes="$repo_root/engine/build/classes/kotlin/runtimeFixture"
find "$classes" -name '*.class' > "$work/classes.list"
set -- --release --min-api 21 --lib "$sdk_root/platforms/android-35/android.jar" \
    --classpath "$repo_root/engine/build/classes/kotlin/main"
while IFS= read -r entry; do
    [ -e "$entry" ] || continue # The daemon has no Java sources/output directory.
    set -- "$@" --classpath "$entry"
done < "$repo_root/engine/build/fixtures/kotlin/classpath.txt"
"$sdk_root/build-tools/37.0.0/d8" "$@" --output "$work" @"$work/classes.list"
printf '%s' '{"name":"KotlinAbi","pluginClassName":"fixture.KotlinAbiPlugin","version":1,"requiresResources":false}' > "$work/manifest.json"
output="$repo_root/engine/src/test/resources/extensions/kotlin-abi.cs3"
(cd "$work" && zip -X -q -D "$output" manifest.json classes*.dex)
echo "Rebuilt $output"
# RT-11: same DEX, WebViewResolver provider as the entry point.
printf '%s' '{"name":"WebView","pluginClassName":"fixture.WebViewPlugin","version":1,"requiresResources":false}' > "$work/manifest.json"
webview="$repo_root/engine/src/test/resources/extensions/webview.cs3"
rm -f "$webview"
(cd "$work" && zip -X -q -D "$webview" manifest.json classes*.dex)
echo "Rebuilt $webview"
# RT-14: same DEX, an extension-created android.webkit.WebView as the entry point.
printf '%s' '{"name":"AndroidWebView","pluginClassName":"fixture.AndroidWebViewPlugin","version":1,"requiresResources":false}' > "$work/manifest.json"
androidWebview="$repo_root/engine/src/test/resources/extensions/android-webview.cs3"
rm -f "$androidWebview"
(cd "$work" && zip -X -q -D "$androidWebview" manifest.json classes*.dex)
echo "Rebuilt $androidWebview"
# RT-17: same DEX, links to a local origin for the client's live playback test.
printf '%s' '{"name":"LocalMedia","pluginClassName":"fixture.LocalMediaPlugin","version":1,"requiresResources":false}' > "$work/manifest.json"
localMedia="$repo_root/engine/src/test/resources/extensions/local-media.cs3"
rm -f "$localMedia"
(cd "$work" && zip -X -q -D "$localMedia" manifest.json classes*.dex)
echo "Rebuilt $localMedia"
