import Foundation

/// Engine contracts shared by the transport, UI adapters and isolated tests.
/// Keep this boundary free of WebKit/SwiftUI so the actual client can be tested
/// without constructing application UI or launching the production engine.
protocol MediaResolveClient: Sendable {
    func observeMedia(taskId: String, requests: [MediaObservedRequestDto]) async throws -> MediaObserveResponseDto
    func completeMedia(_ request: MediaCompleteRequestDto) async throws
}

protocol WebViewSessionClient: Sendable {
    func completeWebView(_ result: WebViewResultDto) async throws
    func reportWebView(_ event: WebViewEventDto) async throws
}

protocol ExtensionPreferencesClient: Sendable {
    func extensionPreferences(installationId: String) async throws -> ExtensionPreferencesDto
    func updateExtensionPreferences(installationId: String, updates: [ExtensionPreferenceUpdateDto]) async throws -> ExtensionPreferencesDto
}
