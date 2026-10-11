# ADR-0002: progressive search uses NDJSON, not SSE

**Status:** Accepted

`/search/stream` streams one JSON event per line (`application/x-ndjson`)
instead of SSE: identical client ergonomics over `URLSession.bytes`, no extra
Ktor module, and graceful behavior behind proxies. Per-provider 5 s caps are
unchanged; events carry provider-level granularity.
