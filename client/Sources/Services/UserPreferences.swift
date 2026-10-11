import Foundation

/// App preferences (provider selection, repositories, download directory).
/// Stored in UserDefaults — never holds credentials (SEC-02: tokens are
/// ephemeral; sync account logins are explicitly out of scope for macOS v1).
@MainActor
@Observable
final class UserPreferences {
    static let shared = UserPreferences()

    @ObservationIgnored
    private let defaults: UserDefaults

    var activeProvider: String {
        didSet { defaults.set(activeProvider, forKey: "activeProvider") }
    }

    var repositoryURLs: [String] {
        didSet { defaults.set(repositoryURLs, forKey: "repositoryURLs") }
    }

    var downloadDirectory: URL {
        didSet { defaults.set(downloadDirectory.path, forKey: "downloadDirectory") }
    }

    var preferredQuality: Int {
        didSet { defaults.set(preferredQuality, forKey: "preferredQuality") }
    }

    var subtitleLanguage: String {
        didSet { defaults.set(subtitleLanguage, forKey: "subtitleLanguage") }
    }

    var subtitleFontSize: Double? {
        didSet { defaults.set(subtitleFontSize, forKey: "subtitleFontSize") }
    }

    var subtitleOutlineWidth: Double? {
        didSet { defaults.set(subtitleOutlineWidth, forKey: "subtitleOutlineWidth") }
    }

    var subtitleTextColor: String? {
        didSet { defaults.set(subtitleTextColor, forKey: "subtitleTextColor") }
    }

    var subtitleBackgroundColor: String? {
        didSet { defaults.set(subtitleBackgroundColor, forKey: "subtitleBackgroundColor") }
    }

    /// Auto-advance to the next episode when one finishes (Settings ▸ Playback).
    var continuousPlayback: Bool {
        didSet { defaults.set(continuousPlayback, forKey: "continuousPlayback") }
    }

    /// Zoom video to fill the player, cropping edges instead of showing
    /// letterbox bars when the video's shape differs from the screen's.
    var videoFillsScreen: Bool {
        didSet { defaults.set(videoFillsScreen, forKey: "videoFillsScreen") }
    }

    /// Simultaneous downloads overall (Android default: 3).
    var maxConcurrentDownloads: Int {
        didSet { defaults.set(maxConcurrentDownloads, forKey: "maxConcurrentDownloads") }
    }

    /// Simultaneous downloads per provider: hammering one host with a whole
    /// season in parallel gets IPs rate-limited or banned.
    var maxDownloadsPerProvider: Int {
        didSet { defaults.set(maxDownloadsPerProvider, forKey: "maxDownloadsPerProvider") }
    }

    static let downloadConcurrencyRange = BackupPreferencePolicy.downloadConcurrencyRange

    var autoAddDownloadsToLibrary: Bool {
        didSet { defaults.set(autoAddDownloadsToLibrary, forKey: "autoAddDownloadsToLibrary") }
    }

