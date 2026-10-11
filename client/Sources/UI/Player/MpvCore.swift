import Foundation
import Synchronization

// The libmpv playback core: value/track types, the `mpv_node` reader, the
// drain-queue owner (`MpvCore`) and its main-actor event sink. The view that
// renders the frames lives in MetalVideoView.swift.

enum MpvValue: Sendable {
    case double(Double)
    case flag(Int32)
    case int64(Int64)
    case string(String)

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .flag(let value) = self { return value != 0 }
        return nil
    }

    var int64Value: Int64? {
        if case .int64(let value) = self { return value }
        return nil
    }
}

/// Why a file ended (mpv_event_end_file.reason). Drives failover vs. next-episode.
enum MpvEndFileReason: Int32, Sendable {
    case eof = 0
    case stop = 2
    case quit = 3
    case error = 4
    case redirect = 5
    case other = -1
}

/// One entry of mpv's `track-list`.
struct MpvTrack: Identifiable, Sendable, Hashable {
    let id: Int64
    let type: String // "audio" | "sub" | "video"
    let title: String?
    let lang: String?
    let codec: String?

    var label: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let lang, !lang.isEmpty { parts.append(lang) }
        if let codec, !codec.isEmpty { parts.append(codec) }
        let joined = parts.joined(separator: " · ")
        return joined.isEmpty ? "Track \(id)" : joined
    }
}

/// One entry of mpv's `chapter-list`.
struct MpvChapter: Sendable, Hashable {
    let index: Int
    let title: String?
    /// Start, seconds.
    let time: Double
}

/// Recursive `mpv_node` reader (plan WS-3.2): converts mpv's tagged C tree
/// into plain Swift values so `track-list` and other NODE properties are
/// observable without a third-party binding.
enum MpvNodeReader {
    enum NodeValue: Sendable {
        case string(String)
        case flag(Bool)
        case int(Int64)
        case double(Double)
        case array([NodeValue])
        case map([String: NodeValue])
    }

    static func read(_ node: mpv_node) -> NodeValue? {
        switch node.format {
        case MPV_FORMAT_STRING:
            guard let raw = node.u.string else { return nil }
            return .string(String(cString: raw))
        case MPV_FORMAT_FLAG:
            return .flag(node.u.flag != 0)
        case MPV_FORMAT_INT64:
            return .int(node.u.int64)
        case MPV_FORMAT_DOUBLE:
            return .double(node.u.double_)
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list,
                  let values = list.pointee.values else { return .array([]) }
            let count = max(0, Int(list.pointee.num))
            let items = (0..<count).compactMap { index in
                read(values[index])
            }
            return .array(items)
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list,
                  let keys = list.pointee.keys,
                  let values = list.pointee.values else { return .map([:]) }
            var map: [String: NodeValue] = [:]
            let count = max(0, Int(list.pointee.num))
            for index in 0..<count {
                guard let keyPtr = keys[index] else { continue }
                let key = String(cString: keyPtr)
                if let value = read(values[index]) {
                    map[key] = value
                }
            }
            return .map(map)
        default:
            return nil
        }
    }

    /// Builds `MpvChapter`s from the `chapter-list` node tree.
    static func chapters(from node: mpv_node) -> [MpvChapter] {
        chapters(from: read(node))
    }

    static func chapters(from value: NodeValue?) -> [MpvChapter] {
        guard case .array(let entries) = value ?? .array([]) else { return [] }
        return entries.enumerated().compactMap { index, entry in
            guard case .map(let map) = entry else { return nil }
            let time: Double
            switch map["time"] {
            case .double(let value): time = value
            case .int(let value): time = Double(value)
            default: return nil
            }
            var title: String?
            if case .string(let value) = map["title"], !value.isEmpty { title = value }
            return MpvChapter(index: index, title: title, time: time)
        }
    }

    /// Builds `MpvTrack`s from the `track-list` node tree.
    static func tracks(from node: mpv_node) -> [MpvTrack] {
        guard case .array(let entries) = read(node) ?? .array([]) else { return [] }
        return entries.compactMap { entry in
            guard case .map(let map) = entry else { return nil }
            guard case .int(let id) = map["id"] else { return nil }
            guard case .string(let type) = map["type"] else { return nil }

            func string(_ key: String) -> String? {
                if case .string(let value) = map[key] {
                    return value.isEmpty ? nil : value
                }
                return nil
            }
            return MpvTrack(
                id: id,
                type: type,
                title: string("title"),
                lang: string("lang"),
                codec: string("codec"),
            )
        }
    }
}

