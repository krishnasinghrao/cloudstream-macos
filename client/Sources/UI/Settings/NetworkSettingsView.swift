import SwiftUI

/// Settings ▸ Network (Offline-Features-Plan Phase 3): DNS-over-HTTPS
/// resolver, HTTP cache and retries — all applied inside the daemon, where
/// every provider request is made — plus a per-provider reachability test.
struct NetworkSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var saved: NetworkSettingsDto?
    @State private var draft: NetworkSettingsDto?
    @State private var customURL = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testResults: [ConnectivityResultDto] = []
    @State private var testError: String?

    private static let cacheSizes = [0, 25, 50, 100, 200, 500]

    var body: some View {
        Form {
            if let draft {
                resolverSection(draft)
                cacheSection(draft)
                testSection
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label("Network settings unavailable", systemImage: "network.slash")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .formStyle(.grouped)
        .task(id: appState.isEngineReady) { await load() }
    }

    // MARK: Sections

    private func resolverSection(_ draft: NetworkSettingsDto) -> some View {
        Section {
            Picker("DNS resolver", selection: binding(\.dns)) {
                ForEach(draft.resolvers) { option in
                    Text(option.id == "system" ? "System Default" : option.label).tag(option.id)
                }
            }

            if draft.dns == "custom" {
                TextField("DoH URL", text: $customURL, prompt: Text("https://dns.example/dns-query"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await save() } }
                if !customURL.isEmpty, !Self.isValidDoHURL(customURL) {
                    Text("Enter an https:// DNS-over-HTTPS endpoint.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Toggle("Retry once after a network error", isOn: binding(\.retryOnNetworkError))

            // Shown once the engine reports the setting (an older engine has none).
            if draft.githubMirror != nil {
                Toggle("Download repositories through jsDelivr", isOn: Binding(
                    get: { self.draft?.githubMirror ?? false },
                    set: { self.draft?.githubMirror = $0; saveError = nil },
                ))
                Text("For networks that block GitHub. Repository and extension files hosted on GitHub are fetched from the jsDelivr mirror; every file is still verified exactly as before. The mirror can show updates up to 12 hours late.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Revert") { revert() }
                    .disabled(!hasChanges || isSaving)
                Button(isSaving ? "Applying…" : "Apply") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || isSaving || !isDraftValid)
            }
        } header: {
            Text("Resolver")
        } footer: {
            Text("DNS-over-HTTPS resolves provider sites through an encrypted resolver, which gets around many ISP-level blocks. If the resolver can't be reached, the system resolver is used.")
                .foregroundStyle(.secondary)
        }
    }

    private func cacheSection(_ draft: NetworkSettingsDto) -> some View {
        Section("HTTP Cache") {
            Picker("Cache size", selection: binding(\.httpCacheMb)) {
                ForEach(Self.cacheSizes, id: \.self) { size in
                    Text(size == 0 ? "Off" : "\(size) MB").tag(size)
                }
            }
            LabeledContent("In use") {
                HStack(spacing: 10) {
                    Text(Int64(saved?.cacheSizeBytes ?? 0).formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Clear") { Task { await clearCache() } }
                        .disabled((saved?.cacheSizeBytes ?? 0) == 0)
                }
            }
            .help("Cached provider pages and API responses. Sites decide what may be cached.")
        }
    }

    private var testSection: some View {
        Section {
            LabeledContent("Provider sites") {
                Button(isTesting ? "Testing…" : "Test Connection") { Task { await runTest() } }
                    .disabled(isTesting || !appState.isEngineReady)
            }
            if let testError {
                Text(testError).font(.caption).foregroundStyle(.red)
            }
            ForEach(testResults) { result in
                HStack(spacing: 8) {
                    Image(systemName: result.reachable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(result.reachable ? .green : .red)
                        .accessibilityLabel(result.reachable ? "Reachable" : "Unreachable")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.provider)
                        Text(result.reachable ? (URL(string: result.url)?.host ?? result.url) : (result.error ?? "Unreachable"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let status = result.status {
                        Text("HTTP \(status)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let latency = result.latencyMs {
                        Text("\(latency) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Checks whether each enabled provider's site answers through the settings above. A reachable site that still fails points to the extension, not your network.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: State

    private func binding<T>(_ keyPath: WritableKeyPath<NetworkSettingsDto, T>) -> Binding<T> {
        Binding(
            get: { draft![keyPath: keyPath] },
            set: { draft?[keyPath: keyPath] = $0; saveError = nil },
        )
    }

    private var effectiveDraft: NetworkSettingsDto? {
        guard var draft else { return nil }
        draft.customDohUrl = draft.dns == "custom" ? customURL.trimmingCharacters(in: .whitespaces) : saved?.customDohUrl
        return draft
    }

    private var hasChanges: Bool {
        guard let saved, let current = effectiveDraft else { return false }
        return current.dns != saved.dns
            || current.httpCacheMb != saved.httpCacheMb
            || current.retryOnNetworkError != saved.retryOnNetworkError
            || current.githubMirror != saved.githubMirror
            || (current.dns == "custom" && current.customDohUrl != saved.customDohUrl)
    }

    private var isDraftValid: Bool {
        guard let draft else { return false }
        return draft.dns != "custom" || Self.isValidDoHURL(customURL)
    }

    static func isValidDoHURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private func revert() {
        draft = saved
        customURL = saved?.customDohUrl ?? ""
        saveError = nil
    }

    private func load() async {
        guard appState.isEngineReady else {
            loadError = "The scraper engine isn't running yet."
            return
        }
        do {
            let settings = try await DaemonClient.shared.networkSettings()
            saved = settings
            draft = settings
            customURL = settings.customDohUrl ?? ""
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        guard let request = effectiveDraft, isDraftValid else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let applied = try await DaemonClient.shared.updateNetworkSettings(request)
            saved = applied
            draft = applied
            customURL = applied.customDohUrl ?? ""
            saveError = nil
            testResults = []
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func clearCache() async {
        do {
            saved = try await DaemonClient.shared.clearHTTPCache()
        } catch {
            appState.presentError("Couldn't clear the HTTP cache: \(error.localizedDescription)")
        }
    }

    private func runTest() async {
        isTesting = true
        testError = nil
        defer { isTesting = false }
        do {
            testResults = try await DaemonClient.shared.testConnectivity()
            if testResults.isEmpty {
                testError = "No enabled providers to test. Install an extension first."
            }
        } catch {
            testError = error.localizedDescription
        }
    }
}
