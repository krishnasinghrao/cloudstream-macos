import XCTest
@testable import CloudStream

@MainActor
final class BackupLockTests: XCTestCase {
    func testLockedBackupEntryPointsRejectBeforeReadingOrWriting() async throws {
        let preferences = UserPreferences.shared
        let wasRequired = preferences.requireUnlock
        let oldAuthenticator = AppLock.shared.authenticator
        preferences.requireUnlock = true
        AppLock.shared.lockIfEnabled(reason: "test")
        let service = BackupService()
        let url = try XCTUnwrap(AppEnvironment.directory("locked-backup"))
            .appendingPathComponent("does-not-exist.json")
        let document = BackupDocument(createdAt: Date(), appVersion: "test", items: [], episodes: [],
            playback: [], preferences: [:], repositories: [], disabledProviders: [])
        let pending = BackupService.Pending(source: .mac(document),
            snapshot: .init(items: [], episodes: [], playback: []), document: document)
        XCTAssertThrowsError(try service.makeDocument(appState: nil)) {
            XCTAssertEqual($0 as? BackupService.RestoreError, .locked)
        }
        XCTAssertThrowsError(try service.read(url)) {
            XCTAssertEqual($0 as? BackupService.RestoreError, .locked)
        }
        XCTAssertThrowsError(try service.write(document, to: url)) {
            XCTAssertEqual($0 as? BackupService.RestoreError, .locked)
        }
        do {
            _ = try await service.restore(pending, mode: .replace, includePreferences: true, appState: nil)
            XCTFail("Locked restore must fail")
        } catch {
            XCTAssertEqual(error as? BackupService.RestoreError, .locked)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        AppLock.shared.authenticator = { _ in .success(()) }
        await AppLock.shared.unlock()
        AppLock.shared.authenticator = oldAuthenticator
        preferences.requireUnlock = wasRequired
    }
}
