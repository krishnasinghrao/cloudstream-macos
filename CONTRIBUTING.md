# Contributing to CloudStream for macOS

Thank you for your interest in contributing to **CloudStream for macOS**!

CloudStream for macOS is an open-source native media workstation designed for Apple Silicon Macs. We welcome bug reports, documentation improvements, and pull requests.

---

## 1. Code of Conduct & AI Policy

All contributors must respect community members and adhere to our [AI Policy](AI-POLICY.md):
1. **Disclose AI Usage:** Disclose AI assistance in commit messages and PR descriptions.
2. **Empirical Verification:** Always compile and test locally (`make test`) before opening a pull request.
3. **Understand Your Code:** You must be able to explain and defend all submitted changes.

---

## 2. Project Architecture

The repository is organized into three decoupled tiers:

* `client/`: Native macOS frontend written in **Swift 6 (strict concurrency)** and **SwiftUI**. Renders video through a `CAMetalLayer` with embedded `libmpv` and manages local library state with **SwiftData**.
* `engine/`: Headless **Kotlin/JVM 17** daemon (`daemon.jar`). Runs a local Ktor loopback HTTP/NDJSON service, bridges `.cs3` extension bytecode via dynamic DEX-to-JVM translation, and coordinates background workers.
* `library/`: The CloudStream extension API (`MainAPI`, extractors, HTTP layer) compiled for plain Kotlin/JVM.
* `scripts/`: Tooling for runtime bundling (`jlink`), media stack staging, DMG packaging, and signature validation.
* `docs/`: Comprehensive architecture specifications, security threat models, and Architecture Decision Records (ADRs).

---

## 3. Development Prerequisites

* **Hardware:** Apple Silicon Mac (M1/M2/M3/M4) running macOS 15.0 Sequoia or newer.
* **Xcode:** Xcode 26.0 or newer (full Xcode installation). CI builds with Xcode 26.3.
* **XcodeGen:** Install via Homebrew:
  ```bash
  brew install xcodegen
  ```
* **Java Development Kit:** JDK 17 (e.g., Eclipse Temurin 17 or Homebrew OpenJDK 17).
* **Media Build Tools (Optional for local dev):** `mpv` and `ffmpeg` can be installed via Homebrew for local testing, or built from source using `scripts/build_media_stack.sh`.

---

## 4. Building and Testing

All common workflows are handled through the root `Makefile`:

```bash
# Build the entire application (daemon fat jar + jlink runtime + Xcode release build)
make build

# Launch the built application
make run

# Run all test suites (Swift unit tests, engine tests, library ABI check)
make test

# Run isolated component tests
make test-client        # Xcode client unit & UI tests
make test-engine        # Engine tests
make test-library       # Extension library ABI stability check

# Package as a disk image (dist/CloudStream.dmg)
make package

# Clean build artifacts
make clean
```

### Working in Xcode
The Xcode project is generated from `client/project.yml`. Do not edit `.xcodeproj` files directly:
```bash
cd client
xcodegen generate
open CloudStreamMac.xcodeproj
```

---

## 5. Non-Negotiable Invariants

All pull requests must respect the project's security and performance invariants:

1. **Loopback Only (SEC-01):** The engine daemon strictly binds to `127.0.0.1`.
2. **Ephemeral Bearer Authentication (SEC-02):** Daemon IPC is guarded by a 32-byte cryptographic random token generated at launch.
3. **Zero Telemetry (SEC-03):** No external tracking, analytics, or remote logging SDKs.
4. **Swift 6 Concurrency:** No data races. Strict concurrency checking is enabled.
5. **No Built-in Piracy Scrapers:** Never submit PRs containing default streaming provider URLs or scrapers into the core repository.

For questions, open a GitHub Discussion or submit an Issue.
