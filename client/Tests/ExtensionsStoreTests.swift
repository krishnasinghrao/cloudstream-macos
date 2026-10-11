import XCTest
@testable import CloudStream

private actor ExtensionAPIFixture: ExtensionsAPI {
    private var testResults: [ProviderTestResultDto] = []
    private(set) var testedProviders: [String] = []
    func setTestResults(_ results: [ProviderTestResultDto]) { testResults = results }
    func testProviders(_ providerIds: [String]) async throws -> [ProviderTestResultDto] { testedProviders = providerIds; return testResults }
    var repositories: [RepositoryDto] = []
    var installed: [PluginDto] = []
    var failReads = false
    var syncCount = 0
    var removed: [String] = []
    var heldCatalogs: [String: CheckedContinuation<[RepoPluginDto], any Error>] = [:]
    var catalogWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    var heldRefresh: CheckedContinuation<[RepositoryDto], any Error>?
    var refreshWaiter: CheckedContinuation<Void, Never>?
    var holdRefresh = false
    var settings = ExtensionSettingsDto()
    func configure(settings: ExtensionSettingsDto) { self.settings = settings }

    func configure(repositories: [RepositoryDto], failReads: Bool = false) {
        self.repositories = repositories
        self.failReads = failReads
    }
    func pauseRefresh() { holdRefresh = true }
    func waitForRefresh() async {
        if heldRefresh != nil { return }
        await withCheckedContinuation { refreshWaiter = $0 }
    }
    func finishRefresh(_ values: [RepositoryDto]) { heldRefresh?.resume(returning: values); heldRefresh = nil }
    func repos() async throws -> [RepositoryDto] {
        if holdRefresh {
            holdRefresh = false
            return try await withCheckedThrowingContinuation {
                heldRefresh = $0
                refreshWaiter?.resume(); refreshWaiter = nil
            }
        }
        if failReads { throw URLError(.notConnectedToInternet) }
        return repositories
    }
    func plugins() async throws -> [PluginDto] {
        if failReads { throw URLError(.notConnectedToInternet) }
        return installed
    }
    func repoPlugins(_ repoUrl: String) async throws -> [RepoPluginDto] {
        try await withCheckedThrowingContinuation {
            heldCatalogs[repoUrl] = $0
            catalogWaiters.removeValue(forKey: repoUrl)?.resume()
        }
    }
    func waitForCatalog(_ url: String) async {
        if heldCatalogs[url] != nil { return }
        await withCheckedContinuation { catalogWaiters[url] = $0 }
    }
    func finishCatalog(_ url: String, values: [RepoPluginDto]) {
        heldCatalogs.removeValue(forKey: url)?.resume(returning: values)
    }
    func syncRepo(_ repoUrl: String, installAll: Bool) async throws -> RepositoryDto {
        XCTAssertFalse(installAll)
        syncCount += 1
        let repo = repository(repoUrl)
        repositories.removeAll { $0.url == repoUrl }
        repositories.append(repo)
        return repo
    }
    func removeRepo(_ repoUrl: String, deleteDownloadedPlugins: Bool) async throws {
        removed.append(repoUrl)
        repositories.removeAll { $0.url == repoUrl }
    }
    func installPlugin(repoUrl: String, internalName: String, pluginUrl: String, fileHash: String?) async throws -> PluginDto {
        throw URLError(.unsupportedURL)
    }
    var enabledCalls: [String: Bool] = [:]
    var heldToggle: CheckedContinuation<Void, Never>?
    var toggleWaiter: CheckedContinuation<Void, Never>?
    var holdToggle = false
    var nextError: Error?

    func uninstallPlugin(_ installationId: String) async throws {
        installed.removeAll { $0.id == installationId }
    }
    func setPluginEnabled(_ installationId: String, enabled: Bool) async throws -> PluginDto {
        if let error = nextError { nextError = nil; throw error }
        if holdToggle {
            holdToggle = false
            await withCheckedContinuation { heldToggle = $0; toggleWaiter?.resume(); toggleWaiter = nil }
        }
        enabledCalls[installationId] = enabled
        return plugin(installationId, enabled: enabled)
    }
    func waitForToggle() async {
        if heldToggle != nil { return }
        await withCheckedContinuation { toggleWaiter = $0 }
    }
    func releaseToggle() { heldToggle?.resume(); heldToggle = nil }
    func pauseToggle() { holdToggle = true }
    func fail(with error: Error) { nextError = error }
    func configureInstalled(_ plugins: [PluginDto]) { installed = plugins }
    func updatePlugin(_ installationId: String) async throws -> PluginDto { plugin(installationId) }
    func updateAllPlugins(repoUrl: String?) async throws -> [UpdateResultDto] {
        [UpdateResultDto(installationId: "a", name: "A", error: nil), UpdateResultDto(installationId: "b", name: "B", error: "boom")]
    }
    func rollbackPlugin(_ installationId: String) async throws -> PluginDto { plugin(installationId) }
    func retryPlugin(_ installationId: String) async throws -> PluginDto { plugin(installationId) }
    func setRepositoryConsent(_ repoUrl: String, allow: Bool) async throws -> RepositoryDto { repository(repoUrl) }
    func reTrustRepository(_ repoUrl: String) async throws -> RepositoryDto { repository(repoUrl) }
    func extensionSettings() async throws -> ExtensionSettingsDto { settings }
    func setAutoUpdate(_ enabled: Bool) async throws -> ExtensionSettingsDto { ExtensionSettingsDto(autoUpdate: enabled) }
    func dismissLegacyExtensions() async throws -> ExtensionSettingsDto { ExtensionSettingsDto() }
    var importedPaths: [String] = []
    func setDeveloperMode(_ enabled: Bool) async throws -> ExtensionSettingsDto {
        settings.developerMode = enabled
        return settings
    }
    func installExtensionFile(path: String) async throws -> PluginDto {
        importedPaths.append(path)
        throw URLError(.cannotOpenFile)
    }
}

