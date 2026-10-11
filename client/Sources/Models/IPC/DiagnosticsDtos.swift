// IPC JSON values mirrored by the engine (ipc-api.md, contract v6).

struct ProviderStatDto: Codable, Sendable, Hashable, Identifiable {
    let provider: String
    let success: Int
    let failure: Int
    let lastError: String?
    let lastLatencyMs: Int
    var id: String { provider }

    /// nil until the provider was used at all.
    var successRate: Double? {
        let total = success + failure
        return total > 0 ? Double(success) / Double(total) : nil
    }
}

struct EndpointStatDto: Codable, Sendable, Hashable {
    let endpoint: String
    let requests: Int
    let errors: Int
}

struct DiagnosticsDto: Codable, Sendable {
    let uptimeMs: Int
    let requestsServed: Int
    let endpoints: [EndpointStatDto]
    let providers: [ProviderStatDto]
    let solveTasksCreated: Int
    let solveTasksSolved: Int
}

struct ProviderTestRequestDto: Encodable, Sendable {
    let providers: [String]
    let query: String?
}

struct ProviderTestStepDto: Codable, Sendable, Hashable {
    let name: String
    let ok: Bool
    let latencyMs: Int?
    let detail: String?
}

struct ProviderTestResultDto: Codable, Sendable, Hashable, Identifiable {
    let provider: String
    let status: String
    let steps: [ProviderTestStepDto]
    var id: String { provider }
}

struct ProviderTestEventDto: Codable, Sendable {
    let type: String
    let result: ProviderTestResultDto?
    let total: Int?
}