/// C-callback-safe bundle of everything the mpv threads touch: the raw handle,
/// a private drain queue, and main-actor-bound handlers.
/// `@unchecked Sendable`: all mutable state is confined to `queue`.
final class MpvCore: @unchecked Sendable {
    let handle: OpaquePointer
    let queue: DispatchQueue
    let sink: MpvEventSink
    private var isStopped = false

    /// Drain-side 4 Hz gate for time-pos forwarding; owned by MpvCore so the
    /// gate resets with each MetalVideoView/engine generation.
    private var lastForwardedDrainTimePos: Double = -1

    /// Playlist entry of the file currently loading/playing. END_FILE events
    /// for any other entry (a replaced mirror) are stale and dropped (T6).
    private var currentEntryId: Int64 = 0

    init(handle: OpaquePointer, queue: DispatchQueue, sink: MpvEventSink) {
        self.handle = handle
        self.queue = queue
        self.sink = sink
    }

    /// Must be called on `queue`.
    func stop() {
        isStopped = true
        let sink = sink
        sink.invalidate()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { sink.clear() }
        }
    }

    /// Delivers on the main queue, FIFO — unlike one `Task { @MainActor }`
    /// per event, which has no ordering guarantee (T6).
    /// Internal for deterministic lifetime tests; callers still enqueue from
    /// the core's serial drain queue, exactly like native events.
    func deliver(_ body: @escaping @MainActor @Sendable (MpvEventSink) -> Void) {
        let sink = sink
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard sink.acceptsEvents else { return }
                body(sink)
            }
        }
    }

    func drainEvents() {
        while !isStopped {
            guard let event = mpv_wait_event(handle, 0) else { return }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE:
                return
            case MPV_EVENT_SHUTDOWN:
                isStopped = true
                return
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let prefix = msg.prefix.map { String(cString: $0) } ?? "mpv"
                    let text = msg.text.map { String(cString: $0) } ?? ""
                    let level = msg.level.map { String(cString: $0) } ?? ""
                    NSLog("%@", "[mpv:\(level)] [\(prefix)] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            case MPV_EVENT_START_FILE:
                if let data = event.pointee.data {
                    currentEntryId = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
                }
                lastForwardedDrainTimePos = -1
            case MPV_EVENT_END_FILE:
                // Read the reason before hopping to the main actor (plain values only).
                let reason: MpvEndFileReason
                if let data = event.pointee.data {
                    let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if currentEntryId != 0, endFile.playlist_entry_id != currentEntryId {
                        continue // a replaced file's late END_FILE
                    }
                    reason = MpvEndFileReason(rawValue: Int32(endFile.reason.rawValue)) ?? .other
                } else {
                    reason = .other
                }
                deliver { $0.onEndFile?(reason) }
            case MPV_EVENT_FILE_LOADED:
                // Not "ready": PLAYBACK_RESTART follows once decoders and
                // audio output are actually running. Treating FILE_LOADED as
                // ready hid the spinner over a frozen first frame.
                deliver { $0.onFileLoaded?() }
            case MPV_EVENT_SET_PROPERTY_REPLY, MPV_EVENT_COMMAND_REPLY:
                // Async writes report failures here — never let them vanish.
                var failure: String?
                if event.pointee.error < 0 {
                    let reason = mpv_error_string(event.pointee.error).map { String(cString: $0) } ?? "\(event.pointee.error)"
                    let kind = event.pointee.event_id == MPV_EVENT_COMMAND_REPLY ? "command" : "property write"
                    NSLog("%@", "[mpv:error] async \(kind) failed: \(reason)")
                    failure = reason
                }
                // Plain values only cross to the main queue, in FIFO order.
                let userdata = event.pointee.reply_userdata
                if event.pointee.event_id == MPV_EVENT_COMMAND_REPLY, userdata != 0 || failure != nil {
                    deliver { $0.onCommandReply?(userdata, failure) }
                }
            case MPV_EVENT_PLAYBACK_RESTART:
                deliver { $0.onPlaybackRestart?() }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data else { continue } // keep draining (P0-3b)
                let property = data.assumingMemoryBound(to: mpv_event_property.self)
                let name = property.pointee.name.map { String(cString: $0) } ?? ""

                // Plain-value hops only: read C memory on this thread.
                if name == "track-list" {
                    let tracks: [MpvTrack]
                    if property.pointee.format == MPV_FORMAT_NODE, let propData = property.pointee.data {
                        // The NODE tree is owned by mpv_event and released on
                        // the next mpv_wait_event — never free it here.
                        let node = propData.assumingMemoryBound(to: mpv_node.self).pointee
                        tracks = MpvNodeReader.tracks(from: node)
                    } else {
                        tracks = []
                    }
                    deliver { $0.onTracks?(tracks) }
                    continue
                }
                if name == "chapter-list" {
                    let chapters: [MpvChapter]
                    if property.pointee.format == MPV_FORMAT_NODE, let propData = property.pointee.data {
                        chapters = MpvNodeReader.chapters(from: propData.assumingMemoryBound(to: mpv_node.self).pointee)
                    } else {
                        chapters = []
                    }
                    deliver { $0.onChapters?(chapters) }
                    continue
                }

                let value: MpvValue?
                switch property.pointee.format {
                case MPV_FORMAT_DOUBLE:
                    value = property.pointee.data.map { .double($0.assumingMemoryBound(to: Double.self).pointee) }
                case MPV_FORMAT_FLAG:
                    value = property.pointee.data.map { .flag($0.assumingMemoryBound(to: Int32.self).pointee) }
                case MPV_FORMAT_INT64:
                    value = property.pointee.data.map { .int64($0.assumingMemoryBound(to: Int64.self).pointee) }
                case MPV_FORMAT_STRING:
                    value = property.pointee.data
                        .flatMap { $0.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee }
                        .map { .string(String(cString: $0)) }
                case MPV_FORMAT_NONE where StreamInfo.observedStringProperties.contains(name):
                    // Unavailable (for example no video yet): clear the value.
                    value = .string("")
                case MPV_FORMAT_NONE where StreamInfo.observedIntegerProperties.contains(name):
                    value = .int64(0)
                case MPV_FORMAT_NONE where name == "aid" || name == "sid":
                    // "no" track selected: surface as 0 so the UI's "Off" is accurate.
                    value = .int64(0)
                default:
                    value = nil
                }
                guard let value else { continue }

                // Gate the high-frequency clock property at the drain queue
                // (P2-19): monotonic-forward ≥ interval, or any discontinuity.
                if name == "time-pos", case .double(let now) = value {
                    let last = lastForwardedDrainTimePos
                    guard last < 0 || now < last || now - last >= MetalVideoView.timePosForwardInterval else { continue }
                    lastForwardedDrainTimePos = now
                }

                deliver { $0.onProperty?(name, value) }
            default:
                continue
            }
        }
    }
}

