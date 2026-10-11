# Fact-check evidence

Read [FACT-CHECK.md](macos/docs/audit/extensions-repository/fact-check/FACT-CHECK.md) for the findings and the disposition of all 37 original audit entries.

The additional Kotlin probes are opt-in characterization tests. Eleven reproduce adverse behavior; one confirms that ordinary HTML aggregation filters out remote-down entries, contradicting part of original F33. They do not demonstrate correct or secure operation overall.

From the repository root:

```sh
./gradlew :macos:daemon:test --offline --console=plain --no-configuration-cache \
  -I macos/docs/audit/extensions-repository/audit.init.gradle \
  --tests com.lagradost.macos.FactCheckProbe

# Restore ordinary test configuration and outputs afterward.
./gradlew :macos:daemon:test --offline --console=plain
```

The existing init script recursively includes this directory. HTTP is intercepted; unrecognized requests fail. Lifecycle probes use harmless test-classpath plugins and synthetic warmed JAR caches, not actual DEX translation. The Context probe temporarily redirects `user.home` inside the isolated audit directory and restores it in `finally`; it does not access the real application data root. Do not run these singleton-mutating probes concurrently in one JVM.

JSON files and the compiler log are snapshots, not regenerated automatically by the commands. The ordinary suite was run last. Original report/probes/results remain unchanged.

The native check used `xcrun swiftc -typecheck -swift-version 6 -module-name CloudStream -target arm64-apple-macosx15.0`, all client Sources `.swift` files, the `mpv_bridge.h` bridging header, and the client include directory. It did not execute Xcode project build phases, launch the application, or replace the distributed app. This is a compiler diagnostic check, not a complete Xcode build or UI test.
