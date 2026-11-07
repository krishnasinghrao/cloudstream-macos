import Darwin
import Foundation
import Network
import Synchronization
import WebKit

/// Whether a host names this Mac or the local network (security audit
/// 2026-11, H1 and L2). Pure and thread-safe: used by WebKit navigation
/// delegates and by the bounded artwork/subtitle loader.
///
/// Mirrors the engine's `WebDestination` and `RepositoryTransport.isPublicAddress`:
/// loopback, private, link-local, CGNAT, multicast, documentation and
/// transition ranges are local; so are `localhost`, `.local`, `.home.arpa`,
/// `.internal`, `.lan` and single-label names (completed with the Mac's search
/// domains). IPv4 is read the way browsers read it, so `2130706433`, `0x7f.1`
/// and `0177.0.0.1` are all 127.0.0.1.
enum LocalDestination {
    /// Tests serve fixtures from loopback. Never set by the app.
    static let testingAllowsLoopback = Atomic<Bool>(false)

    private static let localSuffixes = [".localhost", ".local", ".home.arpa", ".internal", ".lan"]

    /// [url] is an http(s)/ws(s) URL whose host is local. Other schemes are the caller's decision.
    static func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme) else { return false }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return true }
        return isLocalHost(host)
    }

    static func isLocalHost(_ raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        let allowLoopback = testingAllowsLoopback.load(ordering: .relaxed)
        if host.isEmpty { return true }
        if host == "localhost" || host.hasSuffix(".localhost") { return !allowLoopback }
        if localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return true }
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            if allowLoopback, bytes == [UInt8](repeating: 0, count: 15) + [1] { return false }
            return !isPublic(bytes)
        }
        if lastLabelIsNumeric(host) {
            guard let bytes = ipv4(host) else { return true }
            if allowLoopback, bytes[0] == 127 { return false }
            return !isPublic(bytes)
        }
        return !host.contains(".")
    }

    /// Ordinary public unicast only (IANA special-purpose registries), as the engine decides.
    static func isPublic(_ b: [UInt8]) -> Bool {
        if b.count == 16 {
            // IPv4-mapped: the engine's resolver sees the IPv4 address.
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return isPublic(Array(b[12..<16])) }
            guard (0x20...0x3f).contains(b[0]) else { return false }
            if b[0] == 0x3f, b[1] == 0xff, b[2] < 16 { return false }               // 3fff::/20 documentation
            if b[0] == 0x20, b[1] == 0x02 { return false }                           // 6to4
            if b[0] == 0x20, b[1] == 0x01, b[2] < 2 || (b[2] == 0x0d && b[3] == 0xb8) { return false } // Teredo, IETF, 2001:db8::/32
            return true
        }
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _): return false
        case (172, 16...31, _), (100, 64...127, _), (198, 18...19, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 88, 99), (198, 51, 100), (203, 0, 113): return false
        default: return b[0] < 224
        }
    }

    private static func lastLabelIsNumeric(_ host: String) -> Bool {
        guard let last = host.split(separator: ".").last else { return false }
        if last.allSatisfy(\.isASCIIDigit) { return true }
        return last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    /// WHATWG IPv4: one to four parts, each decimal, octal (leading 0) or hex (0x).
    static func ipv4(_ host: String) -> [UInt8]? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard let number = number(part) else { return nil }
            numbers.append(number)
        }
        guard numbers.dropLast().allSatisfy({ $0 <= 255 }), let last = numbers.last,
              last < (UInt64(1) << (8 * UInt64(5 - numbers.count))) else { return nil }
        var value = last
        for (index, part) in numbers.dropLast().enumerated() { value += part << (8 * UInt64(3 - index)) }
        return (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(3 - $0))) }
    }

    private static func number(_ part: String) -> UInt64? {
        guard !part.isEmpty else { return nil }
        let (digits, radix): (Substring, Int)
        if part.hasPrefix("0x") { (digits, radix) = (part.dropFirst(2), 16) }
        else if part.count > 1, part.hasPrefix("0") { (digits, radix) = (part.dropFirst(), 8) }
        else { (digits, radix) = (Substring(part), 10) }
        if digits.isEmpty { return 0 }
        guard digits.count <= 12 else { return nil }
        return UInt64(digits, radix: radix)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Confines WebKit content an extension asks the app to load: WebViewResolver
/// pages, extension-created WebViews and challenge solves (security audit
/// 2026-11, H1).
///
/// Such pages run in the app, outside the extension sandbox, and the
/// extension reads what they return (script results, page events, cookies).
/// Without confinement an extension could open `http://127.0.0.1:<port>/`, a
/// router or a cloud metadata address and read the answer, which the worker
/// sandbox and the egress proxy otherwise refuse.
///
/// 1. Every request goes through the engine's web-content SOCKS5 proxy, which
///    resolves names itself and connects only to public addresses (so DNS
///    rebinding cannot pass it). `allowFailover` is off: if the proxy is
///    unreachable, nothing loads.
/// 2. WebKit connects to loopback and link-local destinations without asking a
///    proxy, so a content rule list blocks every request (pages, frames,
///    fetch/XHR, media) to those addresses and to other local spellings.
/// 3. Navigation delegates refuse local hosts as well (``LocalDestination``).
///
/// If the proxy settings or the rule list are unavailable, ``prepare(_:)``
/// returns false and the caller loads nothing.
@MainActor
final class WebContentNetworkPolicy {
    static let shared = WebContentNetworkPolicy()

    /// Where the proxy comes from; tests supply their own.
    var egressSource: @MainActor () async throws -> WebContentEgressDto = { try await DaemonClient.shared.webContentEgress() }

    private var generation: UInt64 = 0
    private var cached: (generation: UInt64, value: WebContentEgressDto)?
    private var compiled: [Bool: WKContentRuleList] = [:]

    /// A new engine has a new proxy (and password).
    func reset() {
        generation &+= 1
        cached = nil
    }

    /// Confines [configuration]'s website data store and content controller.
    /// False: the content must not be loaded.
    func prepare(_ configuration: WKWebViewConfiguration) async -> Bool {
        guard let rules = await ruleList() else {
            DaemonLog.client("webcontent.refused", fields: ["reason": "rules"])
            return false
        }
        guard let settings = await egressSettings(),
              ["127.0.0.1", "::1"].contains(settings.host),
              let port = UInt16(exactly: settings.port).flatMap(NWEndpoint.Port.init(rawValue:)), port.rawValue > 0 else {
            DaemonLog.client("webcontent.refused", fields: ["reason": "proxy"])
            return false
        }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(settings.host), port: port))
        proxy.applyCredential(username: settings.username, password: settings.password)
        proxy.allowFailover = false
        configuration.websiteDataStore.proxyConfigurations = [proxy]
        configuration.userContentController.add(rules)
        return true
    }

    /// Whether a navigation delegate may let [url] load.
    func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return false }
        return !LocalDestination.isLocal(url)
    }

    private func egressSettings() async -> WebContentEgressDto? {
        if let cached, cached.generation == generation { return cached.value }
        let generation = generation
        guard let value = try? await egressSource(), self.generation == generation else { return nil }
        cached = (generation, value)
        return value
    }

    private func ruleList() async -> WKContentRuleList? {
        let blockLoopback = !LocalDestination.testingAllowsLoopback.load(ordering: .relaxed)
        if let list = compiled[blockLoopback] { return list }
        let identifier = blockLoopback ? "cloudstream.web-content.v1" : "cloudstream.web-content.loopback-tests.v1"
        do {
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: Self.rulesJSON(blockLoopback: blockLoopback)) else { return nil }
            compiled[blockLoopback] = list
            return list
        } catch {
            DaemonLog.client("webcontent.rules_failed", fields: ["error": error.localizedDescription])
            return nil
        }
    }

    /// Host patterns blocked for every resource type. WebKit matches the
    /// canonical URL (lowercase host, dotted-decimal IPv4, bracketed IPv6).
    nonisolated static func blockedHostPatterns(blockLoopback: Bool) -> [String] {
        let quad = "[0-9]+\\.[0-9]+[:/?#]"
        var hosts = [
            // Link-local (WebKit connects without the proxy) and the local network.
            "169\\.254\\.\(quad)", "\\[fe[89ab]",
            "10\\.[0-9]+\\.\(quad)", "192\\.168\\.\(quad)",
            "172\\.1[6-9]\\.\(quad)", "172\\.2[0-9]\\.\(quad)", "172\\.3[0-1]\\.\(quad)",
            "100\\.6[4-9]\\.\(quad)", "100\\.[7-9][0-9]\\.\(quad)", "100\\.1[0-1][0-9]\\.\(quad)", "100\\.12[0-7]\\.\(quad)",
            "\\[f[cd]",
            "[^/?#:@]*\\.local[:/?#]", "[^/?#:@]*\\.home\\.arpa[:/?#]", "[^/?#:@]*\\.internal[:/?#]", "[^/?#:@]*\\.lan[:/?#]",
            // Single-label names resolve through the search domains to LAN hosts.
            "[a-z0-9_-]+[:/?#]",
        ]
        if blockLoopback {
            hosts += [
                "localhost[:/?#]", "[^/?#:@]*\\.localhost[:/?#]",
                "127\\.[0-9]+\\.\(quad)", "0\\.[0-9]+\\.\(quad)",
                "\\[::", "\\[0*:0*:0*:0*:0*:", // ::1, ::, ::ffff:… and their long spellings
            ]
        }
        return hosts.map { "^[a-z][a-z0-9.+-]*://([^/?#@]*@)?" + $0 }
    }

    nonisolated static func rulesJSON(blockLoopback: Bool) -> String {
        let rules = blockedHostPatterns(blockLoopback: blockLoopback).map { pattern -> [String: Any] in
            ["trigger": ["url-filter": pattern], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
