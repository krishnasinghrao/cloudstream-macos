# ADR-0006: plugin removal semantics

**Status:** Accepted

Removal = `beforeUnload()` + registry deregistration + classloader close +
persistent removal mark. JVM class unloading is best-effort (leaked statics
can pin classes until restart); the plugin disappears from all endpoints
immediately and boot-from-cache skips removed hashes. The UI may prompt for a
daemon restart when full memory reclamation matters.
