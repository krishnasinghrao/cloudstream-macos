import Foundation

/// Everything Settings ▸ Clear Cache removes: regenerable data only. Video is
/// never cached on disk (mpv buffers in memory per session); downloads,
/// installed extensions and the library are user data and are not touched.
@MainActor
enum AppCaches {
    static func diskUsageBytes() async -> Int64 {
        let images = await ImageCache.shared.diskUsageBytes()
        return images + (AppEnvironment.isIsolated() ? 0 : Int64(URLCache.shared.currentDiskUsage))
    }

    static func clearAll() {
        ImageCache.shared.clearAll()
        // Responses cached by URLSession.shared (e.g. search suggestions).
        if !AppEnvironment.isIsolated() { URLCache.shared.removeAllCachedResponses() }
    }
}
