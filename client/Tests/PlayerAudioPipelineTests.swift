import XCTest
@testable import CloudStream

@MainActor
final class PlayerAudioPipelineTests: XCTestCase {
    /// The mpv-engine tests need a real libmpv (and the /tmp fixture file);
    /// skip instead of flaking when CS_MPV_ENGINE_TESTS != 1 (P2-16).
    private func requireMpvEngine() throws {
        guard ProcessInfo.processInfo.environment["CS_MPV_ENGINE_TESTS"] == "1" else {
            throw XCTSkip("Set CS_MPV_ENGINE_TESTS=1 to run live mpv engine tests")
        }
    }

    func testMetalVideoViewInitializesWithAudioOutput() throws {
        try requireMpvEngine()
        let view = MetalVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        var propertiesChanged: [String] = []

        view.onPropertyChange = { name, _ in
            propertiesChanged.append(name)
        }

        view.setup(
            resource: try .authorizedLocal(URL(fileURLWithPath: "/tmp/test_stereo.mp4")),
            headers: [:],
            subtitles: [],
            audioTracks: [
                try .authorizedLocal(AudioTrackDto(url: "/tmp/test_stereo.mp4", label: "External Stereo", language: "en"),
                    file: URL(fileURLWithPath: "/tmp/test_stereo.mp4"))
            ],
            startAt: nil
        )

        XCTAssertTrue(view.isInitialized, "MetalVideoView should initialize successfully")

        // Wait a short time for file load and audio pipeline setup
        let exp = expectation(description: "Wait for property change")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        view.shutdown()
        XCTAssertFalse(view.isInitialized, "MetalVideoView should be torn down cleanly")
    }

    func testPlayerViewModelAudioTrackInitialSelection() {
        let vm = PlayerViewModel()
        XCTAssertNil(vm.activeAudioTrackId)
        XCTAssertTrue(vm.audioTracks.isEmpty)

        // When external tracks are present in link
        let testTracks: [MpvTrack] = [
            MpvTrack(id: 1, type: "audio", title: "m4a (128 kbps)", lang: "eng", codec: "aac"),
            MpvTrack(id: 2, type: "audio", title: "WebM Opus (160 kbps)", lang: "eng", codec: "opus")
        ]
        vm.updateTracks(testTracks)

        XCTAssertEqual(vm.audioTracks.count, 2)
        XCTAssertEqual(vm.audioTracks[0].label, "m4a (128 kbps) · eng · aac")
        XCTAssertEqual(vm.audioTracks[1].label, "WebM Opus (160 kbps) · eng · opus")

        // Selecting track updates activeAudioTrackId
        vm.selectAudioTrack(2)
        XCTAssertEqual(vm.activeAudioTrackId, 2)
    }

    func testSubtitleOffSetsCorrectValue() throws {
        try requireMpvEngine()
        let view = MetalVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.setup(
            resource: try .authorizedLocal(URL(fileURLWithPath: "/tmp/test_stereo.mp4")),
            headers: [:],
            subtitles: [],
            audioTracks: [],
            startAt: nil
        )

        // Selecting -1 should not crash and turn off subtitles cleanly
        view.selectSubtitleTrack(-1)
        view.selectAudioTrack(0)

        view.shutdown()
    }
}
