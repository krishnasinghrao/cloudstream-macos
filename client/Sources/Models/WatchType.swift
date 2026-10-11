/// CloudStream's 5 canonical library watch states (Design.md §4.3).
enum WatchType: Int, Codable, CaseIterable, Identifiable, Sendable {
    case watching = 0
    case planToWatch = 1
    case completed = 2
    case onHold = 3
    case dropped = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .watching: return "Watching"
        case .planToWatch: return "Plan to Watch"
        case .completed: return "Completed"
        case .onHold: return "On Hold"
        case .dropped: return "Dropped"
        }
    }

    var symbolName: String {
        switch self {
        case .watching: return "play.circle"
        case .planToWatch: return "bookmark"
        case .completed: return "checkmark.circle"
        case .onHold: return "pause.circle"
        case .dropped: return "xmark.circle"
        }
    }
}
