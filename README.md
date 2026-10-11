<p align="center">
  <img src="Icons/Cloudstream%20MacOS%20icon.png" width="128" height="128" alt="CloudStream for macOS Logo" />
</p>

<h1 align="center">CloudStream for macOS</h1>

<p align="center">
  <strong>A high-performance, native media workstation for Apple Silicon Macs — bringing the CloudStream extension ecosystem to macOS without emulators.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2015.0%2B%20%7C%20Apple%20Silicon-black?logo=apple&style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&style=flat-square" alt="Swift 6" />
  <img src="https://img.shields.io/badge/Kotlin-JVM%2017-7F52FF?logo=kotlin&style=flat-square" alt="Kotlin 17" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-green.svg?style=flat-square" alt="License: GPL v3" /></a>
</p>

---

> **⚠️ Legal Notice:** CloudStream for macOS is a neutral indexing framework and media player. By default, it contains **zero video sources, media streams, or scraper providers**. All scraping logic is executed through optional, third-party community extensions installed solely at the user's discretion. See [DISCLAIMER.md](DISCLAIMER.md).

---

## Why CloudStream for macOS?

CloudStream is one of the most versatile, community-driven media aggregator tools on Android. Its true strength lies in its decentralized extension ecosystem: contributors constantly maintain providers, adjust to changing layouts, and resolve links effortlessly.

However, Mac users have historically been forced into a frustrating compromise:
* Running **heavyweight Android emulators** (BlueStacks, Android Studio AVD) that consume gigabytes of RAM, cause thermal throttling, drain laptop batteries, and introduce sluggish touch-oriented interfaces.
* Dealing with browser-based video hosts littered with intrusive popups, dropped frames, and poor subtitle rendering.

**My goal in building CloudStream for macOS was simple: to bring this fantastic tool to the Mac natively.**

By decoupling the engine into a headless background daemon that translates Android `.cs3` extension bytecode to Java 17, and pairing it with a native **Swift 6 / SwiftUI** desktop client with **Metal + libmpv** rendering, CloudStream for macOS provides an ultra-responsive, distraction-free workstation experience tailored for modern Apple Silicon hardware.

---

## App Showcase

### 🏠 Home & Library
The interface follows Apple’s modern desktop design language with fluid shelves, swift navigation, and local SwiftData persistence:

<p align="center">
  <img src="docs/screenshots/Home%20Page.png" width="95%" alt="CloudStream macOS Home Screen" />
</p>

---

### 🎬 Cinema-Grade Playback Engine
Embedded `libmpv` renders VideoToolbox-decoded frames into pooled IOSurfaces that Metal presents on a `CAMetalLayer` with full BT.2020 HDR10/HLG tone-mapping, stream diagnostics, audio-track selection, and styled subtitle rendering:

<p align="center">
  <img src="docs/screenshots/Full%20Screen%20Video%20Player.png" width="95%" alt="Full Screen Video Player" />
</p>

<p align="center">
  <img src="docs/screenshots/Video%20Player%20Image%201.png" width="48%" alt="Video Player Controls" />
  &nbsp;
  <img src="docs/screenshots/Video%20Player%20Image%202.png" width="48%" alt="Stream Info and Diagnostics" />
</p>

---

### 🧩 Decentralized Extensions & Native Settings
Easily add community repository URLs, browse extensions, and configure playback settings. Every extension runs in an isolated, sandboxed child JVM worker:

<p align="center">
  <img src="docs/screenshots/Extensions%20Page.png" width="55%" alt="Extensions Page" />
  &nbsp;
  <img src="docs/screenshots/Settings%20Menu.png" width="39%" alt="Settings Menu" />
</p>

---

## Key Features

* **⚡ Lightweight & Fast to Start:** Built to a 160 MB idle-memory budget and a 1.2 s engine-ready target (see [docs/Rules.md](docs/Rules.md)), a fraction of an Android emulator's footprint.
* **🎥 Metal + libmpv GPU Pipeline:** Hardware-accelerated decoding via Apple VideoToolbox directly to IOSurfaces with seamless SDR tone-mapping for 4K HDR streams.
* **🛡️ Sandboxed Extensions:** Third-party extensions run inside their own isolated JVM processes, confined by macOS native `sandbox-exec` profiles with restricted file and network access. See [docs/Security.md](docs/Security.md) for the threat model and its limits.
* **📥 Built-in Downloader:** Direct-to-disk automated HLS segment-stitching (`.m3u8` and `.mp4`) via bundled native `ffmpeg`.
* **🔄 Zero Mobile Tooling Needed:** The Kotlin engine runs on standard Java 17 and translates Android DEX bytecode to JVM bytecode dynamically—no Android SDK or emulators required.
* **🍎 Native macOS Integration:** Built with Swift 6 strict concurrency, fluid SwiftUI shelves, macOS Control Center / `NowPlaying` media key support, and local SwiftData offline library tracking.

