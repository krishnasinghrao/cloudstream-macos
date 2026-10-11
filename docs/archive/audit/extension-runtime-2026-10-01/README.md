# Reproducing the 1 October 2026 runtime audit

Start with [REPORT.md](macos/docs/audit/extension-runtime-2026-10-01/REPORT.md). No application source was changed. Passing characterization tests confirm failures in the current implementation.

Run the Kotlin probes from the repository root:

```sh
./gradlew --offline --no-configuration-cache --no-build-cache \
  -I macos/docs/audit/extension-runtime-2026-10-01/audit.init.gradle \
  :macos:daemon:test --tests com.lagradost.macos.RuntimeAuditProbe \
  --tests com.lagradost.macos.AndroidCompatibilityAuditProbe
```

The init script uses a dedicated `macos/daemon/build/tmp/runtime-audit-home`; it does not read or mutate production extension state. The probes use fake public-HTTPS repository documents and a real loopback Ktor server. There are thirteen characterization probes: eight original runtime probes and five Android follow-up probes. The resource test uses the repository's existing harmless DEX fixture and a signed fake catalog; it does not execute a community extension.

To repeat the 28-check follow-up run, also pass `--tests com.lagradost.macos.AndroidStubConformanceTest --tests com.lagradost.macos.PluginBridgeTest`. The result is saved in `android-probe-results.json`; passing unsupported-capability probes means those capabilities are still unsupported.

Read current public catalog metadata (requires network; does not install extensions):

```sh
python3 macos/docs/audit/extension-runtime-2026-10-01/catalog_probe.py
```

This overwrites `catalog-results.json` with the new observation. Use version control if retaining the original snapshot matters.

Inspect cached DEX artifacts without executing their classes (requires JDK 17 and the existing packaged daemon):

```sh
mkdir -p /private/tmp/cloudstream-runtime-audit/classes /private/tmp/cloudstream-runtime-audit/translated
javac -cp macos/dist/CloudStream.app/Contents/Resources/tools/daemon.jar \
  -d /private/tmp/cloudstream-runtime-audit/classes \
  macos/docs/audit/extension-runtime-2026-10-01/TranslateProbe.java \
  macos/docs/audit/extension-runtime-2026-10-01/HostMethodProbe.java \
  macos/docs/audit/extension-runtime-2026-10-01/AndroidAbiProbe.java
java -cp /private/tmp/cloudstream-runtime-audit/classes:macos/dist/CloudStream.app/Contents/Resources/tools/daemon.jar \
  TranslateProbe /private/tmp/cloudstream-runtime-audit/translated \
  "$HOME"/.cloudstream-macos/cache/sources/*.cs3
python3 macos/docs/audit/extension-runtime-2026-10-01/bytecode_probe.py \
  /private/tmp/cloudstream-runtime-audit/translated \
  macos/dist/CloudStream.app/Contents/Resources/tools/daemon.jar
java -cp /private/tmp/cloudstream-runtime-audit/classes:macos/dist/CloudStream.app/Contents/Resources/tools/daemon.jar \
  HostMethodProbe /private/tmp/cloudstream-runtime-audit/translated/*.jar
javap -cp macos/dist/CloudStream.app/Contents/Resources/tools/daemon.jar kotlin.Result
java -cp /private/tmp/cloudstream-runtime-audit/classes:macos/dist/CloudStream.app/Contents/Resources/tools/daemon.jar \
  AndroidAbiProbe /private/tmp/cloudstream-runtime-audit/translated/*.jar \
  > /private/tmp/cloudstream-runtime-audit/android-abi-current.json
```

The static missing-class list includes optional Android UI paths. A reference's absence alone does not prove that a particular provider operation executes that path. The report distinguishes runtime-confirmed failures from architectural limitations.

`android-abi-results.json` retains the follow-up scan with exact symbol descriptors and callers. `android-compatibility-evidence.json` contains cached manifests, the packaged Android class inventory, and selected CineStream startup instructions. No community extension class is loaded or initialized by these scanners; host reflection uses `Class.forName` with initialization disabled. F13–F15 in the report explain the startup dependency, intentional Android resource rejection, and partial Android capability surface.

`runtime-log-evidence.json` preserves only selected provider failures, with original log line numbers and UTC timestamps. `upstream-comparison.json` records exact public source URLs and hashes. `source-snapshot.json` records the local reviewed source and packaged JAR.

The repository Swift helper currently omits sources used by its tests. The audit verified the 19 existing tests in a temporary package with `ManagedExtensionPolicy.swift` and the actual `ExtensionVersion` declaration included; that did not modify the helper or app source.
