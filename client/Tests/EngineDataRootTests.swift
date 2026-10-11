import XCTest
@testable import CloudStream

final class EngineDataRootTests: XCTestCase {
    func testTestHostUsesAnIsolatedRoot() {
        let root = EngineDataRoot.url(environment: ["CS_IN_MEMORY_DB": "1"])
        XCTAssertTrue(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(root.path.contains(".cloudstream-macos"))
    }

    func testProductionUsesTheUsersDataRoot() {
        XCTAssertEqual(EngineDataRoot.url(environment: [:]).lastPathComponent, ".cloudstream-macos")
    }

    func testEngineEnvironmentInheritsNothingFromTheApp() {
        let temporary = URL(fileURLWithPath: "/private/tmp/engine-tmp", isDirectory: true)
        let inherited = ["SSH_AUTH_SOCK": "/tmp/agent.sock", "DOCKER_HOST": "unix:///var/run/docker.sock",
                         "JAVA_TOOL_OPTIONS": "-javaagent:/tmp/x.jar", "AWS_SECRET_ACCESS_KEY": "secret", "LANG": "fr_FR.UTF-8"]
        let environment = DaemonSupervisor.engineEnvironment(temporary: temporary, inherited: inherited)
        XCTAssertEqual(Set(environment.keys), ["HOME", "TMPDIR", "PATH", "LANG"])
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["TMPDIR"], "/private/tmp/engine-tmp/")
        XCTAssertEqual(environment["LANG"], "fr_FR.UTF-8")
        XCTAssertEqual(DaemonSupervisor.engineEnvironment(temporary: temporary, inherited: ["LANG": "$(evil)"])["LANG"], "en_US.UTF-8")
    }

    func testLaunchOptionsRequestWorkerIsolationAndCarryTheSandboxRequirement() throws {
        var policy = ManagedExtensionPolicy()
        policy.requireSandbox = true
        let line = DaemonLaunchOptions(policy: policy, safeMode: false).encodedLine()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(json["isolation"] as? String, "worker")
        XCTAssertEqual((json["policy"] as? [String: Any])?["requireSandbox"] as? Bool, true)
    }
}
