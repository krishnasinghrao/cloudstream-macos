import Foundation

/// URL-scheme routing (Offline-Features-Plan Phase 9). Pure: parses a URL
/// into a route; `AppState.handleDeepLink` performs it.
///
/// * `cloudstreamrepo://`, `cloudstream://`, `cs.repo://`, `cs3://` → add a repository
/// * `cloudstreamapp://search?q=<query>` → search
/// * `cloudstreamapp://open?provider=<name>&url=<result url>` → a title page
/// * `cloudstreamapp://continue` → resume the most recent title
/// * `cloudstreamapp://<query>` / `cloudstreamplayer://<query>` → search (legacy form)
enum DeepLinkRoute: Equatable {
    case addRepository(String)
    case search(String)
    case openTitle(provider: String, providerID: String? = nil, url: String)
    case continueWatching
    case navigate(AppDestination)
    case ignored
}

enum DeepLinkRouter {
    static let repositorySchemes: Set<String> = ["cloudstreamrepo", "cloudstream", "cs.repo", "cs3"]
    static let appSchemes: Set<String> = ["cloudstreamapp", "cloudstreamplayer"]
    static let maxLength = 4096

    static func route(_ url: URL) -> DeepLinkRoute {
        guard url.absoluteString.count <= maxLength else { return .ignored }
        let scheme = url.scheme?.lowercased() ?? ""
        if repositorySchemes.contains(scheme) {
            let target = DaemonClient.normalizeRepoUrl(url.absoluteString)
            return target.hasPrefix("https://") || target.hasPrefix("http://") ? .addRepository(target) : .ignored
        }
        guard appSchemes.contains(scheme) else { return .ignored }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String? {
            components?.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch url.host?.lowercased() {
        case "search":
            guard let text = query("q"), !text.isEmpty else { return .navigate(.search) }
            return .search(String(text.prefix(200)))
        case "open":
            guard let provider = query("provider"), !provider.isEmpty,
                  let target = query("url"), !target.isEmpty else { return .ignored }
            return .openTitle(provider: provider, providerID: query("providerId"), url: target)
        case "continue":
            return .continueWatching
        case "history":
            return .navigate(.history)
        case "downloads":
            return .navigate(.downloaded)
        default:
            let legacy = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).removingPercentEncoding ?? ""
            return legacy.isEmpty ? .navigate(.search) : .search(String(legacy.prefix(200)))
        }
    }

    /// Shareable link for a title (used by Handoff and "Copy Link").
    static func titleURL(provider: String, providerID: String? = nil, url: String) -> URL? {
        var components = URLComponents()
        components.scheme = "cloudstreamapp"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "url", value: url)]
        if let providerID, !providerID.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "providerId", value: providerID))
        }
        return components.url
    }
}
