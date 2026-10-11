// IPC JSON values mirrored by the engine (ipc-api.md, contract v6).

struct ResolverOptionDto: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let label: String
}

struct NetworkSettingsDto: Codable, Sendable, Equatable {
    var dns: String
    var customDohUrl: String?
    var httpCacheMb: Int
    var retryOnNetworkError: Bool
    /// Download GitHub-hosted repositories through jsDelivr (N2). Nil from an
    /// older engine, which then keeps its own value when this is sent back.
    var githubMirror: Bool? = nil
    /// Response only.
    var resolvers: [ResolverOptionDto] = []
    /// Response only.
    var cacheSizeBytes: Int64 = 0
}

struct ConnectivityTestRequestDto: Encodable, Sendable {
    let providers: [String]
}

struct ConnectivityResultDto: Codable, Sendable, Hashable, Identifiable {
    let provider: String
    let url: String
    let reachable: Bool
    let status: Int?
    let latencyMs: Int?
    let error: String?

    var id: String { provider + "|" + url }
}
