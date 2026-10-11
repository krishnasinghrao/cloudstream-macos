import Foundation

/// Turns the sheet's edits into updates: only what the user changed is sent.
enum ExtensionPreferenceChanges {
    static func compute(fields: [ExtensionPreferenceDto], text: [String: String], flags: [String: Bool],
                        removed: Set<String>) -> [ExtensionPreferenceUpdateDto] {
        fields.compactMap { field in
            if removed.contains(field.key) { return ExtensionPreferenceUpdateDto(key: field.key, value: nil, values: nil, remove: true) }
            if field.type == "boolean" {
                guard let flag = flags[field.key], String(flag) != field.value else { return nil }
                return ExtensionPreferenceUpdateDto(key: field.key, value: String(flag), values: nil, remove: false)
            }
            guard let edited = text[field.key], edited != field.editableText else { return nil }
            if field.type == "string_set" {
                let values = edited.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return ExtensionPreferenceUpdateDto(key: field.key, value: nil, values: values, remove: false)
            }
            return ExtensionPreferenceUpdateDto(key: field.key, value: edited, values: nil, remove: false)
        }
    }
}
