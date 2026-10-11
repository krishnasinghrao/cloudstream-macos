# Engineering & Security Rules: CloudStream macOS

## 1. Compliance with Project AI Policy
All code contributions and automated tools must strictly adhere to CloudStream’s root [AI-POLICY.md](https://github.com/recloudstream/cloudstream/blob/master/AI-POLICY.md):
1. **Declare AI Usage:** Always disclose AI-assisted code generation in commit messages and pull requests.
2. **Empirical Verification:** Never commit AI-generated code without verified compilation, local test execution, and end-to-end testing.
3. **Architectural Understanding:** You must be able to explain, debug, and justify every architectural pattern, function, and configuration file submitted.
4. **Human Review Priority:** Maintainer instructions and community feedback supersede automated suggestions at all times.

---

## 2. "Fort Knox" Security & Integrity Invariants (Non-Negotiable)

### 2.1 Network & Isolation Invariants
* **Invariant SEC-01 (Loopback Binding Only):** The Kotlin scraper daemon must strictly bind to `127.0.0.1`. Binding to `0.0.0.0` or any external network interface is strictly prohibited.
* **Invariant SEC-02 (Mandatory Ephemeral Authentication):** Every internal IPC HTTP endpoint (except `/health`) must require the `Authorization: Bearer <token>` header. The token must be generated via secure cryptographic random bytes on each app startup and never written to persistent disk.
* **Invariant SEC-03 (Zero Telemetry & Analytics):** No third-party analytics SDKs, crash trackers, or telemetry beacons (Firebase, Sentry, Mixpanel, Google Analytics) are permitted. All debugging logs remain strictly local.
* **Invariant SEC-04 (URL Sanitization Gate):** All scraped URLs must pass through the `URLSanitizer` before being loaded by `libmpv` or `ffmpeg`. Tracking query parameters (`utm_*`, `fbclid`, `aff_id`, `track_*`) must be stripped.

### 2.2 Security Architecture & Distribution Invariants
* **Invariant SEC-05 (Hardened Runtime & Gatekeeper Notarization):** Because the app bundles companion binaries (`ffmpeg` and a stripped JRE `java`), distribution uses Apple’s **Hardened Runtime** with strict Developer ID Notarization rather than the restrictive Mac App Store sandbox. Outbound networking is allowed for scraping; user disk writes are strictly confined to the user-chosen download directory.
* **Invariant SEC-06 (Scraper Filesystem Restriction):** The Kotlin JVM daemon must never have write access to general user directories. Its file operations are restricted to its sandboxed application cache (`~/.cloudstream-macos/cache`) for plugin bytecode and manifest caching.
* **Invariant SEC-07 (Cryptographic Plugin Verification):** No plugin (`.cs3`) may be loaded into memory without first verifying its SHA-256 checksum against the repository’s signed `repo.json` manifest.
* **Invariant SEC-08 (Android Mock / Stub Isolation):** The daemon must provide a dedicated, pure-Java Android API Mock Layer on the JVM classpath (`Context`, `Base64`, `Log`, `Uri`) to ensure community `.cs3` plugins execute reliably without throwing `NoClassDefFoundError`.

---

## 3. Performance & Resource Budgets (Production Reality)

To ensure this application remains an ultra-lightweight desktop alternative to bloated emulators, all contributions must respect the following hard performance budgets:

| Metric | Hard Budget Limit | Measurement Condition |
| :--- | :--- | :--- |
| **Instant UI Launch** | `< 200 ms` | App click to fully rendered SwiftUI UI shell (cached library) |
| **Daemon Ready Time** | `< 1,200 ms` | From launch to first successful IPC `/health` response |
| **Total Memory (RAM)** | `< 160 MB` | Combined RAM of Swift App + JRE Daemon + libmpv (Idle) |
| **Idle CPU Usage** | `< 0.5%` | App in background or idling on Search screen |
| **4K Playback CPU** | `< 2.5%` | `libmpv` streaming 4K HEVC with Metal hardware decoding |
| **Download CPU Overhead**| `< 1.0%` | `ffmpeg` running `-c copy` at >50 MB/s download speed |
| **Uncompressed App Bundle** | `< 180 MB` | Total `.app` bundle (SwiftUI + stripped JRE + mpv + ffmpeg) |
| **Compressed DMG Installer** | `< 95 MB` | Final `.dmg` release artifact for distribution |

---

## 4. Code Architecture & Modularity Standards

### 4.1 Swift 6 & Xcode 26+ Standards (Apple's Latest Toolkits)
* **Toolchain & Language Mode:** Target **Xcode 26+** with **Swift 6 language mode**. Strict concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`) is enforced. Code must be 100% data-race safe with complete `@MainActor`, `Sendable`, and actor isolation.
* **Modern State & Persistence:** Use Apple's **Observation framework** (`@Observable`) for UI state and **SwiftData** (`@Model`, `@Query`, `ModelContainer`) for local library and history persistence. Legacy `ObservableObject`, `@Published`, and Core Data `.xcdatamodeld` are strictly forbidden.
* **SwiftUI Shelves & Feedback (as implemented):**
  - **Fluid Shelves:** shelves are plain `ScrollView` + `LazyHStack`; cards highlight on hover with a background/border change (no scale jump to clip — `.scrollClipDisabled()` is therefore not needed). `.scrollTargetBehavior(.viewAligned)` snapping is not used.
  - **Dynamic Atmosphere:** category/search cards use semantic system colors (`Color.cardSurface`, `Color.hoverFill` — ADR-0010); `MeshGradient` is not used.
  - **Micro-Animations:** hover state changes animate via `withAnimation`/`.animation`; `.symbolEffect(.bounce/.pulse)` is not used.
* **macOS System Media Integration:**
  - **Control Center & Media Keys:** Integrate with `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` so hardware keyboard media keys (Play/Pause, Seek, Next) and macOS Control Center widgets sync seamlessly with `libmpv`.
  - **Picture-in-Picture:** per [ADR-0004](adr/0004-pip-scope.md), PiP is a detachable floating mini-window hosting the Metal viewport — `AVPictureInPictureController` is not usable with mpv's render API.
* **Rendering:** per [ADR-0019](adr/0019-gpu-render-bridge.md), video renders through `CAMetalLayer` + `mpv_render_context`. The default OpenGL context draws into IOSurfaces shared with Metal; the software context is the fallback. VideoToolbox keeps hardware decoding. OpenGL usage stays confined to the C bridge required by libmpv's render API.

### 4.2 Kotlin JVM Daemon Standards
* **Pure JVM Runtime:** The daemon runs on standard OpenJDK 17+, using CloudStream's `:library` multiplatform target.
* **Coroutines & Non-Blocking I/O:** Every search, scrape, and link extraction call must run on `Dispatchers.IO` using structured concurrency.
* **Reflection & Classloader Isolation:** Plugin loading via `URLClassLoader` must be wrapped in strong exception barriers (`safeAsync`, `try-catch`) so that a malformed or broken plugin never crashes the daemon.
* **Bytecode Cache:** Pre-transpiled `.jar` files from `.cs3` must be cached by SHA-256 hash to eliminate redundant conversions.

### 4.3 Resilience & Fallback Rules
* **Provider Timeout:** Any search provider that fails to respond within **5.0 seconds** must be automatically cancelled and bypassed. Search results from faster providers must stream in progressively without waiting for slow ones.
* **Failover on Stream Errors:** If a resolved video server returns `404 Not Found` or `403 Forbidden`, the engine must automatically failover to the next available server link in the list without prompting the user with an error dialog.
* **Process Recovery:** If the Kotlin daemon process exits unexpectedly, `DaemonSupervisor` in Swift must automatically restart the daemon and re-establish the IPC connection without restarting the macOS application.
* **Just-In-Time Link Resolution:** For download queues, stream links must be resolved dynamically at the moment downloading begins to prevent HTTP 403 expiration on batch jobs.
