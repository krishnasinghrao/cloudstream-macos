// IPC JSON values mirrored by the engine (ipc-api.md, contract v6).

struct SolvePendingDto: Codable, Sendable, Identifiable {
    let taskId: String
    let targetUrl: String
    let ageMs: Int
    /// The challenged request's User-Agent; clearance only works with it.
    var userAgent: String? = nil

    var id: String { taskId }
}

/// A command for an extension's WebView session, from `GET /webview/pending`.
struct WebViewCommandDto: Codable, Sendable, Hashable {
    let commandId: String
    let session: String
    /// `load`, `eval` or `destroy`.
    let op: String
    var url: String? = nil
    var html: String? = nil
    var baseUrl: String? = nil
    var script: String? = nil
    var userAgent: String? = nil
    var interfaces: [String] = []
}

struct WebViewResultDto: Codable, Sendable, Hashable {
    let commandId: String
    var result: String? = nil
    var error: String? = nil
}

struct WebViewEventPayload: Codable, Sendable, Hashable {
    /// `finished` or `call`.
    let kind: String
    var url: String? = nil
    var name: String? = nil
    var method: String? = nil
    var args: [String] = []
}

struct WebViewEventDto: Codable, Sendable, Hashable {
    let session: String
    let event: WebViewEventPayload
}

struct MediaPendingDto: Codable, Sendable, Hashable {
    let taskId: String
    let url: String
    let method: String
    var headers: [String: String] = [:]
    var userAgent: String? = nil
    var script: String? = nil
    let timeoutMs: Int64
    let ageMs: Int64
}

struct MediaObservedRequestDto: Codable, Sendable, Hashable {
    let url: String
    let method: String
}

struct MediaObserveResponseDto: Codable, Sendable {
    let known: Bool
    let stop: Bool
}

struct MediaCompleteRequestDto: Codable, Sendable {
    let taskId: String
    let scriptResult: String?
    let cookies: [String: String]
    let userAgent: String?
    let pageUrl: String?
}