    var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") }
    }

    /// Starting a Plan-to-Watch title moves it to Watching; finishing it
    /// moves it to Completed (Settings ▸ Library).
    var autoUpdateLibraryStatus: Bool {
        didSet { defaults.set(autoUpdateLibraryStatus, forKey: "autoUpdateLibraryStatus") }
    }

    /// What happens when an episode with a saved position is played.
    var resumeBehavior: ResumeBehavior {
        didSet { defaults.set(resumeBehavior.rawValue, forKey: "resumeBehavior") }
    }

    // MARK: Playback (Offline-Features-Plan Phase 4)

    /// Seconds of "Up Next" countdown before auto-advancing; 0 = advance
    /// only when the episode ends.
    var nextEpisodeCountdown: Int {
        didSet { defaults.set(nextEpisodeCountdown, forKey: "nextEpisodeCountdown") }
    }

    /// ←/→ seek step (Shift doubles it).
    var seekStepSeconds: Double {
        didSet { defaults.set(seekStepSeconds, forKey: "seekStepSeconds") }
    }

    /// The manual "Skip" jump for files without chapter markers (Android's
    /// "skip op" = 85 s).
    var manualSkipSeconds: Double {
        didSet { defaults.set(manualSkipSeconds, forKey: "manualSkipSeconds") }
    }

    /// Re-apply the source, audio/subtitle language, subtitle offset and speed
    /// chosen for a title the next time it plays.
    var rememberPlaybackPerTitle: Bool {
        didSet { defaults.set(rememberPlaybackPerTitle, forKey: "rememberPlaybackPerTitle") }
    }

    var lastVolume: Double {
        didSet { defaults.set(lastVolume, forKey: "lastVolume") }
    }

    /// Highest quality picked automatically for playback; 0 = best.
    var playbackMaxQuality: Int {
        didSet { defaults.set(playbackMaxQuality, forKey: "playbackMaxQuality") }
    }

    /// Preferred sources (normalised keys), most preferred first.
    var sourcePriority: [String] {
        didSet { defaults.set(sourcePriority, forKey: "sourcePriority") }
    }

    /// Sources used only as a last resort.
    var avoidedSources: [String] {
        didSet { defaults.set(avoidedSources, forKey: "avoidedSources") }
    }

    /// Display names of every source seen in resolved links, so the priority
    /// editor can offer them. Capped.
    var knownSources: [String] {
        didSet { defaults.set(knownSources, forKey: "knownSources") }
    }

    var screenshotDirectory: URL {
        didSet { defaults.set(screenshotDirectory.path, forKey: "screenshotDirectory") }
    }

    // MARK: Subtitles (Offline-Features-Plan Phase 5)

    /// Turn subtitles on automatically in the first available language of
    /// `preferredSubtitleLanguages`.
    var autoSelectSubtitles: Bool {
        didSet { defaults.set(autoSelectSubtitles, forKey: "autoSelectSubtitles") }
    }

    /// Ordered language codes (ISO 639-1), most wanted first.
    var preferredSubtitleLanguages: [String] {
        didSet { defaults.set(preferredSubtitleLanguages, forKey: "preferredSubtitleLanguages") }
    }

    /// nil = mpv default font.
    var subtitleFont: String? {
        didSet { defaults.set(subtitleFont, forKey: "subtitleFont") }
    }

    var subtitleBold: Bool {
        didSet { defaults.set(subtitleBold, forKey: "subtitleBold") }
    }

    var subtitleShadowOffset: Double {
        didSet { defaults.set(subtitleShadowOffset, forKey: "subtitleShadowOffset") }
    }

    /// mpv `sub-pos`: 100 = bottom edge, lower values move subtitles up.
    var subtitlePosition: Int {
        didSet { defaults.set(subtitlePosition, forKey: "subtitlePosition") }
    }

    var sourcePreferences: SourcePreferences {
        SourcePreferences(priority: sourcePriority, avoided: Set(avoidedSources), maxQuality: playbackMaxQuality)
    }

    static let knownSourcesLimit = 200

    /// Remembers source names from resolved links (most recent first).
    func noteSources(_ names: [String]) {
        var current = knownSources
        var changed = false
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = LinkRanker.sourceKey(trimmed)
            if !current.contains(where: { LinkRanker.sourceKey($0) == key }) {
                current.insert(trimmed, at: 0)
                changed = true
            }
        }
        if changed { knownSources = Array(current.prefix(Self.knownSourcesLimit)) }
    }

    /// Provider whose homepage Home shows (Phase 6).
    var discoverProvider: String {
        didSet { defaults.set(discoverProvider, forKey: "discoverProvider") }
    }

    /// Home sections the user hid.
    var showDiscoverOnHome: Bool {
        didSet { defaults.set(showDiscoverOnHome, forKey: "showDiscoverOnHome") }
    }

    /// Periodically check Watching series for new episodes (Phase 6).
    var checkForNewEpisodes: Bool {
        didSet { defaults.set(checkForNewEpisodes, forKey: "checkForNewEpisodes") }
    }

    var notifyNewEpisodes: Bool {
        didSet { defaults.set(notifyNewEpisodes, forKey: "notifyNewEpisodes") }
    }

    /// The library collection or page Home's shelf shows.
    var homeShelf: HomeShelf {
        didSet { defaults.set(homeShelf.storageValue, forKey: "homeShelf") }
    }

    /// Sort and filters of each library collection, keyed by
    /// `LibraryCollection.rawValue`.
    var libraryViewOptions: [String: LibraryViewOptions] {
        didSet { defaults.set(try? JSONEncoder().encode(libraryViewOptions), forKey: "libraryViewOptions") }
    }

    var recentlySearched: [SearchResultDto] {
        didSet {
            defaults.set(try? JSONEncoder().encode(Array(recentlySearched.prefix(8))), forKey: "recentlySearched")
        }
    }

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        self.activeProvider = defaults.string(forKey: "activeProvider") ?? ""
        self.repositoryURLs = defaults.stringArray(forKey: "repositoryURLs") ?? []
        if let raw = defaults.string(forKey: "downloadDirectory"), !raw.isEmpty {
            self.downloadDirectory = URL(fileURLWithPath: raw)
        } else {
            self.downloadDirectory = AppEnvironment.directory("Downloads") ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        self.preferredQuality = defaults.integer(forKey: "preferredQuality")
        self.subtitleLanguage = defaults.string(forKey: "subtitleLanguage") ?? "en"
        self.subtitleFontSize = defaults.object(forKey: "subtitleFontSize") as? Double
        self.subtitleOutlineWidth = defaults.object(forKey: "subtitleOutlineWidth") as? Double
        // Builds ≤ 1.1 persisted ARGB; mpv expects RGBA (SubtitleColor doc).
        self.subtitleTextColor = SubtitleColor.migratingLegacy(defaults.string(forKey: "subtitleTextColor"))
        self.subtitleBackgroundColor = SubtitleColor.migratingLegacy(defaults.string(forKey: "subtitleBackgroundColor"))
        self.continuousPlayback = defaults.object(forKey: "continuousPlayback") as? Bool ?? true
        self.videoFillsScreen = defaults.bool(forKey: "videoFillsScreen")
        self.maxConcurrentDownloads = Self.clampedConcurrency(defaults.object(forKey: "maxConcurrentDownloads") as? Int, fallback: 3)
        self.maxDownloadsPerProvider = Self.clampedConcurrency(defaults.object(forKey: "maxDownloadsPerProvider") as? Int, fallback: 2)
        self.autoAddDownloadsToLibrary = defaults.object(forKey: "autoAddDownloadsToLibrary") as? Bool ?? true
        self.onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        self.autoUpdateLibraryStatus = defaults.object(forKey: "autoUpdateLibraryStatus") as? Bool ?? true
        self.resumeBehavior = ResumeBehavior(rawValue: defaults.string(forKey: "resumeBehavior") ?? "") ?? .ask
        self.nextEpisodeCountdown = defaults.object(forKey: "nextEpisodeCountdown") as? Int ?? 10
        self.seekStepSeconds = (defaults.object(forKey: "seekStepSeconds") as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 10
        self.manualSkipSeconds = (defaults.object(forKey: "manualSkipSeconds") as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 85
        self.rememberPlaybackPerTitle = defaults.object(forKey: "rememberPlaybackPerTitle") as? Bool ?? true
        self.lastVolume = min(100, max(0, defaults.object(forKey: "lastVolume") as? Double ?? 100))
        self.playbackMaxQuality = defaults.integer(forKey: "playbackMaxQuality")
        self.sourcePriority = defaults.stringArray(forKey: "sourcePriority") ?? []
        self.avoidedSources = defaults.stringArray(forKey: "avoidedSources") ?? []
        self.knownSources = defaults.stringArray(forKey: "knownSources") ?? []
        self.discoverProvider = defaults.string(forKey: "discoverProvider") ?? ""
        self.checkForNewEpisodes = defaults.object(forKey: "checkForNewEpisodes") as? Bool ?? true
        self.autoBackupEnabled = defaults.object(forKey: "autoBackupEnabled") as? Bool ?? true
        self.requireUnlock = defaults.bool(forKey: "requireUnlock")
        self.indexInSpotlight = defaults.object(forKey: "indexInSpotlight") as? Bool ?? true
        self.showMenuBarExtra = defaults.object(forKey: "showMenuBarExtra") as? Bool ?? true
        self.showDockBadge = defaults.object(forKey: "showDockBadge") as? Bool ?? true
        self.lockAfterMinutes = max(0, defaults.object(forKey: "lockAfterMinutes") as? Int ?? 15)
        self.notifyNewEpisodes = defaults.object(forKey: "notifyNewEpisodes") as? Bool ?? true
        self.showDiscoverOnHome = defaults.object(forKey: "showDiscoverOnHome") as? Bool ?? true
        self.autoSelectSubtitles = defaults.bool(forKey: "autoSelectSubtitles")
        let legacyLanguage = defaults.string(forKey: "subtitleLanguage") ?? "en"
        self.preferredSubtitleLanguages = defaults.stringArray(forKey: "preferredSubtitleLanguages") ?? [legacyLanguage]
        self.subtitleFont = defaults.string(forKey: "subtitleFont")
        self.subtitleBold = defaults.bool(forKey: "subtitleBold")
        self.subtitleShadowOffset = defaults.object(forKey: "subtitleShadowOffset") as? Double ?? 0
        self.subtitlePosition = min(150, max(0, defaults.object(forKey: "subtitlePosition") as? Int ?? 100))
        if let raw = defaults.string(forKey: "screenshotDirectory"), !raw.isEmpty {
            self.screenshotDirectory = URL(fileURLWithPath: raw)
        } else {
            self.screenshotDirectory = AppEnvironment.directory("Screenshots") ?? (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory).appendingPathComponent("CloudStream", isDirectory: true)
        }
        self.homeShelf = Self.homeShelf(from: defaults.object(forKey: "homeShelf"))
        self.libraryViewOptions = defaults.data(forKey: "libraryViewOptions")
            .flatMap { try? JSONDecoder().decode([String: LibraryViewOptions].self, from: $0) } ?? [:]
        if let data = defaults.data(forKey: "recentlySearched"),
           let decoded = try? JSONDecoder().decode([SearchResultDto].self, from: data) {
            self.recentlySearched = decoded
        } else {
            self.recentlySearched = []
        }
    }

    /// Earlier versions stored a `WatchType` raw value.
    static func homeShelf(from stored: Any?) -> HomeShelf {
        switch stored {
        case let value as String: HomeShelf(storageValue: value) ?? .default
        case let value as Int: WatchType(rawValue: value).map { .collection(LibraryCollection($0)) } ?? .default
        default: .default
        }
    }

    private static func clampedConcurrency(_ stored: Int?, fallback: Int) -> Int {
        guard let stored, stored > 0 else { return fallback }
        return min(max(stored, downloadConcurrencyRange.lowerBound), downloadConcurrencyRange.upperBound)
    }

    var repositoryMigrationComplete: Bool {
        get { defaults.bool(forKey: "repositoryMigrationComplete.v1") }
        set { defaults.set(newValue, forKey: "repositoryMigrationComplete.v1") }
    }

    func rememberSearch(_ result: SearchResultDto) {
        var current = recentlySearched.filter { $0.id != result.id }
        current.insert(result, at: 0)
        recentlySearched = Array(current.prefix(8))
    }

    func forgetSearch(_ result: SearchResultDto) {
        recentlySearched.removeAll { $0.id == result.id }
    }

    // MARK: - Backup (Phase 7)

    /// Preference keys that travel in a backup: behaviour and appearance
    /// only — no paths (machine-specific), no onboarding/migration flags, no
    /// search history.
    static var backupKeys: [String] { BackupPreferencePolicy.keys }

    func backupValues() -> [String: BackupValue] {
        var result: [String: BackupValue] = [:]
        for key in Self.backupKeys {
            if let raw = defaults.object(forKey: key), let value = BackupValue(any: raw) {
                result[key] = value
            }
        }
        return result
    }

    /// Restores whitelisted values through the typed properties (so observers
    /// update and invalid values are normalised). Unknown keys are ignored.
    func applyBackupValues(_ input: [String: BackupValue]) throws {
        let values = try BackupPreferencePolicy.validated(input)
        func bool(_ key: String) -> Bool? { if case .bool(let v)? = values[key] { return v }; return nil }
        func int(_ key: String) -> Int? {
            switch values[key] { case .int(let v)?: return v; case .double(let v)?: return Int(exactly: v); default: return nil }
        }
        func double(_ key: String) -> Double? {
            switch values[key] { case .double(let v)?: return v; case .int(let v)?: return Double(v); default: return nil }
        }
        func string(_ key: String) -> String? { if case .string(let v)? = values[key] { return v }; return nil }
        func strings(_ key: String) -> [String]? { if case .strings(let v)? = values[key] { return v }; return nil }

        if let v = bool("continuousPlayback") { continuousPlayback = v }
        if let v = bool("videoFillsScreen") { videoFillsScreen = v }
        if let v = int("maxConcurrentDownloads") { maxConcurrentDownloads = Self.clampedConcurrency(v, fallback: maxConcurrentDownloads) }
        if let v = int("maxDownloadsPerProvider") { maxDownloadsPerProvider = Self.clampedConcurrency(v, fallback: maxDownloadsPerProvider) }
        if let v = bool("autoAddDownloadsToLibrary") { autoAddDownloadsToLibrary = v }
        if let v = int("preferredQuality"), v >= 0 { preferredQuality = v }
        if let v = string("subtitleLanguage") { subtitleLanguage = v }
        if let v = double("subtitleFontSize"), (10...200).contains(v) { subtitleFontSize = v }
        if let v = double("subtitleOutlineWidth"), (0...20).contains(v) { subtitleOutlineWidth = v }
        if let v = string("subtitleTextColor") { subtitleTextColor = v }
        if let v = string("subtitleBackgroundColor") { subtitleBackgroundColor = v }
        if let v = bool("autoUpdateLibraryStatus") { autoUpdateLibraryStatus = v }
        if let v = string("resumeBehavior").flatMap(ResumeBehavior.init(rawValue:)) { resumeBehavior = v }
        if let v = int("nextEpisodeCountdown"), (0...120).contains(v) { nextEpisodeCountdown = v }
        if let v = double("seekStepSeconds"), v > 0, v <= 300 { seekStepSeconds = v }
        if let v = double("manualSkipSeconds"), v > 0, v <= 600 { manualSkipSeconds = v }
        if let v = bool("rememberPlaybackPerTitle") { rememberPlaybackPerTitle = v }
        if let v = int("playbackMaxQuality"), v >= 0 { playbackMaxQuality = v }
        if let v = strings("sourcePriority") { sourcePriority = v.map(LinkRanker.sourceKey) }
        if let v = strings("avoidedSources") { avoidedSources = v.map(LinkRanker.sourceKey) }
        if let v = strings("knownSources") { noteSources(v) }
        if let v = bool("autoSelectSubtitles") { autoSelectSubtitles = v }
        if let v = strings("preferredSubtitleLanguages") { preferredSubtitleLanguages = v }
        if let v = string("subtitleFont") { subtitleFont = v }
        if let v = bool("subtitleBold") { subtitleBold = v }
        if let v = double("subtitleShadowOffset"), (0...10).contains(v) { subtitleShadowOffset = v }
        if let v = int("subtitlePosition") { subtitlePosition = min(150, max(0, v)) }
        if let v = string("discoverProvider") { discoverProvider = v }
        if let v = bool("showDiscoverOnHome") { showDiscoverOnHome = v }
        if let v = bool("checkForNewEpisodes") { checkForNewEpisodes = v }
        if let v = bool("notifyNewEpisodes") { notifyNewEpisodes = v }
        if let v = bool("autoBackupEnabled") { autoBackupEnabled = v }
        if let v = bool("indexInSpotlight") { indexInSpotlight = v }
        if let v = bool("showMenuBarExtra") { showMenuBarExtra = v }
        if let v = bool("showDockBadge") { showDockBadge = v }
    }

    /// Require Touch ID / password to open the app (Phase 7.3).
    var requireUnlock: Bool {
        didSet {
            defaults.set(requireUnlock, forKey: "requireUnlock")
            // The app lock also keeps library titles out of Spotlight (L4).
            if oldValue != requireUnlock { spotlightPreferenceChanged?() }
        }
    }

    /// Re-lock after the app was in the background this long; 0 = only on
    /// launch, sleep and user switch.
    var lockAfterMinutes: Int {
        didSet { defaults.set(lockAfterMinutes, forKey: "lockAfterMinutes") }
    }

    // MARK: System integration (Phase 9)

    /// Bound by the application-owned indexer. Keeping this a Foundation-only
    /// callback preserves preference validation in the isolated backup harness.
    @ObservationIgnored var spotlightPreferenceChanged: (@MainActor () -> Void)?

    var indexInSpotlight: Bool {
        didSet {
            defaults.set(indexInSpotlight, forKey: "indexInSpotlight")
            if oldValue != indexInSpotlight { spotlightPreferenceChanged?() }
        }
    }

    var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: "showMenuBarExtra") }
    }

    var showDockBadge: Bool {
        didSet { defaults.set(showDockBadge, forKey: "showDockBadge") }
    }

    /// Daily rolling backups in Application Support (Phase 7).
    var autoBackupEnabled: Bool {
        didSet { defaults.set(autoBackupEnabled, forKey: "autoBackupEnabled") }
    }

    /// Last successful automatic backup of one profile. Each profile has its
    /// own clock; the old app-wide value said nothing about which profile it
    /// covered, so it is not carried over.
    func lastAutoBackup(for profileID: UUID) -> Date? {
        (defaults.dictionary(forKey: "lastAutoBackupByProfile") as? [String: Date])?[profileID.uuidString]
    }

    func setLastAutoBackup(_ date: Date?, for profileID: UUID) {
        var values = (defaults.dictionary(forKey: "lastAutoBackupByProfile") as? [String: Date]) ?? [:]
        values[profileID.uuidString] = date
        defaults.set(values, forKey: "lastAutoBackupByProfile")
        autoBackupRevision &+= 1
    }

    /// Observation hook for the "last automatic backup" row.
    private(set) var autoBackupRevision: UInt64 = 0

    func clearSearchHistory() {
        recentlySearched = []
    }
}

enum ResumeBehavior: String, CaseIterable, Identifiable, Sendable {
    /// Android's resume dialog: "Resume from 34:12 / Start Over".
    case ask
    case alwaysResume
    case alwaysStartOver

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Ask Every Time"
        case .alwaysResume: return "Always Resume"
        case .alwaysStartOver: return "Always Start Over"
        }
    }
}
