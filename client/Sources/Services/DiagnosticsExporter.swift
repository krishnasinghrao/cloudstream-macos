import AppKit
import Foundation
import UniformTypeIdentifiers

/// Support bundle (plan T8.5): the engine's redacted diagnostics plus app and
/// system details. Nothing is sent anywhere; the user picks where to save it.
@MainActor
enum DiagnosticsExporter {
    /// Combined JSON. The engine part is already redacted by the engine; when the
    /// engine is unavailable the bundle records why instead.
    static func bundle(appState: AppState) async -> Data {
        let info = Bundle.main.infoDictionary ?? [:]
        let supervisor = DaemonSupervisor.shared
        let application: [String: Any] = [
            "version": (info["CFBundleShortVersionString"] as? String) ?? "unknown",
            "build": (info["CFBundleVersion"] as? String) ?? "unknown",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "engineReady": appState.isEngineReady,
            "isolationMode": (appState.engineHealth?.isolation?.mode as Any?) ?? NSNull(),
            "extensionsSandboxed": (appState.engineHealth?.isolation?.sandboxed as Any?) ?? NSNull(),
            "safeMode": supervisor.safeModeActive,
            "safeModeReason": (supervisor.safeModeReason as Any?) ?? NSNull(),
            "policyManaged": ManagedExtensionPolicy.current().managed,
        ]
        var root: [String: Any] = [
            "format": "cloudstream-support-bundle-v1",
            "generatedAt": Date().formatted(.iso8601),
            "app": application,
        ]
        do {
            let data = try await DaemonClient.shared.diagnosticsExport()
            root["engine"] = try JSONSerialization.jsonObject(with: data)
        } catch {
            root["engine"] = ["unavailable": error.localizedDescription]
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// Asks where to save, then writes the bundle. Returns an error message on failure.
    static func export(appState: AppState) async -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let stamp = Date().formatted(.iso8601).replacing(":", with: "-")
        panel.nameFieldStringValue = "CloudStream Diagnostics \(stamp).json"
        panel.message = "Diagnostics contain your extension and repository list and recent engine events. Passwords, cookies and tokens are removed."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = await bundle(appState: appState)
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "Couldn't save diagnostics: \(error.localizedDescription)"
        }
    }
}