private func plugin(_ id: String, enabled: Bool = true) -> PluginDto {
    PluginDto(id: id, name: id, internalName: id, version: 1, apiVersion: 1, language: nil, description: nil,
              authors: [], tvTypes: [], iconUrl: nil, repositoryUrl: nil, mainUrl: nil, fileSize: 0, sha256: nil,
              providers: ["P"], enabled: enabled, verified: true, lastError: nil, state: enabled ? "running" : "disabled")
}

private func repository(_ url: String) -> RepositoryDto {
    RepositoryDto(name: url, url: url, description: nil, iconUrl: nil, manifestVersion: 1,
                  pluginCount: 1, status: "ok", error: nil, verified: false, keyFingerprint: nil)
}

private func entry(_ repo: String, name: String) -> RepoPluginDto {
    RepoPluginDto(id: name, name: name, internalName: name, version: 1, apiVersion: 1,
                  url: "\(repo)/plugin.cs3", repositoryUrl: repo, description: nil, authors: [],
                  tvTypes: [], language: nil, iconUrl: nil, fileSize: nil, fileHash: nil,
                  status: 1, isInstalled: false, isUpdateAvailable: false)
}

@MainActor
final class ExtensionsStoreTests: XCTestCase {
    func testRefreshIsReadOnlyAndRetainsLastGoodSnapshotOffline() async {
        let api = ExtensionAPIFixture()
        let saved = repository("https://saved.invalid/repo.json")
        await api.configure(repositories: [saved])
        let store = ExtensionsStore(api: api)
        let loaded = await store.refresh()
        XCTAssertTrue(loaded)
        await api.configure(repositories: [], failReads: true)
        let offline = await store.refresh()
        XCTAssertFalse(offline)
        XCTAssertEqual(store.repositories, [saved])
        XCTAssertNotNil(store.refreshError)
        let syncs = await api.syncCount
        XCTAssertEqual(syncs, 0)
    }

    func testBackgroundUpdatesAreAnnouncedOncePerEngineRefresh() async {
        let defaults = UserDefaults(suiteName: "ExtensionsStoreTests.\(UUID().uuidString)")!
        let api = ExtensionAPIFixture()
        let store = ExtensionsStore(api: api, defaults: defaults)
        var announced: [[String]] = []
        store.notifyAutoUpdates = { announced.append($0) }
        var settings = ExtensionSettingsDto()
        settings.lastBackgroundRefresh = BackgroundRefreshDto(at: 1_000, repositories: 1, syncFailures: 0, updated: ["Alpha", "Beta"])
        await api.configure(settings: settings)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(announced, [["Alpha", "Beta"]])
        settings.lastBackgroundRefresh = BackgroundRefreshDto(at: 2_000, repositories: 1, syncFailures: 0, updated: [])
        await api.configure(settings: settings)
        await store.refresh()
        XCTAssertEqual(announced.count, 1, "a refresh without updates posts nothing")
    }

