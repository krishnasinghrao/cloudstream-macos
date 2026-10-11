import Foundation

/// Actor-isolated HTTP client for the loopback daemon IPC channel
/// (Architecture.md §2.1). Every call carries the ephemeral bearer token
/// (SEC-02); responses are decoded into the values in Models/IPC/.
///
/// Contract v6 (ipc-api.md): POST /links with a JSON body, NDJSON
/// `/search/stream` for progressive results, solve-task polling for the
/// anti-bot bridge, and an ipcVersion handshake on connect.
actor DaemonClient {
    static let shared = DaemonClient()

    struct Endpoint: Sendable {
        let port: Int
        let token: String
    }

    enum DaemonError: LocalizedError, Sendable {
        case notReady
        case badURL(String)
        case badResponse
        case ipcVersionMismatch(found: Int)
        case appLocked
        case http(statusCode: Int, detail: String?)
        /// Typed extension failure (IPC v4); `message` is user-presentable.
        case extensionFailure(code: String, message: String)
        case operationFailure(OperationFailureDto)
        /// An NDJSON stream closed before its `done` event (audit M1).
        case streamEnded
        /// The listener could not prove it holds this launch's token (audit M1).
        case untrustedEngine

        var errorDescription: String? {
            switch self {
            case .notReady: return "Daemon is not running"
            case .badURL(let path): return "Malformed IPC path: \(path)"
            case .badResponse: return "Malformed daemon response"
            case .appLocked: return "Application is locked"
            case .ipcVersionMismatch(let found):
                return "Daemon IPC version \(found) does not match client version \(HealthDto.expectedIpcVersion) — update CloudStream"
            // A 422 carries a sentence written for the user (provider unavailable).
            case .http(422, let detail?):
                return detail
            case .http(let statusCode, let detail):
                return "Daemon returned \(statusCode)\(detail.map { ": \($0)" } ?? "")"
            case .extensionFailure(_, let message):
                return message
            case .operationFailure(let failure):
                return failure.publicMessage
            case .streamEnded:
                return "The engine stopped before it finished. Try again."
            case .untrustedEngine:
                return "Couldn't confirm the engine's identity. Restart CloudStream."
            }
        }

        /// Stable error code for typed failures (e.g. "consent_required").
        var code: String? {
            if case .appLocked = self { return "locked" }
            if case .extensionFailure(let code, _) = self { return code }
            if case .operationFailure(let failure) = self { return failure.code }
            return nil
        }
    }

    private var endpoint: Endpoint?

    /// Updated by AppState when the supervisor reports a (re)spawned daemon.
    func updateEndpoint(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    func clearEndpoint() {
        endpoint = nil
    }

    /// Connects and validates the IPC version handshake. The engine proves it
    /// holds the token; the token itself is not sent to /health (audit M1).
    /// Throws on version mismatch, an unproven listener or daemon unavailability.
    func connectAndVerify() async throws -> HealthDto {
        guard let endpoint else { throw DaemonError.notReady }
        guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/health") else { throw DaemonError.badURL("health") }
        let nonce = EngineHealthProbe.makeNonce()
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(nonce, forHTTPHeaderField: EngineHealthProbe.nonceHeader)
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, data: data)
        let health = try JSONDecoder().decode(HealthDto.self, from: data)
        guard EngineHealthProbe.matches(health.proof, expected: EngineHealthProbe.proof(token: endpoint.token, nonce: nonce)) else {
            throw DaemonError.untrustedEngine
        }
        guard health.ipcVersion == HealthDto.expectedIpcVersion else {
            throw DaemonError.ipcVersionMismatch(found: health.ipcVersion)
        }
        return health
    }

    /// Engine traffic uses its own cacheless, cookieless, proxy-free pool (audit A1, M3).
    nonisolated static var session: URLSession { EngineTransport.ipcSession }

    // MARK: - Public API

    func repos() async throws -> [RepositoryDto] {
        try await get("repos")
    }

    func importLegacyRepositories(_ urls: [String]) async throws {
        struct Import: Encodable { let urls: [String] }
        struct ImportResponse: Decodable { let status: String }
        let _: ImportResponse = try await post("repos/import", body: Import(urls: urls))
    }

    /// Ordinary repeatable registration (backup restore). Records addresses
    /// only: nothing is synced, installed or trusted.
    func registerRepositories(_ urls: [String]) async throws -> [RepoRegistrationDto] {
        struct Register: Encodable { let urls: [String] }
        return try await post("repos/register", body: Register(urls: urls))
    }

    static func normalizeRepoUrl(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\'<>[]()"))

        // Strip markdown links if present: [Title](URL)
        if let match = url.range(of: #"(?<=]\()[^\)]+"#, options: .regularExpression) {
            url = String(url[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip HTML links if present: <a href="URL">
        if let match = url.range(of: #"(?<=href=["'])[^\s"']+"#, options: .regularExpression) {
            url = String(url[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let customSchemes = [
            "cloudstreamrepo://", "cloudstreamrepo:",
            "cloudstream://", "cloudstream:",
            "cs.repo://", "cs.repo:",
            "cs3://", "cs3:",
            "cloudstreamapp://"
        ]
        for scheme in customSchemes {
            if url.lowercased().hasPrefix(scheme) {
                url = String(url.dropFirst(scheme.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        if url.contains("cs.repo") && url.contains("url=") {
            // String parse, not URLComponents: the unprefixed form
            // ("cs.repo/url=https://…") parses ambiguously and drops the query.
            if let range = url.range(of: #"url=(https?://[^&\s]+)"#, options: .regularExpression) {
                url = String(url[range]).dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if url.hasPrefix("http://") {
            url = "https://" + url.dropFirst("http://".count)
        } else if !url.hasPrefix("https://") && (url.contains(".") || url.contains("/")) {
            url = "https://" + url
        }

        return url
    }

    func syncRepo(_ repoUrl: String, installAll: Bool = false) async throws -> RepositoryDto {
        let normalized = Self.normalizeRepoUrl(repoUrl)
        return try await post("repos/sync", body: ReposSyncRequestDto(repoUrl: normalized, installAll: installAll))
    }

    func repoPlugins(_ repoUrl: String) async throws -> [RepoPluginDto] {
        try await get("repos/plugins", queryItems: [URLQueryItem(name: "repoUrl", value: repoUrl)])
    }

    func removeRepo(_ repoUrl: String, deleteDownloadedPlugins: Bool = true) async throws {
        let _: Acknowledgement = try await post(
            "repos/remove",
            body: RepoRemoveRequestDto(repoUrl: repoUrl, deleteDownloadedPlugins: deleteDownloadedPlugins)
        )
    }

    func plugins() async throws -> [PluginDto] {
        try await get("plugins")
    }

    func installPlugin(repoUrl: String, internalName: String, pluginUrl: String, fileHash: String? = nil) async throws -> PluginDto {
        try await post(
            "plugins/install",
            body: PluginInstallRequestDto(
                repoUrl: repoUrl,
                internalName: internalName,
                pluginUrl: pluginUrl,
                fileHash: fileHash
            )
        )
    }

    func uninstallPlugin(_ installationId: String) async throws {
        let _: Acknowledgement = try await post("plugins/uninstall", body: InstallationRequestDto(installationId: installationId))
    }

    /// Extension-level enable state (IPC v4: installation ID).
    func setPluginEnabled(_ installationId: String, enabled: Bool) async throws -> PluginDto {
        try await post("plugins/setEnabled", body: PluginEnabledRequestDto(installationId: installationId, enabled: enabled))
    }

    func updatePlugin(_ installationId: String) async throws -> PluginDto {
        try await post("plugins/update", body: InstallationRequestDto(installationId: installationId))
    }

    func updateAllPlugins(repoUrl: String? = nil) async throws -> [UpdateResultDto] {
        try await post("plugins/updateAll", body: UpdateAllRequestDto(repoUrl: repoUrl))
    }

    func rollbackPlugin(_ installationId: String) async throws -> PluginDto {
        try await post("plugins/rollback", body: InstallationRequestDto(installationId: installationId))
    }

    func retryPlugin(_ installationId: String) async throws -> PluginDto {
        try await post("plugins/retry", body: InstallationRequestDto(installationId: installationId))
    }

    func setRepositoryConsent(_ repoUrl: String, allow: Bool) async throws -> RepositoryDto {
        try await post("repos/consent", body: RepoConsentRequestDto(repoUrl: repoUrl, allow: allow))
    }

    func reTrustRepository(_ repoUrl: String) async throws -> RepositoryDto {
        struct Body: Encodable { let repoUrl: String }
        return try await post("repos/trust", body: Body(repoUrl: repoUrl))
    }

    func extensionSettings() async throws -> ExtensionSettingsDto {
        try await get("extensions/settings")
    }

    func setAutoUpdate(_ enabled: Bool) async throws -> ExtensionSettingsDto {
        try await post("extensions/settings", body: ExtensionSettingsUpdateDto(autoUpdate: enabled))
    }

    func setDeveloperMode(_ enabled: Bool) async throws -> ExtensionSettingsDto {
        try await post("extensions/settings", body: ExtensionSettingsUpdateDto(developerMode: enabled))
    }

    /// Developer mode: imports a local `.cs3` the user picked (never enabled automatically).
    func installExtensionFile(path: String) async throws -> PluginDto {
        try await post("extensions/developer/install", body: DeveloperInstallRequestDto(path: path))
    }

    func dismissLegacyExtensions() async throws -> ExtensionSettingsDto {
        try await post("extensions/legacy/dismiss", body: EmptyBody())
    }

    func providerInfo() async throws -> [ProviderInfoDto] {
        try await get("providers")
    }

    /// Every provider (including disabled ones) with its stable ID.
    func allProviders() async throws -> [ProviderInfoDto] {
        try await get("providers/all")
    }

    /// Name-based convenience for data without IDs (Android backups, diagnostics):
    /// applies to every provider currently registered under that name.
    func setProviderEnabled(named name: String, enabled: Bool) async throws {
        for provider in try await allProviders() where provider.name == name {
            try await setProviderEnabled(providerId: provider.providerId ?? provider.name, enabled: enabled)
        }
    }

    func setProviderEnabled(providerId: String, enabled: Bool) async throws {
        let _: Acknowledgement = try await post("providers/setEnabled", body: ProviderEnabledRequestDto(providerId: providerId, enabled: enabled))
    }

    /// Clone-site / credential override. Credentials are held in memory by the
    /// engine only; the caller keeps them in the Keychain.
    func configureProvider(_ request: PluginConfigRequestDto) async throws -> PluginConfigResponseDto {
        try await post("plugins/config", body: request)
    }

    func home(provider: String, page: Int = 1) async throws -> HomePageDto {
        try await get("home", queryItems: [
            URLQueryItem(name: "plugin", value: provider),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    /// Progressive search over NDJSON: each provider has a 5 s barrier.
    nonisolated func searchStream(_ query: String, plugins: [String]? = nil) -> AsyncThrowingStream<SearchStreamEventDto, Error> {
        eventStream(path: "search/stream") { client, continuation in
            var queryItems = [URLQueryItem(name: "q", value: query)]
            if let plugins, !plugins.isEmpty {
                queryItems.append(URLQueryItem(name: "plugins", value: plugins.joined(separator: ",")))
            }
            let request = try await client.makeRequest("search/stream", queryItems: queryItems)
            let (bytes, response) = try await Self.session.bytes(for: request)
            try Self.validate(response, data: nil)
            try await Self.requireDone(Self.consumeEvents(bytes.lines, into: continuation) { $0.type == "done" })
        }
    }

    /// - Parameter refresh: bypass the daemon's 10-minute details cache (⌘R).
    func details(provider: String, url: String, refresh: Bool = false) async throws -> DetailsDto {
        var items = [
            URLQueryItem(name: "plugin", value: provider),
            URLQueryItem(name: "url", value: url),
        ]
        if refresh { items.append(URLQueryItem(name: "refresh", value: "1")) }
        return try await get("details", queryItems: items)
    }

    /// Resolves stream links for an episode/movie data string (POST body —
    /// episode data can be multi-KB). Links arrive pre-sorted by quality
    /// (daemon-side failover order) and sanitized (SEC-04).
    func links(provider: String, data: String) async throws -> LinksResponseDto {
        try await post("links", body: LinksRequestDto(plugin: provider, data: data))
    }

    /// Runs the daemon's extractors on one URL (trailers).
    func extract(url: String, referer: String?) async throws -> LinksResponseDto {
        try await post("extract", body: ExtractRequestDto(url: url, referer: referer))
    }

    /// Starts the provider's `extractorVerifierJob` for a link that carries
    /// `extractorData` (Android download parity: some hosts expire a link
    /// unless it is kept alive while in use). Returns the daemon job ID.
    func startExtractorVerifier(source: String, extractorData: String) async throws -> String? {
        let response: VerifierStartResponseDto = try await post(
            "links/verify/start",
            body: VerifierStartRequestDto(source: source, extractorData: extractorData)
        )
        return response.jobId
    }

    /// Stops a verifier job; failures are irrelevant (the daemon also caps
    /// every job's lifetime).
    func stopExtractorVerifier(jobId: String) async {
        let _: Acknowledgement? = try? await post("links/verify/stop", body: VerifierStopRequestDto(jobId: jobId))
    }

    /// A registered set of relayed resources: `urls` are loopback addresses in
    /// request order, valid until the session is revoked or the engine exits.
    struct MediaRelaySession: Sendable, Equatable {
        let sessionID: String
        let urls: [String]
    }

    /// Registers the resources of one split stream so each is fetched with
    /// its own headers (audit A35).
    func registerMediaRelay(_ resources: [MediaRelayResourceDto]) async throws -> MediaRelaySession {
        guard let endpoint else { throw DaemonError.notReady }
        let response: MediaRelayResponseDto = try await post("media/relay", body: MediaRelayRequestDto(resources: resources))
        guard response.paths.count == resources.count,
              response.paths.allSatisfy({ $0.hasPrefix("/media/relay/") && $0.dropFirst(13).allSatisfy(\.isHexDigit) }) else {
            await revokeMediaRelay(sessionID: response.sessionId)
            throw DaemonError.badResponse
        }
        return MediaRelaySession(sessionID: response.sessionId, urls: response.paths.map { "http://127.0.0.1:\(endpoint.port)\($0)" })
    }

    /// Failures are irrelevant: the engine also expires idle sessions.
    func revokeMediaRelay(sessionID: String) async {
        let _: Acknowledgement? = try? await post("media/relay/revoke", body: MediaRelayRevokeRequestDto(sessionId: sessionID))
    }

    /// One provider-test result as each finishes (`POST /test/run`).
    nonisolated func providerTestStream(providers: [String] = [], query: String? = nil) -> AsyncThrowingStream<ProviderTestEventDto, Error> {
        eventStream(path: nil) { client, continuation in
            let body = try JSONEncoder().encode(ProviderTestRequestDto(providers: providers, query: query))
            let request = try await client.makeRequest("test/run", body: body)
            let (bytes, response) = try await Self.session.bytes(for: request)
            try Self.validate(response, data: nil)
            try await Self.requireDone(Self.consumeEvents(bytes.lines, into: continuation) { $0.type == "done" })
        }
    }

    /// Progressive link resolution over NDJSON `POST /links/stream`.
    /// Engines without this endpoint (404/405) fall back to batch `/links`.
    nonisolated func linksStream(provider: String, data: String) -> AsyncThrowingStream<LinksStreamEventDto, Error> {
        eventStream(path: "links/stream") { client, continuation in
            let body = try JSONEncoder().encode(LinksRequestDto(plugin: provider, data: data))
            let request = try await client.makeRequest("links/stream", body: body)
            let (bytes, response) = try await Self.session.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 405 {
                let batch = try await client.links(provider: provider, data: data)
                for link in batch.links {
                    continuation.yield(LinksStreamEventDto(type: "link", link: link, subtitle: nil, error: nil))
                }
                for subtitle in batch.subtitles {
                    continuation.yield(LinksStreamEventDto(type: "subtitle", link: nil, subtitle: subtitle, error: nil))
                }
                continuation.yield(LinksStreamEventDto(type: "done", link: nil, subtitle: nil, error: nil))
                return
            }
            try Self.validate(response, data: nil)
            try await Self.requireDone(Self.consumeEvents(bytes.lines, into: continuation) { $0.type == "done" })
        }
    }

    // MARK: - Anti-bot solve bridge

    /// - Parameter waitMs: hold the request until a challenge is parked or
    ///   this long passes (the engine caps it at 25 s): a long poll.
    func pendingSolves(waitMs: Int = 0) async throws -> [SolvePendingDto] {
        try await get("solve/pending", queryItems: waitMs > 0 ? [URLQueryItem(name: "waitMs", value: "\(waitMs)")] : [])
    }

    func submitSolve(taskId: String, targetUrl: String?, cookies: String) async throws {
        let _: Acknowledgement = try await post(
            "solve-callback",
            body: ["taskId": taskId, "targetUrl": targetUrl as String?, "cookies": cookies]
        )
    }

    // MARK: - Native JavaScript media resolution (plan RT-11)

    /// - Parameter waitMs: long poll, as for `pendingSolves`.
    func pendingMedia(waitMs: Int = 0) async throws -> [MediaPendingDto] {
        try await get("media/pending", queryItems: waitMs > 0 ? [URLQueryItem(name: "waitMs", value: "\(waitMs)")] : [])
    }

    // MARK: - Diagnostics and network settings

    func diagnostics() async throws -> DiagnosticsDto {
        try await get("diagnostics")
    }

    func networkSettings() async throws -> NetworkSettingsDto {
        try await get("settings/network")
    }

    func updateNetworkSettings(_ settings: NetworkSettingsDto) async throws -> NetworkSettingsDto {
        try await post("settings/network", body: settings)
    }

    func clearHTTPCache() async throws -> NetworkSettingsDto {
        try await post("settings/network/clearCache", body: EmptyBody())
    }

    func testConnectivity(providers: [String] = []) async throws -> [ConnectivityResultDto] {
        try await post("network/test", body: ConnectivityTestRequestDto(providers: providers))
    }

    // MARK: - Plumbing

    /// Captures the endpoint once so URL and token always belong to one launch.
    private func makeRequest(_ path: String, queryItems: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard let endpoint else { throw DaemonError.notReady }
        guard var components = URLComponents(string: "http://127.0.0.1:\(endpoint.port)/\(path)") else {
            throw DaemonError.badURL(path)
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw DaemonError.badURL(path) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Owns producer completion and cancellation for every NDJSON endpoint.
    /// A nil path preserves provider diagnostics' passive demand accounting.
    nonisolated private func eventStream<Event: Decodable & Sendable>(
        path: String?,
        produce: @escaping @Sendable (DaemonClient, AsyncThrowingStream<Event, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let demand = path.map(EngineDemand.begin)
                defer { demand?.end() }
                do {
                    try await produce(self, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields every decodable event line; true when the stream's `done` event
    /// arrived. A stream that closes without it is incomplete (audit M1).
    nonisolated static func consumeEvents<Event: Decodable & Sendable, Lines: AsyncSequence>(
        _ lines: Lines,
        into continuation: AsyncThrowingStream<Event, Error>.Continuation,
        isDone: @Sendable (Event) -> Bool
    ) async throws -> Bool where Lines.Element == String {
        let decoder = JSONDecoder()
        // Whole lines preserve multi-byte UTF-8 across arbitrary TCP chunks.
        for try await line in lines {
            guard !Task.isCancelled else { return false }
            guard !line.isEmpty,
                  let event = try? decoder.decode(Event.self, from: Data(line.utf8)) else { continue }
            continuation.yield(event)
            if isDone(event) { return true }
        }
        return false
    }

    /// A stream that ended without `done` is an error unless the consumer cancelled it.
    nonisolated static func requireDone(_ sawDone: Bool) throws {
        guard sawDone || Task.isCancelled else { throw DaemonError.streamEnded }
    }

    private struct Acknowledgement: Decodable {
        let status: String?
    }

    private struct EmptyBody: Encodable {}

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let demand = EngineDemand.begin(path)
        defer { demand.end() }
        let request = try makeRequest(path, queryItems: queryItems)
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(
        _ path: String,
        body: B
    ) async throws -> T {
        let demand = EngineDemand.begin(path)
        defer { demand.end() }
        let request = try makeRequest(path, body: JSONEncoder().encode(body))
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Redacted engine support bundle (`/diagnostics/export`) as raw JSON.
    func diagnosticsExport() async throws -> Data {
        let request = try makeRequest("diagnostics/export")
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    nonisolated static func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw DaemonError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 423 { throw DaemonError.appLocked }
            if let typed = data.flatMap({ try? JSONDecoder().decode(ExtensionErrorDto.self, from: $0) }) {
                throw DaemonError.extensionFailure(code: typed.code, message: typed.error)
            }
            let errorObj = data.flatMap { try? JSONDecoder().decode(ErrorResponseDto.self, from: $0) }
            if errorObj?.error == "locked" { throw DaemonError.appLocked }
            if let failure = errorObj?.failure { throw DaemonError.operationFailure(failure) }
            let detail = errorObj?.detail ?? errorObj?.error ?? data.flatMap { String(data: $0, encoding: .utf8) }
            throw DaemonError.http(statusCode: http.statusCode, detail: detail)
        }
    }

    // MARK: - App lock synchronization (SEC-08)

    func setAppLock(locked: Bool) async throws -> AppLockResponseDto {
        try await post("lock", body: AppLockRequestDto(locked: locked))
    }
}

extension DaemonClient: MediaResolveClient {
    func observeMedia(taskId: String, requests: [MediaObservedRequestDto]) async throws -> MediaObserveResponseDto {
        try await post("media/observe", body: MediaObserveRequest(taskId: taskId, requests: requests))
    }

    func completeMedia(_ request: MediaCompleteRequestDto) async throws {
        let _: Acknowledgement = try await post("media/complete", body: request)
    }

    private struct MediaObserveRequest: Encodable {
        let taskId: String
        let requests: [MediaObservedRequestDto]
    }
}

extension DaemonClient: WebViewSessionClient {
    /// Long poll, as for `pendingSolves`.
    func pendingWebViewCommands(waitMs: Int = 0) async throws -> [WebViewCommandDto] {
        try await get("webview/pending", queryItems: waitMs > 0 ? [URLQueryItem(name: "waitMs", value: "\(waitMs)")] : [])
    }

    func completeWebView(_ result: WebViewResultDto) async throws {
        let _: Acknowledgement = try await post("webview/complete", body: result)
    }

    func reportWebView(_ event: WebViewEventDto) async throws {
        let _: Acknowledgement = try await post("webview/event", body: event)
    }
}

extension DaemonClient: ExtensionPreferencesClient {
    func extensionPreferences(installationId: String) async throws -> ExtensionPreferencesDto {
        try await get("plugins/preferences", queryItems: [URLQueryItem(name: "installationId", value: installationId)])
    }

    func updateExtensionPreferences(installationId: String, updates: [ExtensionPreferenceUpdateDto]) async throws -> ExtensionPreferencesDto {
        struct Body: Encodable { let installationId: String; let updates: [ExtensionPreferenceUpdateDto] }
        return try await post("plugins/preferences", body: Body(installationId: installationId, updates: updates))
    }
}
