import AppKit
import SwiftUI

/// Settings ▸ Playback (Offline-Features-Plan Phase 4).
struct PlaybackSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showSourceEditor = false
    @State private var showScreenshotPicker = false

    private static let countdowns = [0, 5, 10, 15, 20, 30]
    private static let seekSteps: [Double] = [5, 10, 15, 30]
    private static let skipAmounts: [Double] = [30, 60, 85, 90, 120]
    private static let qualities = [0, 2160, 1440, 1080, 720, 480, 360]

    var body: some View {
        @Bindable var preferences = appState.preferences

        Form {
            Section {
                Toggle("Play the next episode automatically", isOn: $preferences.continuousPlayback)
                Picker("Up Next countdown", selection: $preferences.nextEpisodeCountdown) {
                    ForEach(Self.countdowns, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off (at the end)" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .disabled(!preferences.continuousPlayback)
            } header: {
                Text("Continuous Playback")
            } footer: {
                Text("The countdown starts at the end credits when the file marks them, otherwise near the end of the episode.")
                    .foregroundStyle(.secondary)
            }

            Section("Resume") {
                Picker("When an episode has a saved position", selection: $preferences.resumeBehavior) {
                    ForEach(ResumeBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                Toggle("Remember source, audio, subtitles and speed for each title", isOn: $preferences.rememberPlaybackPerTitle)
            }

            Section("Controls") {
                Picker("Seek step (← →)", selection: $preferences.seekStepSeconds) {
                    ForEach(Self.seekSteps, id: \.self) { step in
                        Text("\(Int(step)) seconds").tag(step)
                    }
                }
                Picker("Skip button (S)", selection: $preferences.manualSkipSeconds) {
                    ForEach(Self.skipAmounts, id: \.self) { amount in
                        Text("\(Int(amount)) seconds").tag(amount)
                    }
                }
                .help("Used when a file has no intro/credits chapters")
            }

            Section {
                Picker("Maximum quality", selection: $preferences.playbackMaxQuality) {
                    ForEach(Self.qualities, id: \.self) { quality in
                        Text(quality == 0 ? "Best available" : "\(quality)p").tag(quality)
                    }
                }
                LabeledContent("Source priority") {
                    HStack(spacing: 8) {
                        Text(sourceSummary(preferences))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Edit…") { showSourceEditor = true }
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Preferred sources play first; avoided sources are only tried when everything else fails. Downloads use the same order.")
                    .foregroundStyle(.secondary)
            }

            Section("Screenshots") {
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Text(preferences.screenshotDirectory.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { showScreenshotPicker = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSourceEditor) {
            SourcePriorityEditor(preferences: appState.preferences)
        }
        .fileImporter(isPresented: $showScreenshotPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                appState.preferences.screenshotDirectory = url
            }
        }
    }

    private func sourceSummary(_ preferences: UserPreferences) -> String {
        let preferred = preferences.sourcePriority.count
        let avoided = preferences.avoidedSources.count
        if preferred == 0 && avoided == 0 { return "Default order" }
        return [preferred > 0 ? "\(preferred) preferred" : nil, avoided > 0 ? "\(avoided) avoided" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Drag-to-reorder source priority (Android `SourcePriorityDialog` parity).
struct SourcePriorityEditor: View {
    let preferences: UserPreferences
    @Environment(\.dismiss) private var dismiss

    enum Bucket: String, CaseIterable, Identifiable {
        case preferred = "Preferred"
        case neutral = "Default"
        case avoided = "Avoided"
        var id: String { rawValue }
    }

    struct Row: Identifiable, Hashable {
        let key: String
        let name: String
        var id: String { key }
    }

    @State private var preferred: [Row] = []
    @State private var neutral: [Row] = []
    @State private var avoided: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source Priority")
                .font(.title3.weight(.semibold))
            Text("Drag to reorder preferred sources. Sources appear here after they've been used once.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                section(.preferred, rows: $preferred, empty: "Move sources here to try them first.")
                section(.neutral, rows: $neutral, empty: "No other sources seen yet.")
                section(.avoided, rows: $avoided, empty: "Sources here are used only as a last resort.")
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 320)

            HStack {
                Button("Reset", role: .destructive) {
                    neutral = (preferred + neutral + avoided).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    preferred = []
                    avoided = []
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    preferences.sourcePriority = preferred.map(\.key)
                    preferences.avoidedSources = avoided.map(\.key)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func section(_ bucket: Bucket, rows: Binding<[Row]>, empty: String) -> some View {
        Section(bucket.rawValue) {
            if rows.wrappedValue.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            ForEach(rows.wrappedValue) { row in
                HStack {
                    if bucket == .preferred, let index = rows.wrappedValue.firstIndex(of: row) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                    Text(row.name)
                    Spacer()
                    Menu {
                        ForEach(Bucket.allCases.filter { $0 != bucket }) { target in
                            Button("Move to \(target.rawValue)") { move(row, from: bucket, to: target) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Move \(row.name)")
                }
            }
            .onMove { from, to in
                guard bucket == .preferred else { return }
                rows.wrappedValue.move(fromOffsets: from, toOffset: to)
            }
        }
    }

    private func move(_ row: Row, from: Bucket, to: Bucket) {
        switch from {
        case .preferred: preferred.removeAll { $0 == row }
        case .neutral: neutral.removeAll { $0 == row }
        case .avoided: avoided.removeAll { $0 == row }
        }
        switch to {
        case .preferred: preferred.append(row)
        case .neutral: neutral.append(row)
        case .avoided: avoided.append(row)
        }
    }

    private func load() {
        var names: [String: String] = [:]
        for name in preferences.knownSources {
            names[LinkRanker.sourceKey(name)] = names[LinkRanker.sourceKey(name)] ?? name
        }
        func row(_ key: String) -> Row { Row(key: key, name: names[key] ?? key) }
        preferred = preferences.sourcePriority.map(row)
        avoided = preferences.avoidedSources.map(row)
        let used = Set(preferences.sourcePriority + preferences.avoidedSources)
        neutral = names.keys.filter { !used.contains($0) }.map(row)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Settings ▸ Subtitles (Offline-Features-Plan Phase 5).
struct SubtitleSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newLanguage = ""

    private static let fonts: [String] = ["sans-serif"] + NSFontManager.shared.availableFontFamilies

    var body: some View {
        @Bindable var preferences = appState.preferences

        Form {
            Section {
                Toggle("Turn on subtitles automatically", isOn: $preferences.autoSelectSubtitles)
                ForEach(Array(preferences.preferredSubtitleLanguages.enumerated()), id: \.offset) { index, code in
                    HStack {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(Self.languageName(code))
                        Text(code).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            guard index > 0 else { return }
                            preferences.preferredSubtitleLanguages.swapAt(index, index - 1)
                        } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(Self.languageName(code)) up")
                        Button(role: .destructive) {
                            preferences.preferredSubtitleLanguages.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(Self.languageName(code))")
                    }
                }
                HStack {
                    Picker("Add language", selection: $newLanguage) {
                        Text("Choose…").tag("")
                        ForEach(Self.languageOptions, id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    Button("Add") {
                        guard !newLanguage.isEmpty, !preferences.preferredSubtitleLanguages.contains(newLanguage) else { return }
                        preferences.preferredSubtitleLanguages.append(newLanguage)
                        newLanguage = ""
                    }
                    .disabled(newLanguage.isEmpty)
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("The first language available is selected. Downloads save subtitles in the first language. A show's own choice (remembered per title) wins.")
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                LabeledContent("Font Size") {
                    HStack {
                        Slider(value: styleBinding(\.subtitleFontSize, default: SubtitleStyle.defaultFontSize), in: 28...90)
                            .frame(width: 200)
                        Text("\(Int(preferences.subtitleFontSize ?? SubtitleStyle.defaultFontSize)) pt")
                            .font(.body.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Outline Width") {
                    HStack {
                        Slider(value: styleBinding(\.subtitleOutlineWidth, default: SubtitleStyle.defaultOutlineWidth), in: 0...6)
                            .frame(width: 200)
                        Text(String(format: "%.1f pt", preferences.subtitleOutlineWidth ?? SubtitleStyle.defaultOutlineWidth))
                            .font(.body.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Shadow") {
                    HStack {
                        Slider(value: Binding(
                            get: { preferences.subtitleShadowOffset },
                            set: { preferences.subtitleShadowOffset = $0; appState.player.applySubtitleStyle() },
                        ), in: 0...4)
                        .frame(width: 200)
                        Text(String(format: "%.1f", preferences.subtitleShadowOffset))
                            .font(.body.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Vertical Position") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(preferences.subtitlePosition) },
                            set: { preferences.subtitlePosition = Int($0.rounded()); appState.player.applySubtitleStyle() },
                        ), in: 50...100)
                        .frame(width: 200)
                        Text("\(preferences.subtitlePosition)%")
                            .font(.body.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Picker("Font", selection: Binding(
                    get: { preferences.subtitleFont ?? "sans-serif" },
                    set: { preferences.subtitleFont = $0 == "sans-serif" ? nil : $0; appState.player.applySubtitleStyle() },
                )) {
                    ForEach(Self.fonts, id: \.self) { family in
                        Text(family == "sans-serif" ? "System Default" : family).tag(family)
                    }
                }
                Toggle("Bold", isOn: Binding(
                    get: { preferences.subtitleBold },
                    set: { preferences.subtitleBold = $0; appState.player.applySubtitleStyle() },
                ))
                Picker("Text Color", selection: Binding(
                    get: { preferences.subtitleTextColor ?? SubtitleColor.white },
                    set: { preferences.subtitleTextColor = $0; appState.player.applySubtitleStyle() },
                )) {
                    ForEach(SubtitleColor.presets, id: \.color) { preset in
                        Text(preset.name).tag(preset.color)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.preferences.preferredSubtitleLanguages) { _, languages in
            // Downloads keep reading the single legacy key.
            if let first = languages.first { appState.preferences.subtitleLanguage = first }
        }
    }

    private func styleBinding(_ keyPath: ReferenceWritableKeyPath<UserPreferences, Double?>, default fallback: Double) -> Binding<Double> {
        Binding(
            get: { appState.preferences[keyPath: keyPath] ?? fallback },
            set: {
                appState.preferences[keyPath: keyPath] = $0
                appState.player.applySubtitleStyle()
            },
        )
    }

    struct LanguageOption { let code: String; let name: String }

    static let languageOptions: [LanguageOption] = {
        let locale = Locale.current
        return Locale.LanguageCode.isoLanguageCodes
            .compactMap { code -> LanguageOption? in
                guard let alpha2 = code.identifier(.alpha2),
                      let name = locale.localizedString(forLanguageCode: alpha2) else { return nil }
                return LanguageOption(code: alpha2, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
