import XCTest
@testable import CloudStream

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testHostedServicesUsePrivateLocationsAndPreferences() throws {
        XCTAssertTrue(AppEnvironment.isIsolated())
        XCTAssertTrue(AppEnvironment.isUnitTestHost)
        let root = try XCTUnwrap(AppEnvironment.root())
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        for url in [EngineDataRoot.url(), DaemonSupervisor.logDirectory(),
                    BackupService.shared.backupsDirectory, UserPreferences.shared.downloadDirectory,
                    UserPreferences.shared.screenshotDirectory] {
            XCTAssertTrue(url.path.hasPrefix(root.path + "/"), url.path)
        }
        let key = "isolation-probe-\(UUID().uuidString)"
        let defaults = AppEnvironment.defaults
        defaults.set("private", forKey: key)
        defer { defaults.removeObject(forKey: key) }
        XCTAssertEqual(AppEnvironment.defaults.string(forKey: key), "private")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func testIsolatedCredentialsNeverRequireKeychainAccess() throws {
        let id = "test-provider-\(UUID().uuidString)"
        try ProviderCredentialStore.save("fixture-secret", for: id)
        defer { ProviderCredentialStore.delete(for: id) }
        XCTAssertEqual(ProviderCredentialStore.credential(for: id), "fixture-secret")
        XCTAssertTrue(ProviderCredentialStore.storedProviderIds().contains(id))
        ProviderCredentialStore.delete(for: id)
        XCTAssertNil(ProviderCredentialStore.credential(for: id))
    }

    func testExplicitFixtureRootAndProductionRootRemainDistinct() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["CS_IN_MEMORY_DB": "1", "CS_TEST_ROOT": root.path]
        XCTAssertEqual(AppEnvironment.root(environment: environment), root)
        XCTAssertEqual(EngineDataRoot.url(environment: environment), root.appendingPathComponent("engine", isDirectory: true))
        XCTAssertNil(AppEnvironment.root(environment: [:]))
    }
}