    func testAddAndRemoveUseDaemonRegistryWithoutResyncingRemovedRepository() async {
        let api = ExtensionAPIFixture()
        let store = ExtensionsStore(api: api)
        let url = "https://new.invalid/repo.json"
        let added = await store.addRepository(url)
        XCTAssertTrue(added)
        XCTAssertEqual(store.repositories.map(\.url), [url])
        await store.removeRepository(repository(url))
        await store.refresh()
        XCTAssertTrue(store.repositories.isEmpty)
        let syncs = await api.syncCount
        XCTAssertEqual(syncs, 1)
        let removals = await api.removed
        XCTAssertEqual(removals, [url])
    }

    func testOldEngineResponseCannotPublishAfterReconnect() async {
        let api = ExtensionAPIFixture()
        let store = ExtensionsStore(api: api)
        await api.pauseRefresh()
        let old = Task { await store.refresh() }
        await api.waitForRefresh()
        store.engineChanged()
        let current = repository("https://current.invalid/repo.json")
        await api.configure(repositories: [current])
        await store.refresh()
        await api.finishRefresh([repository("https://old.invalid/repo.json")])
        _ = await old.value
        XCTAssertEqual(store.repositories, [current])
        XCTAssertFalse(store.isRefreshing)
    }

    func testOlderCatalogCannotOverwriteNewSelection() async {
        let api = ExtensionAPIFixture()
        let catalog = RepositoryCatalogStore(api: api)
        let a = Task { await catalog.load(repoURL: "A") }
        await api.waitForCatalog("A")
        let b = Task { await catalog.load(repoURL: "B") }
        await api.waitForCatalog("B")
        await api.finishCatalog("B", values: [entry("B", name: "same")])
        await b.value
        await api.finishCatalog("A", values: [entry("A", name: "same")])
        await a.value
        XCTAssertEqual(catalog.plugins.map(\.repositoryUrl), ["B"])
        XCTAssertFalse(catalog.isLoading)
    }

    func testCancelledCatalogDoesNotPublishItsResponse() async {
        let api = ExtensionAPIFixture()
        let catalog = RepositoryCatalogStore(api: api)
        let request = Task { await catalog.load(repoURL: "A") }
        await api.waitForCatalog("A")
        request.cancel()
        await api.finishCatalog("A", values: [entry("A", name: "cancelled")])
        await request.value
        XCTAssertTrue(catalog.plugins.isEmpty)
        XCTAssertNil(catalog.error)
        XCTAssertFalse(catalog.isLoading)
    }

    func testCatalogIdentityIncludesRepositoryAndPreservesCase() {
        XCTAssertNotEqual(entry("https://repo.invalid/A", name: "Same").catalogID,
                          entry("https://repo.invalid/a", name: "Same").catalogID)
    }
    func testMissingOrDeniedInstallationPolicyBlocksTheClientAction() async {
        let store = ExtensionsStore(api: ExtensionAPIFixture())
        var plugin = entry("https://policy.invalid", name: "Fixture")
        await store.install(plugin)
        XCTAssertEqual(store.operationError, "Sync this repository to verify that installation is allowed.")
        plugin.installationAllowed = false
        plugin.installationBlockedReason = "A signed catalog is required."
        await store.install(plugin)
        XCTAssertEqual(store.operationError, "A signed catalog is required.")
        XCTAssertTrue(store.pluginActivities.isEmpty)
    }


