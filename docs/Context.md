# Context & Vision: CloudStream macOS

## 1. Executive Summary
**CloudStream macOS** is a high-performance, native media workstation for Apple Mac computers (Apple Silicon & Intel). It extracts the robust, community-maintained scraping and streaming engine of CloudStream—an open-source Android media aggregator—and brings it to macOS as an ultra-fast, lightweight, "Fort Knox" secure desktop utility.

Rather than porting the entire mobile application (which includes phone-centric touch interfaces, social voting, account synchronizations, and discovery feeds), this project isolates what desktop power users care about most:
1. **Universal Search:** Fast, simultaneous querying across community-maintained provider extensions.
2. **Lossless Line-Speed Downloader:** Automated segment-stitching and direct-to-disk downloading (`.m3u8` and `.mp4`) via native `ffmpeg`.
3. **Flawless Playback:** Embedded hardware-accelerated streaming via `libmpv` with full audio track and styled subtitle support.
4. **Local Library Management:** Distraction-free, local title organization (*Watching*, *Plan to Watch*, *Completed*, *On Hold*, *Dropped*).
5. **Apple TV Design Language:** A bespoke, cinematic macOS SwiftUI interface following Apple’s frosted glass and ambient dark design system.

---

## 2. Background & Problem Statement

### 2.1 The Current State of CloudStream
CloudStream (specifically CloudStream 3 / 4) is one of the most widely adopted open-source Android media streaming applications. Its strength lies entirely in its **decentralized extension ecosystem**:
* Over 100+ community extensions (e.g., Hexated, English providers, Anime scrapers, IPTV, LibriVox) are constantly maintained by open-source contributors.
* When streaming websites change their DOM layouts, anti-bot scripts, or video player hosts, extension authors update their repositories within days.
* The application itself contains **zero pirated or copyrighted media by default**; it acts strictly as an extensible indexing and playback framework.

### 2.2 The Desktop Dilemma
Desktop users wanting to access CloudStream on macOS currently face two major roadblocks:
1. **Heavyweight Android Emulators (BlueStacks, Android Studio AVD):**
   * Emulators require 3.5 GB to 5.0 GB of RAM.
   * They trigger heavy CPU virtualization, destroying laptop battery life and causing thermal throttling.
   * Commercial emulators frequently bundle intrusive advertisements, telemetry, and background tracking services.
2. **Unfinished Compose Multiplatform Desktop Port:**
   * The official repository includes a `:desktopApp` target, but it is currently in an early skeleton state (`Main.kt` renders only a basic test layout).
   * Migrating the massive Android-specific `:app` codebase (fragments, Jetpack lifecycles, ExoPlayer dependencies, Android `Context`) to Compose Desktop is a multi-year effort that remains incomplete.

### 2.3 The Architectural Precedent: The Tachidesk / Suwayomi Model
This exact scenario occurred with **Tachiyomi** (the premier Android manga reader). When desktop users wanted Tachiyomi on macOS/PC without emulators, the community did not wait for a full Android UI rewrite. Instead, they built **Tachidesk (Suwayomi)**:
* They extracted Tachiyomi’s scraper engine to run on standard Java/JVM as a headless background process.
* They exposed a local API on `localhost`.
* They built native or lightweight web/desktop frontends on top.

**CloudStream macOS** applies this battle-tested architectural paradigm to video streaming and downloading.

---

## 3. Product Vision & Principles

### Principle 1: The "Fort Knox" Security Posture
Free streaming hosts and video mirrors are fraught with aggressive ad networks, fingerprinting scripts, tracking pixels, and malicious redirects.
* The macOS app **never runs a browser context directly on untrusted pages**.
* The scraper engine strips away 100% of website DOM/scripts and extracts solely the raw video manifests (`.m3u8` or `.mp4`).
* Zero outgoing telemetry, zero user tracking, and strictly local SwiftData storage.
* Sandboxed filesystem permissions: writes occur only to the user-selected download directory.

### Principle 2: "Build Once, Run Indefinitely"
* No maintenance burden on scrapers: The app consumes official `.cs3` community repositories directly. As scrapers are updated by the community, the app seamlessly pulls the latest plugin versions.
* Native binaries (`ffmpeg`, `libmpv`, Kotlin runtime) are statically bundled with pinned SHA-256 hashes, requiring no internet downloads of executables.

### Principle 3: Desktop-First Workstation Ergonomics
* We eliminate the mobile "Discover / Recommendations" dashboard and account login hurdles.
* Instant cold startup (< 1 second).
* Keyboard shortcuts (Space for pause, `Cmd+F` for search, Left/Right for seek, `Cmd+D` for download).
* Deep macOS system integration (Finder reveal, native notifications on download completion, system menu bar controls, Dark Mode vibrancy).

---

## 4. Target Personas

### Persona A: The Archival Collector / Offline Traveler
* **Profile:** Wants high-quality movies and complete TV/anime seasons stored locally for flights, commutes, or local Plex/Jellyfin libraries.
* **Pain Point:** Web downloaders are filled with popups, fake download buttons, and broken chunk downloads. Android phone storage is cramped.
* **Goal:** Search a show, select "Download Season (1080p)", and get perfectly named `.mp4` files with embedded English subtitles saved directly to `~/Movies`.

### Persona B: The Distraction-Free Streamer
* **Profile:** Wants to watch media at their Mac desk with a high-end display (Retina / Liquid Retina XDR / Studio Display).
* **Pain Point:** Browser streaming players suffer from dropped frames, poor scaling algorithms, and ugly subtitle rendering.
* **Goal:** Click an episode and immediately stream in a clean, floating Apple TV-style window powered by `libmpv` and Apple Metal hardware acceleration.
