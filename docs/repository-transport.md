# Repository transport and ingestion contract

Implemented in `RepositoryTransport`, `RepositoryContentFetcher`, `RepositoryJson`, and `RepositoryService`. This is one part of the active remediation; it does not establish plugin execution isolation or authenticate detached catalog lists.

Repository requests use a dedicated OkHttp client. They do not inherit the mutable provider client, provider interceptors, global cookies, cached responses, authenticators, or system proxy. Normal TLS certificate and hostname checks remain enabled. HTTPS is required on every request, redirect, and resolved catalog/artifact reference: a plain-HTTP address (typed by the user, in a catalog, or in a redirect) is read as its HTTPS form, and a host without HTTPS fails; nothing is ever fetched over HTTP. Embedded credentials and fragments are rejected by the transport. User-supplied navigation fragments are removed before establishing repository identity.

DNS answers are checked by the resolver actually used for connection establishment. Mixed public/restricted answers are rejected as a whole. Literal IP addresses get the same check because OkHttp can bypass DNS for them. The conservative policy allows ordinary public addresses and rejects loopback, private, link-local, multicast, unspecified, documentation, benchmarking and transition-address ranges. The policy was checked against the [IANA IPv4 registry](https://www.iana.org/assignments/iana-ipv4-special-registry/) and [IANA IPv6 registry](https://www.iana.org/assignments/iana-ipv6-special-registry/). Private/intranet repositories and proxies currently have no supported opt-in exception.

Each fetch has a 60-second coroutine deadline, including waiting for a permit and any challenge solve. Individual HTTP calls have a 30-second timeout, with 10-second connect and 15-second read limits. Cancellation calls OkHttp cancellation and removes pending challenge tasks. Two concurrent fetch permits and a dedicated two-thread executor with an eight-item queue bound request execution, including native DNS work that may not be interruptible immediately. Redirects are followed manually, with cycle detection and a five-hop limit. Only final HTTP 200 responses become documents.

The client requests identity encoding and rejects unexpected content encoding. It enforces declared and streamed byte limits, including responses without Content-Length. Limits are:

| Resource | Limit |
|---|---:|
| Root manifest or discovery document | 2 MiB |
| Combined plugin-list bytes per repository | 8 MiB |
| Source artifact | 32 MiB |
| Codeberg API decoded payload | 2 MiB; larger content uses bounded raw HTTPS fallback |
| Plugin lists per repository | 16 |
| Extensions per repository/aggregate | 10,000 |
| Discovery links per page / total visited repositories | 32 / 64 |
| Discovery nesting / full sync deadline | 3 levels below root / 120 seconds |
| JSON nesting / total nodes / array elements / object members | 32 / 100,000 / 10,000 / 256 |
| JSON keys / ordinary string values | 256 / 65,536 UTF-16 code units |

UTF-8 decoding fails on malformed bytes. Structural validation runs before general JSON tree decoding and before root signature verification. It rejects duplicate decoded keys, including escaped aliases, invalid Unicode, nonstandard JSON syntax, oversized structure and oversized strings. The Codeberg adapter permits a separately bounded base64 string.

Relative lists resolve against the root response's final URL; relative artifacts and icons resolve against the list response's final URL. A single unusable entry never fails its repository: a malformed entry is left out, a later duplicate identity yields to the first, an icon that is unusable or names a private-network literal address is dropped, and an entry whose download address is unusable stays listed but cannot be installed. Entries are read with Android's leniency (unknown keys ignored, a null or quoted value for a defaulted field accepted). Codeberg contents-API responses retain the logical raw-file URL as their resolution base. Its previous public API compatibility marker is restricted to the exact Codeberg HTTPS origin and contents-API path and is rebuilt per redirect; it is not publisher authentication. Cached solver cookies are selected separately for each destination origin.

Known aliases are explicit. Unknown shortcode path case is preserved. Wrapped `cs.repo` query extraction only applies to that exact hostname. Migration/dead-repository rules match their expected host and owner/repository path, rather than arbitrary substrings in unrelated URLs.

Verification uses a local HTTPS server and a temporary certificate to exercise actual redirects, headers, streaming bodies, TLS rejection, cancellation, and cookie isolation. Integration fixtures check final-URL resolution, parser identity, bounded Codeberg decoding and discovery cycles. Live community repository compatibility, maximum-size memory pressure under the packaged JVM, challenged requests with user-agent-bound cookies, atomic aggregate commits, and isolated execution remain open release gates.
