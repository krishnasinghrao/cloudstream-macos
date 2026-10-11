# Project Roadmap & Milestones: CloudStream macOS

> **Superseded (4 October 2026).** This app is a personal build for the owner's own Macs: notarization, the Intel DMG and the public-release milestones below are out of scope. The single list of open work is [Remaining-Work.md](../../Remaining-Work.md).


## 1. Phased Development Roadmap

The project is structured into **5 sequential phases**, progressing from low-level scraper engine verification to media pipeline construction, native Apple TV SwiftUI design execution, and final notarized release packaging.

```mermaid
gantt
    title CloudStream macOS Delivery Timeline
    dateFormat  YYYY-MM-DD
    section Phase 1: Engine Core
    Kotlin Daemon & :library link        :done, 2026-10-01, 2d
    Android API Mock Layer (Stubs)       :active, 2026-10-03, 1d
    dex2jar Bridge with Bytecode Cache   : 2026-10-04, 2d
    Ktor IPC Server & Bearer Auth        : 2026-10-06, 1d
    section Phase 2: Media Workers
    CAMetalLayer libmpv Player Bridge    : 2026-10-07, 2d
    ffmpeg Downloader with JIT Resolver  : 2026-10-09, 2d
    WKWebView Anti-Bot Clearance Bridge  : 2026-10-11, 1d
    section Phase 3: Apple TV SwiftUI
    Frosted Sidebar & Clean Chrome Shell : 2026-10-12, 2d
    Dedicated Search View & History      : 2026-10-14, 2d
    16:9 Continue Watching & Library     : 2026-10-16, 2d
    Floating Glass Player HUD Overlay    : 2026-10-18, 2d
    Downloads Table & SwiftData State    : 2026-10-20, 2d
    section Phase 4: Hardening
    Failover Engine & URL Sanitizer      : 2026-10-22, 1d
    Resource Budget & Memory Audit       : 2026-10-23, 1d
    section Phase 5: Packaging
    jlink Stripped JRE Assembly          : 2026-10-24, 1d
    Hardened Runtime & DMG Notarization  : 2026-10-25, 2d
```

---

## 2. Detailed Phase Breakdown & Deliverables

### Phase 1: Headless Kotlin Daemon & Plugin Engine
* **Goal:** Prove that CloudStream's `:library` can execute on pure macOS OpenJDK, load a community `.cs3` plugin, search a query, and return stream links via authenticated JSON IPC.
* **Key Tasks:**
  * Configure `engine` Gradle build linking to root `:library`.
  * Implement `AndroidStubs.kt` providing pure Java implementations of `android.content.Context`, `android.util.Base64`, `android.util.Log`, and `android.net.Uri`.
  * Implement `PluginBridge.kt` using `dex2jar` to convert `.dex` to `.jar`, caching converted jars by SHA-256 hash.
  * Build the Ktor embedded server with bearer token authentication on `127.0.0.1:<port>`.
* **Exit Criteria:**
  * Terminal test: Calling `curl -H "Authorization: Bearer <token>" "http://127.0.0.1:54321/search?q=batman"` successfully returns raw JSON search results from an active CloudStream plugin without Android runtime crashes.

---

### Phase 2: Media Processing & Anti-Bot Bridges
* **Goal:** Establish reliable, line-speed downloading and hardware-accelerated streaming with header spoofing and JIT link resolution.
* **Key Tasks:**
  * Bundle universal `ffmpeg` CLI binary into `client/Resources/Binaries/`.
  * Implement `MpvPlayerView.swift` integrating `libmpv` with `CAMetalLayer` and `mpv_render_context` (`MPV_RENDER_API_TYPE_METAL`) for zero-copy Apple Silicon GPU decoding.
  * Implement `DownloadService.swift` with **Just-In-Time Link Resolution** so video host tokens are resolved immediately before download starts, avoiding HTTP 403 expiration during batch season downloads.
  * Build `WebViewSolverService.swift`: Offscreen `WKWebView` to capture `cf_clearance` cookies and solve Cloudflare challenges.
