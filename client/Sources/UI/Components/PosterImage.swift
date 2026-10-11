import AppKit
import CryptoKit
import SwiftUI
import Synchronization

// MARK: - Cached Remote Poster Image

/// How large an image is decoded. Cards and rows show artwork a few hundred
/// points wide; decoding a 2000×3000 poster in full for them costs ~24 MB
/// each, evicts its neighbours from the memory cache and makes every
/// scrolled frame resample a huge bitmap.
enum ArtworkRendition: Sendable {
    /// Cards, shelves, rows: sharp up to ~320 pt on a 2× display.
    case thumbnail
    /// Hero backdrops and anything shown near window size.
    case full

    var maxDimension: Int {
        switch self {
        case .thumbnail: return 640
        case .full: return BoundedImageDecoder.maxRenditionDimension
        }
    }
}

struct PosterImage: View {
    let url: String?
    var alignment: Alignment = .center
    var placeholderIcon: String = "film"
    /// Referer/cookie headers some hosts require (provider `posterHeaders`).
    var headers: [String: String]? = nil
    var rendition: ArtworkRendition = .thumbnail
    /// The loaded image and the URL it belongs to: a reused cell never shows
    /// the previous title's poster.
    @State private var loaded: (url: String, image: NSImage)?

    var body: some View {
        // A lazy container rebuilds cells as they scroll back in. Reading the
        // memory cache here shows the poster in the cell's first frame; a
        // `.task` would only deliver it a frame later, as a visible reload.
        let image = url.flatMap { url -> NSImage? in
            guard !url.isEmpty else { return nil }
            if let loaded, loaded.url == url { return loaded.image }
            return ImageCache.shared.synchronousMemoryImage(for: url, headers: headers, rendition: rendition)
        }
        Color.cardSurface
            // `alignment` positions the artwork (the hero anchors faces to the
            // top); the placeholder always sits in the middle of the frame.
            .overlay(alignment: alignment) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .overlay {
                if image == nil {
                    Image(systemName: placeholderIcon)
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            // A fill-mode image overflows the proposal to keep its aspect;
            // never let it bleed outside this view's bounds.
            .clipped()
            .task(id: url) {
                guard let url, !url.isEmpty else { return }
                if let cached = ImageCache.shared.synchronousMemoryImage(for: url, headers: headers, rendition: rendition) {
                    // Already on screen from `body`; held so eviction cannot blank it.
                    loaded = (url, cached)
                    return
                }
                if let image = await ImageCache.shared.image(for: url, headers: headers, rendition: rendition), !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.18)) {
                        loaded = (url, image)
                    }
                }
            }
    }
}

// MARK: - Image Cache

/// Thread-safe NSCache box. NSCache is documented thread-safe but not
/// marked `Sendable`, so strict concurrency needs this wrapper to move
/// decoded images across task boundaries.
private final class ImageMemoryBox: @unchecked Sendable {
    let cache = NSCache<NSString, NSImage>()
    /// NSCache treats its cost limit as a hint and may hold far more. The
    /// budget is kept here: entries in insertion order with their cost, the
    /// oldest removed as soon as the total passes the limit. An entry NSCache
    /// dropped by itself is only counted a little longer than it lived.
    private let entries = Mutex<(order: [(key: String, cost: Int)], total: Int)>(([], 0))

    func object(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: NSImage, forKey key: String) {
        let cost = Self.decodedCost(of: image)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        let limit = cache.totalCostLimit
        let evicted: [String] = entries.withLock { state in
            if let index = state.order.firstIndex(where: { $0.key == key }) {
                state.total -= state.order.remove(at: index).cost
            }
            state.order.append((key, cost))
            state.total += cost
            var removed: [String] = []
            while limit > 0, state.total > limit, state.order.count > 1 {
                let oldest = state.order.removeFirst()
                state.total -= oldest.cost
                removed.append(oldest.key)
            }
            return removed
        }
        for key in evicted { cache.removeObject(forKey: key as NSString) }
    }

    /// Approximate decoded size (RGBA bytes) — what the image costs in RAM.
    static func decodedCost(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        let fallback = Int(image.size.width * image.size.height)
        return max(pixels, fallback) * 4
    }

    func removeAll() {
        cache.removeAllObjects()
        entries.withLock { $0 = ([], 0) }
    }

    /// Drops the oldest entries until at most `budget` bytes remain.
    func trim(to budget: Int) {
        let evicted: [String] = entries.withLock { state in
            var removed: [String] = []
            while state.total > budget, !state.order.isEmpty {
                let oldest = state.order.removeFirst()
                state.total -= oldest.cost
                removed.append(oldest.key)
            }
            return removed
        }
        for key in evicted { cache.removeObject(forKey: key as NSString) }
    }
}