---

## System Requirements

* **Architecture:** Apple Silicon Mac (M1 / M2 / M3 / M4 / Pro / Max / Ultra) — arm64 native.
* **Operating System:** macOS 15.0 Sequoia or newer.

---

## Installation

### Download Pre-built Disk Image

1. Head to the **[Releases](../../releases)** tab.
2. Download the latest `CloudStream.dmg`.
3. Open the `.dmg` and drag **CloudStream.app** into your `/Applications` folder.

> [!TIP]
> **macOS Gatekeeper First-Launch Note:**
> Because community open-source releases are ad-hoc signed, macOS may show a developer verification prompt on first launch. To clear this:
> * Either **Right-click** (or Control-click) `CloudStream.app` in Finder and select **Open**.
> * Or run this one-line command in Terminal:
>   ```bash
>   xattr -cr /Applications/CloudStream.app
>   ```

---

## Adding Extensions

1. Launch **CloudStream**.
2. Open **Settings** ($\text{Cmd} + ,$) $\rightarrow$ **Extensions** $\rightarrow$ **Add Repository**.
3. Paste a community repository manifest URL (standard CloudStream 3 / 4 repository links).
4. Install your desired providers. Each extension is sandboxed into an isolated worker process.

---

## Architecture Overview

CloudStream for macOS is engineered across three decoupled tiers:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   Native Client Tier (Swift 6)                         │
│  • Pure SwiftUI + SwiftData                                            │
│  • Metal + libmpv for 4K HDR hardware-accelerated playback             │
│  • Control Center & NowPlaying media integration                       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Authenticated Loopback (HTTP/NDJSON)
┌───────────────────────────────────▼────────────────────────────────────┐
│              Engine Control Plane (Headless Kotlin/JVM 17)             │
│  • Bundled minimal JRE (jlink OpenJDK 17 — no Java install required)   │
│  • Dynamic Android DEX -> JVM bytecode translation                     │
│  • Clean-room Android stubs (Context, SharedPreferences, org.json)     │
│  • Egress proxy, link resolver, and challenge solver                   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Stdin / Stdout Frame Pipes
┌───────────────────────────────────▼────────────────────────────────────┐
│              Worker Tier (Per-Extension Sandboxes)                     │
│  • Restricted by macOS native sandbox-exec profiles                    │
│  • Strict egress proxy (refuses private/LAN connections)               │
│  • Isolated memory limits & execution call deadlines                   │
└────────────────────────────────────────────────────────────────────────┘
```

For detailed specifications, see [docs/Architecture.md](docs/Architecture.md) and [docs/Security.md](docs/Security.md).

---

## Developer Quickstart

### Prerequisites
* Mac with Apple Silicon
* Xcode 26.0 or newer (Swift 6.2; the app uses macOS 26 APIs behind availability checks and still runs on macOS 15)
* [XcodeGen](https://github.com/yonaskolb/XcodeGen):
  ```bash
  brew install xcodegen
  ```
* JDK 17 (e.g., Eclipse Temurin 17 or Homebrew OpenJDK 17)

### Build and Run

```bash
# Full build: compiles daemon fat jar, bundles JRE, stages media, and builds Swift client
make build

# Launch the newly built app
make run
```

### Common Targets

| Command | Action |
| :--- | :--- |
| `make test` | Runs the complete test suite (Swift unit tests, engine tests, ABI check) |
| `make test-client` | Runs Xcode client unit and UI tests |
| `make test-engine` | Runs daemon unit, ABI, and sandbox isolation tests |
| `make test-library` | Verifies library ABI stability against `library/api/library.api` |
| `make package` | Builds and packages the signed disk image (`dist/CloudStream.dmg`) |
| `make clean` | Purges build outputs and DerivedData |

### Working in Xcode
The Xcode project is generated from `client/project.yml`:
```bash
cd client && xcodegen generate && open CloudStreamMac.xcodeproj
```

---

## Contributing & Community

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening pull requests.

* **AI Policy:** All automated or AI-assisted contributions must adhere to [AI-POLICY.md](AI-POLICY.md).
* **Security:** Review our threat model in [docs/Security.md](docs/Security.md) and report issues via [SECURITY.md](SECURITY.md).

---

## License & Attribution

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

* The extension library and scraper engine derive from the [recloudstream/cloudstream](https://github.com/recloudstream/cloudstream) project by Lagradost and contributors.
* CloudStream for macOS is an independent, community-driven desktop companion application and is not officially affiliated with or endorsed by the original Android CloudStream team.