    func testDifferentExtensionsToggleConcurrentlyButOneExtensionIsSerialized() async {
        let api = ExtensionAPIFixture()
        await api.configureInstalled([plugin("a"), plugin("b")])
        let store = ExtensionsStore(api: api)
        await store.refresh()
        await api.pauseToggle()
        let first = Task { await store.setEnabled(false, plugin: plugin("a")) }
        await api.waitForToggle()
        XCTAssertTrue(store.isBusy("a"))
        await store.setEnabled(false, plugin: plugin("a"))
        XCTAssertNotNil(store.operationError, "the same extension cannot run two operations at once")
        store.operationError = nil
        await store.setEnabled(false, plugin: plugin("b"))
        XCTAssertNil(store.operationError, "another extension is not blocked")
        await api.releaseToggle()
        await first.value
        let calls = await api.enabledCalls
        XCTAssertEqual(calls, ["a": false, "b": false])
        XCTAssertFalse(store.isBusy("a"))
    }

    func testTypedDaemonErrorsAreShownAsMessages() async {
        let api = ExtensionAPIFixture()
        await api.fail(with: DaemonClient.DaemonError.extensionFailure(code: "consent_required", message: "raw"))
        let store = ExtensionsStore(api: api)
        await store.setEnabled(true, plugin: plugin("a"))
        XCTAssertEqual(store.operationError, "Allow installs from this community repository first.")
        XCTAssertNil(store.pendingEnabled["a"])
    }

    func testUpdateAllReportsFailuresPerExtension() async {
        let store = ExtensionsStore(api: ExtensionAPIFixture())
        await store.updateAll()
        XCTAssertEqual(store.lastUpdateResults.count, 2)
        XCTAssertEqual(store.operationError, "B: boom")
    }

    func testManagedPolicyIgnoresUnforcedUserDefaults() {
        let defaults = UserDefaults(suiteName: "policy-test-\(UUID().uuidString)")!
        defaults.set(false, forKey: "ExtensionsAllowCommunityRepositories")
        let policy = ManagedExtensionPolicy.current(defaults: defaults)
        XCTAssertTrue(policy.allowCommunityTier, "only configuration-profile (forced) values apply")
        XCTAssertFalse(policy.managed)
        let line = String(decoding: DaemonLaunchOptions(policy: policy, safeMode: true).encodedLine(), as: UTF8.self)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertTrue(line.contains("\"safeMode\":true"))
    }

    func testDeveloperModeTogglesAndFailedImportsAreReported() async {
        let api = ExtensionAPIFixture()
        let store = ExtensionsStore(api: api)
        await store.setDeveloperMode(true)
        XCTAssertTrue(store.settings.developerMode)
        await store.installExtensionFile(URL(fileURLWithPath: "/tmp/My.cs3"))
        let imported = await api.importedPaths
        XCTAssertEqual(imported, ["/tmp/My.cs3"])
        XCTAssertNotNil(store.operationError, "a failed import is shown to the user")
        XCTAssertFalse(store.isBusy("developer-install"))
    }

