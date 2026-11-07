import Foundation

/// A semantic version (semver.org precedence): `1.2.3`, `1.2.3-beta.2`.
/// Build metadata (`+…`) is accepted and ignored. Tags may carry a `v` or
/// `macos-v` prefix (the release workflow accepts both).
struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("macos-") { value.removeFirst("macos-".count) }
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        var pre: [String] = []
        if let dash = value.firstIndex(of: "-") {
            pre = value[value.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            value = String(value[..<dash])
            guard !pre.isEmpty, pre.allSatisfy({ identifier in
                !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else { return nil }
        }
        let core = value.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch, prerelease: pre)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A pre-release sorts before its release.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true    // numeric identifiers sort first
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// One published release that can update this app.
struct UpdateRelease: Equatable, Sendable {
    let version: SemanticVersion
    let tag: String
    let pageURL: URL
    let publishedAt: Date?
    let dmg: Asset
    /// `<hex>  CloudStream.dmg`, published beside the disk image by CI.
    let checksumAsset: Asset?

    struct Asset: Equatable, Sendable {
        let name: String
        let url: URL
        let size: Int64
        /// GitHub's own SHA-256 of the uploaded file (`digest: "sha256:…"`).
        let sha256: String?
    }
}

/// Reads the GitHub Releases API (`GET /repos/{owner}/{repo}/releases/latest`).
enum UpdateFeed {
    static let dmgName = "CloudStream.dmg"
    static let checksumName = "CloudStream.dmg.sha256"
    /// A release disk image is about 90 MB; anything far larger is not ours.
    static let maximumDMGBytes: Int64 = 512 * 1024 * 1024

    enum FeedError: LocalizedError, Equatable {
        case malformed
        case noDiskImage(String)
        case untrustedURL(String)

        var errorDescription: String? {
            switch self {
            case .malformed: "The update information from GitHub couldn’t be read."
            case .noDiskImage(let tag): "Release \(tag) has no \(UpdateFeed.dmgName) to install."
            case .untrustedURL(let url): "The update download isn’t hosted by GitHub (\(url))."
            }
        }
    }

    /// `owner/repo`, from Info.plist (`CSUpdateRepository`), or nil when this
    /// build has no update source (it then never checks).
    static func repository(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let value = info?["CSUpdateRepository"] as? String else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0.allSatisfy(allowed.contains) && $0 != "." && $0 != ".." })
        else { return nil }
        return value
    }

    static func latestReleaseURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// Hosts an update may be fetched from: the API, the release download
    /// URL, and the storage hosts GitHub redirects release assets to.
    static let trustedHosts: Set<String> = [
        "api.github.com", "github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    static func isTrusted(_ url: URL?, hosts: Set<String> = trustedHosts) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        if url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 {
            return hosts.contains(host)
        }
        // Tests serve fixtures over loopback HTTP; only an explicit host list allows it.
        return url.scheme?.lowercased() == "http" && hosts.contains(host) && (host == "127.0.0.1" || host == "localhost")
    }

    /// Decodes the API response. Returns nil for a draft or pre-release (the
    /// `latest` endpoint never returns those; this keeps it so).
    static func decode(_ data: Data, hosts: Set<String> = trustedHosts) throws -> UpdateRelease? {
        struct Wire: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
            let published_at: String?
            let assets: [WireAsset]
        }
        struct WireAsset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64
            let state: String?
            let digest: String?
        }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) } catch { throw FeedError.malformed }
        if wire.draft == true || wire.prerelease == true { return nil }
        guard let version = SemanticVersion(wire.tag_name), !version.isPrerelease else { return nil }
        guard let page = URL(string: wire.html_url), isTrusted(page, hosts: hosts) else { throw FeedError.untrustedURL(wire.html_url) }

        func asset(named name: String) throws -> UpdateRelease.Asset? {
            guard let raw = wire.assets.first(where: { $0.name == name && ($0.state ?? "uploaded") == "uploaded" }) else { return nil }
            guard let url = URL(string: raw.browser_download_url), isTrusted(url, hosts: hosts) else {
                throw FeedError.untrustedURL(raw.browser_download_url)
            }
            var digest: String?
            if let value = raw.digest?.lowercased(), value.hasPrefix("sha256:") {
                let hex = String(value.dropFirst("sha256:".count))
                if isSHA256(hex) { digest = hex }
            }
            return .init(name: raw.name, url: url, size: raw.size, sha256: digest)
        }
        guard let dmg = try asset(named: dmgName), dmg.size > 0, dmg.size <= maximumDMGBytes else {
            throw FeedError.noDiskImage(wire.tag_name)
        }
        let published = wire.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return UpdateRelease(version: version, tag: wire.tag_name, pageURL: page, publishedAt: published,
                             dmg: dmg, checksumAsset: try asset(named: checksumName))
    }

    /// The SHA-256 in a `shasum -a 256` line for `name`.
    static func checksum(fromShasumOutput text: String, for name: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            var file = fields[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }   // binary-mode marker
            let hex = fields[0].lowercased()
            if file == name, isSHA256(hex) { return hex }
        }
        return nil
    }

    static func isSHA256(_ hex: String) -> Bool {
        hex.count == 64 && hex.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