/// Handler storage is exclusively main-actor owned. Only the small locked
/// lifetime fence is reachable from the drain/teardown queues.
@MainActor
final class MpvEventSink {
    nonisolated private let active = Mutex(true)

    nonisolated var acceptsEvents: Bool { active.withLock { $0 } }
    nonisolated func invalidate() { active.withLock { $0 = false } }

    var onProperty: (@MainActor (String, MpvValue) -> Void)?
    var onEndFile: (@MainActor (MpvEndFileReason) -> Void)?
    var onTracks: (@MainActor ([MpvTrack]) -> Void)?
    var onFileLoaded: (@MainActor () -> Void)?
    var onPlaybackRestart: (@MainActor () -> Void)?
    var onChapters: (@MainActor ([MpvChapter]) -> Void)?
    var onCommandReply: (@MainActor (UInt64, String?) -> Void)?

    init(
        onProperty: @escaping @MainActor (String, MpvValue) -> Void,
        onEndFile: @escaping @MainActor (MpvEndFileReason) -> Void,
        onTracks: @escaping @MainActor ([MpvTrack]) -> Void,
        onFileLoaded: (@MainActor () -> Void)? = nil,
        onPlaybackRestart: (@MainActor () -> Void)? = nil,
        onChapters: (@MainActor ([MpvChapter]) -> Void)? = nil,
        onCommandReply: (@MainActor (UInt64, String?) -> Void)? = nil,
    ) {
        self.onProperty = onProperty
        self.onEndFile = onEndFile
        self.onTracks = onTracks
        self.onFileLoaded = onFileLoaded
        self.onPlaybackRestart = onPlaybackRestart
        self.onChapters = onChapters
        self.onCommandReply = onCommandReply
    }

    func clear() {
        invalidate()
        onProperty = nil
        onEndFile = nil
        onTracks = nil
        onFileLoaded = nil
        onPlaybackRestart = nil
        onChapters = nil
        onCommandReply = nil
    }
}

/// The outcome of one asynchronous player command.
struct MpvCommandReply: Equatable, Sendable {
    enum Kind: UInt64, Sendable { case other = 0, seek = 1, screenshot = 2 }
    let kind: Kind
    /// nil on success.
    let error: String?
    /// The file a screenshot command was asked to write.
    var url: URL? = nil

    /// Reply tag: the kind in the low byte, a sequence above it.
    static func tag(_ kind: Kind, sequence: UInt64) -> UInt64 { (sequence << 8) | kind.rawValue }
}
