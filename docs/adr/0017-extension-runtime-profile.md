# ADR 0017: Versioned extension runtime compatibility

Date: 1 October 2026. Status: accepted for implementation; release validation pending.

Android extensions execute DEX against the Android application. The macOS port translates that DEX and executes it against a smaller JVM host. The audit demonstrates that successful registration or search does not establish compatibility of title loading, settings, or extraction.

Keep the worker isolation in ADR 0016. Introduce descriptor-aware adaptation against trusted host definitions, worker-local initialization, functional Android/app helper adapters, and a versioned capability report. Unknown optional UI references are warnings; an actually reached required missing symbol is an operation failure. Empty stubs and rejection of required resources do not meet the compatibility objective.

Use typed errors with stage and request ownership across worker, daemon, and native client. Adopt IPC 5 for the coordinated contract change, explicitly version worker frames, and invalidate translations when the ABI/profile changes. Use CloudStream's 120-second default and provider hints clamped to 5–480 seconds, preserving progressive results and cancellation.

Native WebKit must separately support challenge solving and media resolution, including observed request events and worker-owned callback decisions. A spike must prove the requested capture behavior before the implementation is considered compatible. Extractor descriptors and dispatch must work independently of provider registration and across owning workers.

Positive Android-compiled fixtures, real worker execution, packaged startup/search/details/extraction, resource/settings fixtures, and actual synthetic media playback are release gates. The implementation plan remains open for any required affected-extension facility not covered by the named profile.

This decision supersedes the five-second provider timeout in Rules §4.3 for extension compatibility. It does not remove hard deadlines or resource bounds. See [implementation plan](../archive/plans/Extensions-Runtime-Implementation-Plan.md).
