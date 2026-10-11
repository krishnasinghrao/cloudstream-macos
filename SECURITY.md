# Security Policy

## Reporting Security Vulnerabilities

We take the security of CloudStream for macOS seriously. Because this application processes third-party community extensions and media streams from untrusted web endpoints, maintaining strict isolation is a core priority.

If you believe you have found a security vulnerability (such as a sandbox escape, IPC token leak, credential disclosure, or denial of service), please **do not report it in public GitHub issues**.

Instead, please report security vulnerabilities via **GitHub Private Vulnerability Reporting** on this repository, or contact the maintainers directly through private channels.

---

## Security Model & Guarantees

For a detailed explanation of the threat model, trust boundaries, worker isolation profiles, and security invariants (SEC-01 through SEC-10), please read:

👉 [**docs/Security.md**](docs/Security.md)

### Key Security Invariants:
* **Per-Extension Worker Sandboxing:** Third-party `.cs3` plugins run in isolated child JVM processes restricted by macOS sandbox profiles (`sandbox-exec`).
* **Filesystem Isolation:** Extension workers have write access exclusively to their own private cache directories (`~/.cloudstream-macos/workers/<id>`) and cannot access user files, documents, or other extensions.
* **Ephemeral IPC:** Communication between the native Swift UI and the Kotlin daemon uses loopback (`127.0.0.1`) authenticated with an ephemeral, cryptographic 32-byte bearer token generated anew each launch.
* **Zero Telemetry:** Zero external telemetry, crash tracking, or advertising SDKs.