* **Exit Criteria:**
  * A test `.m3u8` stream from a protected video host downloads losslessly to `~/Downloads` without `403 Forbidden` errors.
  * The video plays smoothly in a floating test `libmpv` window with Metal acceleration and zero dropped frames.

---

### Phase 3: Native Apple TV SwiftUI Interface (Swift 6 & SwiftUI 6)
* **Goal:** Build the complete visual experience uniting CloudStream's exact UI architecture with Apple TV macOS HIG styling using Apple's latest toolkits (Xcode 16+, Swift 6, SwiftUI 6).
* **Key Tasks:**
  * Configure Xcode project with **Swift 6 language mode** and strict complete concurrency checking (`SWIFT_STRICT_CONCURRENCY = complete`).
  * Construct the `NavigationSplitView` with frosted sidebar implementing CloudStream's 5 core tabs (`Home`, `Search`, `Library`, `Downloads`, `Settings`) and official `WatchType` library categories (`Watching`, `Plan to Watch`, `Completed`, `On Hold`, `Dropped`).
  * Build the **Home View** featuring active provider switcher, "Resume Watching" shelf (16:9 cards with progress bars), and dynamic provider homepage carousels using `.scrollClipDisabled()` and `.scrollTargetBehavior(.viewAligned)`.
  * Build the **Dedicated Search View** with native query field, `MeshGradient` ambient category cards, and parallel multi-provider poster grid.
  * Build the **Media Details View** (`ResultFragment` flow) with Play/Resume button, Watch status dropdown, Dub/Sub toggle, Season selector, and Episode rows with Play, Download, and Mirrors picker.
  * Build the **Floating Glass Player HUD** with timeline scrubber, transport controls, audio track popover, styled subtitle settings, and episode drawer.
  * Integrate **macOS System Media**: Hook `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for Control Center and keyboard media keys, and `AVPictureInPictureController` for native PiP.
  * Build the **Downloads View** with downloaded titles list, active download queue table, speed/ETA calculations, and disk space meter.
  * Implement **SwiftData** persistence models (`StoredMediaItem`).
* **Exit Criteria:**
  * Full end-to-end user flow working visually: Browse Provider / Search -> View Details -> Bookmark / Pick Mirror -> Stream in Metal Player or Download via JIT Downloader.

---

### Phase 4: "Fort Knox" Security & Performance Hardening
* **Goal:** Ensure the application is completely leak-proof, resilient, and respects resource budgets.
* **Key Tasks:**
  * Implement `URLSanitizer.kt` to strip all tracking parameters (`utm_*`, affiliate redirects).
  * Add automatic server failover: if Server 1 returns 404/403, immediately try Server 2 without user interruption.
  * Validate RAM usage under 160 MB and daemon startup under 1,200 ms.
* **Exit Criteria:**
  * Network sniffer confirms zero outgoing telemetry packets and strictly local loopback IPC traffic.

---

### Phase 5: Self-Contained App Packaging & Release
* **Goal:** Produce a zero-dependency, double-clickable `.dmg` installer signed and notarized by Apple Gatekeeper.
* **Key Tasks:**
  * Run `bundle_runtime.sh` with `jlink` to assemble a minimal OpenJDK runtime (~35 MB) containing only required modules (`java.base`, `java.net.http`, `java.sql`, etc.).
  * Package the Swift `.app` bundle including the JRE, `daemon.jar`, `ffmpeg`, and `libmpv`.
  * Configure **Hardened Runtime** entitlements (`com.apple.security.cs.allow-jit`, etc.).
  * Create release automation script `package_app.sh` generating signed and notarized `.dmg` images for both Apple Silicon (`arm64`) and Intel (`x86_64`).
* **Exit Criteria:**
  * Installing the `.dmg` on a fresh macOS machine with no Java or Developer Tools installed launches instantly and functions 100% out of the box with zero Gatekeeper warnings.
