import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Removes secrets from log text before it is shown or exported.
enum LogRedactor {
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1<redacted>"),
        (#"(?i)("?(?:authorization|cookie|set-cookie|token|access_token|password|passwd|secret|credentials|cf_clearance|api[_-]?key)"?\s*[:=]\s*"?)[^",;\s}&]+"#, "$1<redacted>"),
        (#"(?i)([?&](?:token|key|sig|signature|auth|session)=)[^&\s"]+"#, "$1<redacted>"),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}

/// Reads the tail of a log file without loading it whole.
enum LogTail {
    static func lines(of url: URL, maxBytes: Int = 512 * 1024, maxLines: Int = 800) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial first line
        return Array(lines.suffix(maxLines))
    }
}

/// Settings ▸ Diagnostics (Offline-Features-Plan Phase 8): provider test
/// runner, provider health, engine status and logs.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState

    enum LogSource: String, CaseIterable, Identifiable {
        case engine = "Engine"
        case app = "App"
        /// What the engine process itself printed, launch by launch.
        case engineOutput = "Engine Output"
        case engineErrors = "Engine Errors"
        var id: String { rawValue }

        var url: URL {
            switch self {
            case .engine:
                return EngineDataRoot.url().appendingPathComponent("logs/daemon.log")
            case .app:
                return ClientLogFile.shared.url
            case .engineOutput:
                return DaemonSupervisor.logDirectory().appendingPathComponent(EngineOutputLog.names[0])
            case .engineErrors:
                return DaemonSupervisor.logDirectory().appendingPathComponent(EngineOutputLog.names[1])
            }
        }
    }

    @State private var testResults: [ProviderTestResultDto] = []
    @State private var testTotal = 0
    @State private var isTesting = false
    @State private var testError: String?
    @State private var testTask: Task<Void, Never>?
    @State private var expanded: Set<String> = []

    @State private var diagnostics: DiagnosticsDto?
    @State private var logSource: LogSource = .engine
    @State private var logFilter = ""
    @State private var errorsOnly = false
    @State private var logLines: [String] = []

    var body: some View {
        Form {
            engineSection
            testSection
            healthSection
            logSection
        }
        .formStyle(.grouped)
        .task { await refreshDiagnostics() }
        .task(id: logSource) { reloadLog() }
        .onDisappear { testTask?.cancel() }
    }

    // MARK: Engine

    private var engineSection: some View {
        Section("Engine") {
            LabeledContent("Version", value: appState.daemonVersion ?? "Not connected")
            if let diagnostics {
                LabeledContent("Uptime", value: Duration.milliseconds(diagnostics.uptimeMs).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
                LabeledContent("Requests served", value: diagnostics.requestsServed.formatted())
                LabeledContent("Anti-bot challenges", value: "\(diagnostics.solveTasksSolved) of \(diagnostics.solveTasksCreated) solved")
            }
            LabeledContent("Restarts this session", value: "\(DaemonSupervisor.shared.restartCount)")
            LabeledContent("Scraper engine") {
                Button("Restart") { DaemonSupervisor.shared.restart() }
            }
        }
    }

    // MARK: Provider tests

    private var testSection: some View {
        Section {
            HStack {
                Button(isTesting ? "Stop" : "Test All Providers") {
                    if isTesting { testTask?.cancel() } else { runTests() }
                }
                .disabled(!appState.isEngineReady)
                if isTesting {
                    ProgressView(value: Double(testResults.count), total: Double(max(testTotal, testResults.count, 1)))
                        .frame(width: 140)
                    Text("\(testResults.count) done")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !testResults.isEmpty, !isTesting {
                    let failing = testResults.filter { $0.status == "fail" }
                    Button("Disable \(failing.count) Failing") { disable(failing) }
                        .disabled(failing.isEmpty)
                    Button("Copy Report") { copyReport() }
                }
            }
            if let testError {
                Text(testError).font(.caption).foregroundStyle(.red)
            }
            ForEach(sortedResults) { result in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(result.id) },
                    set: { open in if open { expanded.insert(result.id) } else { expanded.remove(result.id) } },
                )) {
                    ForEach(result.steps, id: \.name) { step in
                        HStack(spacing: 8) {
                            Image(systemName: step.ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(step.ok ? .green : .red)
                            Text(step.name.capitalized).frame(width: 80, alignment: .leading)
                            Text(step.detail ?? "").foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                            if let ms = step.latencyMs {
                                Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                } label: {
                    HStack {
                        Image(systemName: Self.symbol(for: result.status))
                            .foregroundStyle(Self.color(for: result.status))
                            .accessibilityLabel(result.status)
                        Text(result.provider)
                        Spacer()
                        Text(result.status.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Self.color(for: result.status))
                    }
                }
            }
        } header: {
            Text("Provider Tests")
        } footer: {
            Text("Each provider is checked end to end: homepage, search, opening a title and resolving its streams. Nothing is played or downloaded.")
                .foregroundStyle(.secondary)
        }
    }

    private var sortedResults: [ProviderTestResultDto] {
        let order = ["fail": 0, "partial": 1, "pass": 2]
        return testResults.sorted { (order[$0.status] ?? 3, $0.provider) < (order[$1.status] ?? 3, $1.provider) }
    }

    static func symbol(for status: String) -> String {
        switch status {
        case "pass": return "checkmark.circle.fill"
        case "partial": return "exclamationmark.triangle.fill"
        default: return "xmark.octagon.fill"
        }
    }

    static func color(for status: String) -> Color {
        switch status {
        case "pass": return .green
        case "partial": return .orange
        default: return .red
        }
    }

    private func runTests() {
        testResults = []
        testError = nil
        testTotal = appState.providers.reduce(0) { $0 + max(1, $1.providers.count) }
        isTesting = true
        testTask = Task {
            defer { isTesting = false }
            do {
                for try await event in DaemonClient.shared.providerTestStream() {
                    if let result = event.result { testResults.append(result) }
                    if let total = event.total { testTotal = total }
                }
                if testResults.isEmpty { testError = "No enabled providers to test." }
            } catch is CancellationError {
            } catch {
                testError = error.localizedDescription
            }
            await refreshDiagnostics()
        }
    }

    private func disable(_ results: [ProviderTestResultDto]) {
        Task {
            for result in results {
                try? await DaemonClient.shared.setProviderEnabled(named: result.provider, enabled: false)
            }
            _ = await appState.extensions.refresh()
            appState.presentNotice("Disabled \(results.count) provider\(results.count == 1 ? "" : "s")")
        }
    }

    static func report(_ results: [ProviderTestResultDto]) -> String {
        results.map { result in
            let steps = result.steps.map { step in
                "  \(step.ok ? "✓" : "✗") \(step.name)\(step.latencyMs.map { " (\($0) ms)" } ?? ""): \(step.detail ?? "")"
            }
            return (["\(result.provider): \(result.status.uppercased())"] + steps).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.report(sortedResults), forType: .string)
        appState.presentNotice("Test report copied")
    }

    // MARK: Health

    private var healthSection: some View {
        Section {
            if let providers = diagnostics?.providers, !providers.isEmpty {
                ForEach(providers.sorted { ($0.successRate ?? 1) < ($1.successRate ?? 1) }) { stat in
                    HStack {
                        Circle()
                            .fill(Self.healthColor(stat))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(stat.provider)
                        Spacer()
                        Text("\(stat.success) ok · \(stat.failure) failed")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(stat.lastLatencyMs) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .help(stat.lastError ?? "No recent errors")
                }
            } else {
                Text("No provider activity yet this session.")
                    .foregroundStyle(.secondary)
            }
            Button("Refresh") { Task { await refreshDiagnostics() } }
        } header: {
            Text("Provider Health (this session)")
        }
    }

    static func healthColor(_ stat: ProviderStatDto) -> Color {
        guard let rate = stat.successRate else { return .gray }
        if rate >= 0.9 { return .green }
        if rate >= 0.5 { return .orange }
        return .red
    }

    private func refreshDiagnostics() async {
        guard appState.isEngineReady else { return }
        diagnostics = try? await DaemonClient.shared.diagnostics()
    }

    // MARK: Logs

    private var logSection: some View {
        Section("Logs") {
            // The four sources get a row of their own at their natural width;
            // sharing a row with the filter squeezed or clipped them. Labels
            // are hidden because a grouped Form gives them a column of their
            // own; the titles still name the controls for VoiceOver.
            Picker("Log", selection: $logSource) {
                ForEach(LogSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                TextField("Filter", text: $logFilter, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Toggle("Problems only", isOn: $errorsOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Button { reloadLog() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                    .accessibilityLabel("Reload log")
            }
            ScrollView {
                Text(visibleLog.isEmpty ? "No log entries." : visibleLog)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            HStack {
                Button("Export Logs…") { exportLogs() }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([logSource.url])
                }
                .disabled(!FileManager.default.fileExists(atPath: logSource.url.path))
            }
        }
    }

    private var visibleLog: String {
        Self.filter(logLines, text: logFilter, problemsOnly: errorsOnly).suffix(300).joined(separator: "\n")
    }

    static func filter(_ lines: [String], text: String, problemsOnly: Bool) -> [String] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        return lines.filter { line in
            if problemsOnly {
                let lower = line.lowercased()
                guard lower.contains("error") || lower.contains("warn") || lower.contains("fail") else { return false }
            }
            return needle.isEmpty || line.localizedStandardContains(needle)
        }
    }

    private func reloadLog() {
        ClientLogFile.shared.flush()
        logLines = LogTail.lines(of: logSource.url).map(LogRedactor.redact)
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.title = "Export Logs"
        panel.nameFieldStringValue = "CloudStream-Logs-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ClientLogFile.shared.flush()
        var sections: [String] = [
            "CloudStream for Mac diagnostics — \(Date().formatted(.iso8601))",
            "App \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"), engine \(appState.daemonVersion ?? "not connected"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        if !testResults.isEmpty { sections += ["", "== Provider tests ==", Self.report(sortedResults)] }
        for source in LogSource.allCases {
            sections += ["", "== \(source.rawValue) log ==", LogTail.lines(of: source.url, maxBytes: 2 * 1024 * 1024, maxLines: 5000).map(LogRedactor.redact).joined(separator: "\n")]
        }
        do {
            try sections.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            appState.presentNotice("Logs exported (secrets removed)")
        } catch {
            appState.presentError("Couldn't export logs: \(error.localizedDescription)")
        }
    }
}
