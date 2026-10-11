import XCTest
@testable import CloudStream

final class BackupValidationTests: XCTestCase {
    private func document() -> BackupDocument {
        BackupDocument(createdAt: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "fixture",
                       items: [], episodes: [], playback: [], preferences: [:], repositories: [], disabledProviders: [])
    }

    func testUntrustedHugeJSONIntegerFailsBeforeRestore() throws {
        var backup = document()
        backup.preferences = ["maxConcurrentDownloads": .double(1e100)]
        // Serialize raw DTOs to exercise hostile input, bypassing the guarded
        // export API exactly as an externally edited backup would.
        let data = try BackupDocument.encoder.encode(backup)
        XCTAssertThrowsError(try BackupDocument.decode(data)) {
            XCTAssertTrue($0.localizedDescription.contains("maxConcurrentDownloads"))
        }
    }

    func testFractionalAndNonFiniteIntegersAreRejected() {
        for number in [1.5, Double.nan, Double.infinity, -Double.infinity, Double(Int.max)] {
            XCTAssertThrowsError(try BackupPreferencePolicy.validated(["maxConcurrentDownloads": .double(number)]))
        }
        XCTAssertEqual(try BackupPreferencePolicy.validated(["maxConcurrentDownloads": .double(3)]),
                       ["maxConcurrentDownloads": .int(3)])
    }

    @MainActor func testActualPreferencesRejectPatchBeforeAnyMutation() throws {
        let name = "cloudstream-backup-validation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UserPreferences(defaults: defaults)
        let previousStep = preferences.seekStepSeconds
        XCTAssertThrowsError(try preferences.applyBackupValues([
            "seekStepSeconds": .double(30), "maxConcurrentDownloads": .double(1e100),
        ]))
        XCTAssertEqual(preferences.seekStepSeconds, previousStep)
        XCTAssertNil(defaults.object(forKey: "seekStepSeconds"))
        try preferences.applyBackupValues(["maxConcurrentDownloads": .double(3), "sourcePriority": .strings([" VidPlay "]),
                                          "downloadDirectory": .string("/etc")])
        XCTAssertEqual(preferences.maxConcurrentDownloads, 3)
        XCTAssertEqual(preferences.sourcePriority, ["vidplay"])
        XCTAssertNotEqual(preferences.downloadDirectory.path, "/etc")
    }

    func testValidSignedDelayAndPartialIntroArePreserved() throws {
        var backup = document()
        backup.playback = [.init(itemID: "legacy-title", audioLanguage: nil, subtitleLanguage: nil,
                                 subtitlesOff: false, subtitleDelay: -3.5, speed: 1.5, introStart: 10, introEnd: nil)]
        let decoded = try BackupDocument.decode(try backup.encoded())
        XCTAssertEqual(decoded.playback.first?.subtitleDelay, -3.5)
        backup.playback[0].introEnd = 5
        XCTAssertThrowsError(try backup.validate())
        backup.playback[0].introEnd = nil
        backup.playback[0].speed = .infinity
        XCTAssertThrowsError(try backup.validate())
    }

    func testInvalidHistoryPositionAndDateDoNotReachPersistence() {
        var backup = document()
        backup.episodes = [.init(itemID: "legacy-title", episodeData: "episode", season: 0, episode: 1,
                                 positionSeconds: -1, durationSeconds: 100, watched: false, updatedAt: Date())]
        XCTAssertThrowsError(try backup.validate())
        backup.episodes[0].positionSeconds = 0
        XCTAssertNoThrow(try backup.validate())
        backup.episodes[0].positionSeconds = 1e100
        XCTAssertThrowsError(try backup.validate(), "finite seconds must also fit UI integer timestamps")
        backup.episodes[0].positionSeconds = 0
        backup.createdAt = Date(timeIntervalSince1970: 1e100)
        XCTAssertThrowsError(try backup.encoded())
        XCTAssertThrowsError(try BackupDocument.timestamp(backup.createdAt))
    }

    func testUniqueSafetyPublicationCannotOverwriteAnExistingBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let firstName = BackupFilePolicy.automaticName(profileID: profile, reason: "before-restore", date: date)
        let secondName = BackupFilePolicy.automaticName(profileID: profile, reason: "before-restore", date: date)
        XCTAssertNotEqual(firstName, secondName)
        XCTAssertTrue(firstName.contains(profile.uuidString))
        XCTAssertNotEqual(firstName, BackupFilePolicy.automaticName(profileID: UUID(), reason: "before-restore", date: date))
        let first = directory.appendingPathComponent(firstName)
        let second = directory.appendingPathComponent(secondName)
        try BackupFilePolicy.writeUnique(Data("first".utf8), to: first)
        try BackupFilePolicy.writeUnique(Data("second".utf8), to: second)
        XCTAssertThrowsError(try BackupFilePolicy.writeUnique(Data("replacement".utf8), to: first))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2,
                       "publication must clean every temporary file")
    }
}
