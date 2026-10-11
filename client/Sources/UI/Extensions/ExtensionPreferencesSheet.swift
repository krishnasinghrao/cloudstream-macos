import SwiftUI

/// Native editor for an extension's own settings (plan RT-15). The engine reads
/// the extension's preference keys, types and defaults from its code; this
/// sheet edits them with matching controls. Keys are shown exactly as the
/// extension defines them — no labels are invented — and text values are
/// hidden by default because any of them may be a credential.
struct ExtensionPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: PluginDto
    var client: ExtensionPreferencesClient = DaemonClient.shared

    @State private var fields: [ExtensionPreferenceDto] = []
    @State private var truncated = false
    @State private var text: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var removed: Set<String> = []
    @State private var revealValues = false
    @State private var status: String?
    @State private var loading = true
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(plugin.name) Extension Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || loading || changes.isEmpty)
            }
            Text("These are the settings this extension stores, named as the extension names them. "
                 + "Its Android settings screen isn't available on Mac. Saving restarts the extension.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fields.isEmpty {
                ContentUnavailableView("No Settings", systemImage: "slider.horizontal.3",
                                       description: Text(status ?? "This extension doesn't store any settings."))
            } else {
                Toggle("Show text values", isOn: $revealValues)
                Form {
                    ForEach(fields, id: \.key) { field in row(field) }
                    if truncated { Text("This extension has more settings than can be listed.").foregroundStyle(.secondary) }
                }.formStyle(.grouped)
            }
            if let status, !fields.isEmpty { Text(status).font(.callout).foregroundStyle(.orange) }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ field: ExtensionPreferenceDto) -> some View {
        let isRemoved = removed.contains(field.key)
        LabeledContent {
            HStack {
                switch field.type {
                case "boolean":
                    Toggle(field.key, isOn: Binding(
                        get: { flags[field.key] ?? ((field.value ?? field.default) == "true") },
                        set: { flags[field.key] = $0; removed.remove(field.key) })).labelsHidden()
                case "string_set":
                    TextField("One per line", text: binding(field), axis: .vertical).lineLimit(1...6)
                case "string":
                    if revealValues { TextField(placeholder(field), text: binding(field)) }
                    else { SecureField(placeholder(field), text: binding(field)) }
                default:
                    TextField(placeholder(field), text: binding(field)).monospacedDigit()
                }
                if field.isSet || text[field.key] != nil || flags[field.key] != nil {
                    Button("Use Default") { reset(field) }
                        .controlSize(.small).disabled(isRemoved)
                        .help("Removes the stored value so the extension's own default applies")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.key).font(.body.monospaced())
                Text(isRemoved ? "Will use default" : field.typeLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func placeholder(_ field: ExtensionPreferenceDto) -> String {
        field.default.map { $0.isEmpty ? "Default: empty" : "Default: \($0)" } ?? "Not set"
    }

    private func binding(_ field: ExtensionPreferenceDto) -> Binding<String> {
        Binding(get: { text[field.key] ?? (removed.contains(field.key) ? "" : field.editableText) },
                set: { text[field.key] = $0; removed.remove(field.key) })
    }

    private func reset(_ field: ExtensionPreferenceDto) {
        text[field.key] = nil
        flags[field.key] = nil
        if field.isSet { removed.insert(field.key) }
    }

    private var changes: [ExtensionPreferenceUpdateDto] {
        ExtensionPreferenceChanges.compute(fields: fields, text: text, flags: flags, removed: removed)
    }

    private func load() async {
        defer { loading = false }
        do {
            let result = try await client.extensionPreferences(installationId: plugin.id)
            fields = result.fields
            truncated = result.truncated
        } catch {
            status = ExtensionsStore.message(for: error)
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await client.updateExtensionPreferences(installationId: plugin.id, updates: changes)
            fields = result.fields
            text = [:]; flags = [:]; removed = []
            dismiss()
        } catch {
            status = ExtensionsStore.message(for: error)
        }
    }
}