    func testCompatibilityReportDecodesFromTheEngine() throws {
        let json = #"{"profile":"cloudstream-macos-runtime-1","current":true,"coreCode":["com.lagradost.cloudstream3.MainActivity"],"otherCode":["android.webkit.WebView"],"truncated":false}"#
        let report = try JSONDecoder().decode(CompatibilityDto.self, from: Data(json.utf8))
        XCTAssertTrue(report.hasCoreGaps)
        XCTAssertEqual(report.otherCode, ["android.webkit.WebView"])
        let clean = try JSONDecoder().decode(CompatibilityDto.self, from: Data(#"{"profile":"p","current":true,"coreCode":[],"otherCode":[],"truncated":false}"#.utf8))
        XCTAssertFalse(clean.hasCoreGaps)
    }

    /// RT-01: a typed engine failure reaches the user as its public message and code, not a generic HTTP error.
    func testTypedOperationFailureIsSurfacedFromAnErrorResponse() throws {
        let body = #"{"error":"provider failure","detail":"The provider returned no data for this operation.","failure":{"code":"provider_no_data","stage":"extraction","requestId":"r-1","publicMessage":"The provider returned no data for this operation.","retryable":false,"installationId":null,"providerId":"x:P","redactedCause":"ProviderNoDataException","remoteStatus":null,"elapsedMs":0}}"#
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1/links")!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try DaemonClient.validate(response, data: Data(body.utf8))) { error in
            let failure = error as? DaemonClient.DaemonError
            XCTAssertEqual(failure?.code, "provider_no_data")
            XCTAssertEqual(failure?.errorDescription, "The provider returned no data for this operation.")
        }
        // Without a typed record the HTTP status is reported, never a fabricated cause.
        XCTAssertThrowsError(try DaemonClient.validate(response, data: Data(#"{"error":"not found"}"#.utf8))) { error in
            XCTAssertNil((error as? DaemonClient.DaemonError)?.code)
        }
    }

    /// RT-06: a fresh store has no repositories of its own; everything comes from the engine.
    func testNoRepositoriesExistUntilTheUserAddsOne() async {
        let store = ExtensionsStore(api: ExtensionAPIFixture(), defaults: UserDefaults(suiteName: "fresh-\(UUID().uuidString)")!)
        XCTAssertTrue(store.repositories.isEmpty)
        _ = await store.refresh()
        XCTAssertTrue(store.repositories.isEmpty, "the app ships no preset repositories")
    }

    /// RT-15: the settings sheet sends only what changed, typed as the extension defines it.
    func testExtensionSettingsSendOnlyChangedValues() throws {
        let json = #"{"fields":[{"key":"server","type":"string","isSet":false},{"key":"page_size","type":"int","default":"10","value":"25","isSet":true},{"key":"show_adult","type":"boolean","default":"false","value":"true","isSet":true},{"key":"mirrors","type":"string_set","values":["a","b"],"isSet":true}],"truncated":false}"#
        let fields = try JSONDecoder().decode(ExtensionPreferencesDto.self, from: Data(json.utf8)).fields
        XCTAssertEqual(fields[3].editableText, "a\nb")
        XCTAssertEqual(fields[1].typeLabel, "Whole number")
        XCTAssertEqual(ExtensionPreferenceChanges.compute(fields: fields, text: [:], flags: [:], removed: []), [], "nothing edited, nothing sent")
        let changes = ExtensionPreferenceChanges.compute(
            fields: fields, text: ["server": "https://media.invalid", "page_size": "25", "mirrors": " a \n\n c "],
            flags: ["show_adult": true], removed: [])
        XCTAssertEqual(changes, [
            ExtensionPreferenceUpdateDto(key: "server", value: "https://media.invalid", values: nil, remove: false),
            ExtensionPreferenceUpdateDto(key: "mirrors", value: nil, values: ["a", "c"], remove: false),
        ], "unchanged number and flag are not resent; list lines are trimmed")
        XCTAssertEqual(ExtensionPreferenceChanges.compute(fields: fields, text: ["page_size": "3"], flags: [:], removed: ["page_size"]),
                       [ExtensionPreferenceUpdateDto(key: "page_size", value: nil, values: nil, remove: true)], "Use Default removes the stored value")
    }

    /// RT-16: the per-extension diagnostic tests that extension's providers and names the failing stage.
    func testDiagnoseTestsTheExtensionsProvidersAndReportsFailedStages() async throws {
        let api = ExtensionAPIFixture()
        await api.setTestResults([ProviderTestResultDto(provider: "P", status: "partial", steps: [
            ProviderTestStepDto(name: "search", ok: true, latencyMs: 5, detail: nil),
            ProviderTestStepDto(name: "links", ok: false, latencyMs: 9, detail: "No links"),
        ])])
        let store = ExtensionsStore(api: api, defaults: UserDefaults(suiteName: "diagnose-\(UUID().uuidString)")!)
        var dto = plugin("diag")
        dto.providerIds = ["diag:P"]
        await store.diagnose(dto)
        let tested = await api.testedProviders
        XCTAssertEqual(tested, ["diag:P"])
        XCTAssertEqual(store.operationError, "Test found problems: P — links: No links")
    }

    /// RT-16: a registered extension that has not started is usable, and the last failed stage is surfaced.
    func testReadyStateAndLatestFailedStage() throws {
        var dto = plugin("health")
        dto.state = "ready"
        XCTAssertTrue(dto.isOperational)
        XCTAssertNil(dto.latestFailure)
        let json = #"[{"provider":"P","providerId":"health:P","stage":"links","ok":false,"code":"provider_no_data","message":"No links","at":2},{"provider":"P","providerId":"health:P","stage":"search","ok":true,"at":1}]"#
        dto.health = try JSONDecoder().decode([OperationHealthDto].self, from: Data(json.utf8))
        XCTAssertEqual(dto.latestFailure?.stageLabel, "Video links")
        dto.health?.reverse()
        XCTAssertNil(dto.latestFailure, "a newer success supersedes the older failure")
        dto.state = "failed"
        XCTAssertFalse(dto.isOperational)
    }

    func testVersionLabelsHideUnsetAndAlwaysUpdateMarkers() {
        XCTAssertEqual(ExtensionVersion.label(3), "v3")
        XCTAssertNil(ExtensionVersion.label(0))
        XCTAssertNil(ExtensionVersion.label(-1), "-1 is CloudStream's always-update marker, not a version")
    }

    func testSandboxIsRequiredUnlessAProfileTurnsItOff() {
        XCTAssertTrue(ManagedExtensionPolicy.from { _ in nil }.requireSandbox, "unmanaged Macs fail closed without sandbox-exec")
        let optedOut = ManagedExtensionPolicy.from { ["ExtensionsRequireSandbox": false][$0] }
        XCTAssertFalse(optedOut.requireSandbox)
        XCTAssertTrue(optedOut.managed)
    }

    func testDeveloperExtensionsCanBeForbiddenByPolicy() {
        let policy = ManagedExtensionPolicy.from { ["ExtensionsAllowDeveloperExtensions": false][$0] }
        XCTAssertFalse(policy.allowDeveloperExtensions)
        XCTAssertTrue(policy.managed)
        XCTAssertFalse(ManagedExtensionPolicy.failClosed().allowDeveloperExtensions)
    }

    func testMisconfiguredManagedPolicyFailsClosed() {
        let values: [String: Any] = ["ExtensionsAllowedRepositories": "https://single.invalid/repo.json", "ExtensionsRequireSandbox": true]
        let policy = ManagedExtensionPolicy.from { values[$0] }
        XCTAssertEqual(policy, .failClosed())
        XCTAssertEqual(policy.allowedRepositories, [])
        XCTAssertTrue(policy.safeModeOnly)
        XCTAssertTrue(policy.requireSandbox)
        let relaxed = ManagedExtensionPolicy.from { ["ExtensionsAllowedRepositories": 1, "ExtensionsRequireSandbox": false][$0] }
        XCTAssertTrue(relaxed.requireSandbox, "a misconfigured profile never relaxes the sandbox requirement")
        let valid = ManagedExtensionPolicy.from { ["ExtensionsAllowedRepositories": ["https://a.invalid/repo.json"]][$0] }
        XCTAssertEqual(valid.allowedRepositories, ["https://a.invalid/repo.json"])
        XCTAssertTrue(valid.managed)
        XCTAssertFalse(valid.safeModeOnly)
    }

    func testSignedRepositoriesNeedConsentAndVerifiedOnesDoNot() throws {
        let signed = try JSONDecoder().decode(RepositoryDto.self, from: Data(#"{"name":"r","url":"https://r.invalid/repo.json","status":"ok","verified":false,"tier":"signed","keyFingerprint":"ab:cd","consentRequired":true}"#.utf8))
        XCTAssertEqual(signed.tier, "signed")
        XCTAssertTrue(signed.consentRequired)
        let pinned = try JSONDecoder().decode(RepositoryDto.self, from: Data(#"{"name":"r","url":"https://r.invalid/repo.json","status":"ok","verified":true,"tier":"verified","consentRequired":false}"#.utf8))
        XCTAssertFalse(pinned.consentRequired)
        let older = try JSONDecoder().decode(RepositoryDto.self, from: Data(#"{"name":"r","url":"https://r.invalid/repo.json","status":"ok","verified":false,"tier":"community"}"#.utf8))
        XCTAssertTrue(older.consentRequired, "an engine that omits the field still asks for consent")
    }

    func testRepositoryDecodingDefaultsTierFromLegacyVerifiedFlag() throws {
        let json = #"{"name":"r","url":"https://r.invalid/repo.json","status":"ok","verified":true,"pluginCount":1,"manifestVersion":1}"#
        let repo = try JSONDecoder().decode(RepositoryDto.self, from: Data(json.utf8))
        XCTAssertEqual(repo.tier, "verified")
        XCTAssertFalse(repo.consented)
    }

    func testProviderKeyPrefersStableIdentity() {
        var result = SearchResultDto(name: "t", url: "u", provider: "Movies", type: "Movie", posterUrl: nil, quality: nil,
                                     score: nil, language: nil, episodes: nil, year: nil, isMovie: true)
        XCTAssertEqual(result.providerKey, "Movies")
        result.providerId = "abc:Movies"
        XCTAssertEqual(result.providerKey, "abc:Movies")
    }
}


/// Audit A38: client caches key provider-derived data by this generation.
@MainActor
final class ProviderGenerationTests: XCTestCase {
    private func installed(version: Int, enabled: Bool = true, mainUrl: String? = nil) -> PluginDto {
        PluginDto(id: "ext", name: "Ext", internalName: "ext", version: version, apiVersion: 1, language: nil, description: nil,
                  authors: [], tvTypes: [], iconUrl: nil, repositoryUrl: nil, mainUrl: mainUrl, fileSize: 0, sha256: "h\(version)",
                  providers: ["P"], enabled: enabled, verified: true, lastError: nil, state: enabled ? "running" : "disabled")
    }

    func testInstalledExtensionChangesAdvanceTheProviderGeneration() async {
        let api = ExtensionAPIFixture()
        let suite = "provider-generation-" + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = ExtensionsStore(api: api, defaults: UserDefaults(suiteName: suite)!)
        // Library reconciliation hangs off this: it must see the new list.
        var seenByObserver: [[Int]] = []
        store.onProvidersChanged = { seenByObserver.append(store.plugins.map(\.version)) }
        defer { XCTAssertEqual(seenByObserver, [[1], [2], [2], [2], []], "once per real change, after the list is published") }
        func refreshed(_ plugins: [PluginDto]) async -> UInt64 {
            await api.configureInstalled(plugins)
            _ = await store.refresh()
            return store.providerGeneration
        }
        let empty = await refreshed([])
        let first = await refreshed([installed(version: 1)])
        XCTAssertNotEqual(first, empty)
        let unchanged = await refreshed([installed(version: 1)])
        XCTAssertEqual(unchanged, first, "an unchanged list is not a new generation")
        // A process state flip alone (starting/running) must not churn caches.
        var restarting = installed(version: 1)
        restarting.state = "starting"
        let stateOnly = await refreshed([restarting])
        XCTAssertEqual(stateOnly, first)
        let updated = await refreshed([installed(version: 2)])
        XCTAssertNotEqual(updated, first, "a replaced artifact invalidates provider data")
        let disabled = await refreshed([installed(version: 2, enabled: false)])
        XCTAssertNotEqual(disabled, updated)
        let moved = await refreshed([installed(version: 2, enabled: false, mainUrl: "https://clone.example")])
        XCTAssertNotEqual(moved, disabled)
        let removed = await refreshed([])
        XCTAssertNotEqual(removed, moved)
    }
}

/// Audit A33: the request states unchanged / set / clear distinctly.
final class ProviderConfigurationRequestTests: XCTestCase {
    func testRequestEncodesUnchangedSetAndClearDistinctly() throws {
        func json(_ request: PluginConfigRequestDto) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        let unchanged = try json(.init(providerId: "p"))
        XCTAssertNil(unchanged["url"]); XCTAssertNil(unchanged["credentials"])
        XCTAssertEqual(unchanged["clearUrl"] as? Bool, false); XCTAssertEqual(unchanged["clearCredentials"] as? Bool, false)
        let cleared = try json(.init(providerId: "p", url: .clear, credentials: .clear))
        XCTAssertNil(cleared["url"]); XCTAssertNil(cleared["credentials"])
        XCTAssertEqual(cleared["clearUrl"] as? Bool, true); XCTAssertEqual(cleared["clearCredentials"] as? Bool, true)
        let set = try json(.init(providerId: "p", url: .set("https://a"), credentials: .set("s")))
        XCTAssertEqual(set["url"] as? String, "https://a"); XCTAssertEqual(set["credentials"] as? String, "s")
        // Responses from an engine without the new fields still decode.
        let legacy = try JSONDecoder().decode(PluginConfigResponseDto.self, from: Data(#"{"providerId":"p","mainUrl":"u","applied":false,"detail":null}"#.utf8))
        XCTAssertFalse(legacy.accepted)
    }
}