/// Disk + memory poster cache. Decoding and disk I/O happen off the main
/// actor; only the in-flight bookkeeping is main-actor state.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = ImageMemoryBox()
    private let disk: URL
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    nonisolated static let activeMemoryBudget = 256 * 1024 * 1024
    nonisolated static let inactiveMemoryBudget = 48 * 1024 * 1024

    /// Disk cache ceiling, enforced least-recently-used first on launch and while running.
    nonisolated static let maxDiskBytes: Int64 = 200_000_000
    /// Bytes written between runtime prunes; keeps directory scans rare.
    nonisolated static let pruneIntervalBytes: Int64 = 20_000_000

    /// Network loads beyond this wait their turn; memory hits are not limited.
    /// A load keeps its turn until its image is decoded, so no more than
    /// this many response bodies are ever held.
    nonisolated static let maxConcurrentLoads = 6
    nonisolated private static let loads = AsyncLimiter(limit: maxConcurrentLoads)
    /// Disk-cache reads get their own turns: a cached poster must not wait
    /// behind slow network loads.
    nonisolated private static let diskLoads = AsyncLimiter(limit: maxConcurrentLoads)
    /// Source pixels being decoded at once, network and disk together. A
    /// decode can need four bytes per source pixel before it is downsampled,
    /// so this is what bounds decode memory when many large images arrive:
    /// about 96 MB, i.e. a dozen 1080p backdrops or two 12-megapixel ones.
    /// A larger image (up to the source limit) is decoded alone.
    nonisolated static let maxConcurrentDecodePixels = 24_000_000
    nonisolated private static let decodes = AsyncLimiter(limit: maxConcurrentDecodePixels)
    nonisolated private let session: URLSession
    nonisolated private let maxResponseBytes: Int

    nonisolated private static let bytesSincePrune = Mutex<Int64>(0)

    /// - Parameter directory: tests pass a private cache directory.
    init(directory: URL? = nil, session: URLSession = BoundedHTTPResource.session, maxResponseBytes: Int = BoundedHTTPResource.imageBytes) {
        self.session = session
        self.maxResponseBytes = maxResponseBytes
        memory.cache.countLimit = 600
        // Phase 10 memory budget: large backdrops cost far more than posters.
        memory.cache.totalCostLimit = Self.activeMemoryBudget
        // While the app is in the background, keep only what the visible
        // screen needs: the idle app stays near its memory budget, and the
        // disk cache brings scrolled-away artwork back quickly.
        let box = memory
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
            box.trim(to: Self.inactiveMemoryBudget)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        disk = directory ?? AppEnvironment.directory("Images") ?? caches.appendingPathComponent("CloudStreamMac/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let dir = disk
        Task.detached(priority: .utility) {
            Self.pruneDisk(at: dir)
        }
    }

    /// Cache identity: the URL plus the request headers that select what the
    /// host returns, so one credential's artwork is never served for another.
    /// Memory identity: one entry per rendition of a file. The disk file is
    /// the original and is shared by all of them.
    nonisolated static func memoryKey(for urlString: String, headers: [String: String]?, rendition: ArtworkRendition) -> String {
        let key = cacheKey(for: urlString, headers: headers)
        return rendition == .full ? key : key + "\n@\(rendition.maxDimension)"
    }

    nonisolated static func cacheKey(for urlString: String, headers: [String: String]?) -> String {
        let scoped = sanitizedHeaders(headers)
        guard !scoped.isEmpty else { return urlString }
        let fields = scoped.map { "\($0.key.lowercased()):\($0.value)" }.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(fields.utf8)).map { String(format: "%02x", $0) }.joined()
        return urlString + "\n" + digest
    }

    private func diskURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
        let hexString = hash.map { String(format: "%02x", $0) }.joined()
        return disk.appendingPathComponent("\(hexString).img")
    }

    /// Fast synchronous memory-only cache hit. Zero latency, zero flicker.
    func synchronousMemoryImage(for urlString: String, headers: [String: String]? = nil,
                                rendition: ArtworkRendition = .full) -> NSImage? {
        memory.object(forKey: Self.memoryKey(for: urlString, headers: headers, rendition: rendition))
    }

    /// nil when the artwork is unavailable: offline, rejected status or type,
    /// over the byte budget, or not a decodable image within the pixel budget.
    func image(for urlString: String, headers: [String: String]? = nil, rendition: ArtworkRendition = .full) async -> NSImage? {
        let key = Self.memoryKey(for: urlString, headers: headers, rendition: rendition)
        if let cached = memory.object(forKey: key) {
            return cached
        }
        if let existingTask = inFlight[key] {
            return await existingTask.value
        }

        let diskURL = diskURL(for: Self.cacheKey(for: urlString, headers: headers))
        let memoryCache = memory
        let session = session
        let maxBytes = maxResponseBytes
        let maxDimension = rendition.maxDimension

        // The user is looking at the placeholder: not background work.
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            if let size = (try? diskURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
               let img = (try? await Self.diskLoads.run({ () -> NSImage? in
                   guard let data = try? Data(contentsOf: diskURL) else { return nil }
                   return await Self.decode(data, maxDimension: maxDimension)
               })) ?? nil {
                memoryCache.set(img, forKey: key)
                // Pruning removes the least recently used file, not the oldest download.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: diskURL.path)
                return img
            }
            guard let remote = URL(string: urlString) else { return nil }
            var request = URLRequest(url: remote)
            request.timeoutInterval = 15
            for (field, value) in Self.sanitizedHeaders(headers) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            do {
                return try await Self.loads.run { [request] () -> NSImage? in
                    let loaded = try await BoundedHTTPResource.load(request, maxBytes: maxBytes, acceptsContentType: Self.acceptsImageType, session: session)
                    guard !Task.isCancelled else { return nil }
                    guard let img = await Self.decode(loaded, maxDimension: maxDimension) else {
                        DaemonLog.client("image.rejected", fields: ["reason": "undecodable_or_pixel_budget"])
                        return nil
                    }
                    if (try? loaded.write(to: diskURL, options: .atomic)) != nil {
                        Self.recordWrite(bytes: Int64(loaded.count), in: diskURL.deletingLastPathComponent())
                    }
                    memoryCache.set(img, forKey: key)
                    return img
                }
            } catch {
                // Never log the URL or headers: both can carry credentials.
                if let failure = error as? BoundedHTTPResource.Failure, failure == .tooLarge || failure == .unexpectedContentType {
                    DaemonLog.client("image.rejected", fields: ["reason": failure == .tooLarge ? "byte_budget" : "content_type"])
                }
                return nil
            }
        }

        inFlight[key] = task
        let result = await task.value
        // A clear or a newer load may already own this key.
        if inFlight[key] == task { inFlight.removeValue(forKey: key) }
        return result
    }

    /// Servers that mislabel artwork as generic binary are tolerated; text or
    /// markup (error pages, captive portals) is not an image.
    nonisolated static func acceptsImageType(_ mime: String?) -> Bool {
        guard let mime else { return true }
        return mime.hasPrefix("image/") || mime == "application/octet-stream" || mime == "binary/octet-stream"
    }

    /// Clears memory and disk (Settings ▸ Clear Cache).
    func clearAll() {
        memory.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        try? FileManager.default.removeItem(at: disk)
        try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        Self.bytesSincePrune.withLock { $0 = 0 }
    }

    /// Bytes the image cache currently occupies on disk.
    func diskUsageBytes() async -> Int64 {
        let dir = disk
        return await Task.detached(priority: .utility) {
            Self.cachedFiles(in: dir).reduce(0) { $0 + $1.size }
        }.value
    }

    /// Counts a new file and prunes once enough has been written since the
    /// last prune, so the ceiling holds during long sessions, not just at launch.
    nonisolated private static func recordWrite(bytes: Int64, in directory: URL) {
        let shouldPrune = bytesSincePrune.withLock { total in
            total += bytes
            guard total >= pruneIntervalBytes else { return false }
            total = 0
            return true
        }
        if shouldPrune {
            pruneDisk(at: directory)
        }
    }

    nonisolated private static func cachedFiles(in directory: URL) -> [(url: URL, size: Int64, modified: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Provider-supplied headers, minus anything that could corrupt the
    /// request (CR/LF injection, hop-by-hop or length headers).
    nonisolated static func sanitizedHeaders(_ headers: [String: String]?) -> [String: String] {
        guard let headers else { return [:] }
        let forbidden: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "upgrade"]
        return headers.filter { field, value in
            !field.isEmpty
                && !forbidden.contains(field.lowercased())
                && !field.contains(where: { $0.isNewline || $0 == ":" })
                && !value.contains(where: \.isNewline)
        }
    }

    /// Decoded off the main actor, within the pixel budget and downsampled
    /// to a display rendition, so dimensions cannot dictate memory use.
    /// Decodes within the shared pixel budget; nil for anything that is not
    /// an image within the source limit.
    nonisolated private static func decode(_ data: Data, maxDimension: Int) async -> NSImage? {
        guard let pixels = BoundedImageDecoder.sourcePixels(of: data) else { return nil }
        return (try? await decodes.run(cost: pixels) { BoundedImageDecoder.decode(data, maxDimension: maxDimension)?.image }) ?? nil
    }

    nonisolated private static func pruneDisk(at directory: URL) {
        let files = cachedFiles(in: directory)
        let totalBytes = files.reduce(0) { $0 + $1.size }
        guard totalBytes > maxDiskBytes else { return }
        var toFree = totalBytes - maxDiskBytes
        for file in files.sorted(by: { $0.modified < $1.modified }) where toFree > 0 {
            try? FileManager.default.removeItem(at: file.url)
            toFree -= file.size
        }
    }
}
