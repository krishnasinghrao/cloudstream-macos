import AppKit
import SwiftUI

/// Owns the player NSWindow (ADR-0008). The main window stays alive beneath
/// playback; the system draws the traffic lights, so nothing in the player
/// UI compensates for chrome with hardcoded offsets.
///
/// The key event monitor is installed only while the player window is key,
/// consumes exactly the shortcut matrix it handles, and passes every other
/// event through — ⌘W/⌘Q/system shortcuts keep working during playback.
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()

    private var window: NSWindow?
    private var inputMonitor: PlayerInputMonitor?
    private weak var player: PlayerViewModel?
    /// Last aspect ratio the window was fitted to (D8) — refit only on change.
    private var fittedAspect: CGFloat?

    func present(player: PlayerViewModel) {
        self.player = player

        guard let window else {
            makeWindow(for: player)
            return
        }
        window.title = Self.title(for: player)
        if !window.isVisible || !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func closeWindow() {
        window?.performClose(nil)
    }

    /// Locks live resizing to the video's aspect ratio and, once per new
    /// aspect, fits the window to the video (D8) — QuickTime-style: natural
    /// size, scaled down to the screen, centered, never off-screen.
    func setVideoAspectRatio(_ size: NSSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        window.contentAspectRatio = size
        let aspect = size.width / size.height
        window.contentMinSize = Self.minimumContentSize(aspect: aspect, within: Self.usableArea(of: window.screen).size)
        guard !isFullScreen, fittedAspect.map({ abs($0 - aspect) > 0.01 }) ?? true else { return }
        fittedAspect = aspect

        let content = window.contentRect(forFrameRect: window.frame)
        let target = Self.fittedContentRect(
            videoSize: size,
            preferredBox: Self.userContentSize,
            around: NSPoint(x: content.midX, y: content.midY),
            in: Self.usableArea(of: window.screen),
        )
        window.setFrame(window.frameRect(forContentRect: target), display: true, animate: window.isVisible)
    }

    // MARK: - Window geometry

    /// Largest share of the usable screen area a fitted player may take.
    private static let maxScreenFraction: CGFloat = 0.85
    /// Smallest video size (long side × short side); below this the compact
    /// HUD and the picture itself stop being usable.
    static let minLongSide: CGFloat = 560
    static let minShortSide: CGFloat = 315
    /// The system full-screen transition runs about half a second; shorter
    /// feels like a jump rather than a zoom.
    private static let minTransitionDuration: TimeInterval = 0.5

    /// The smallest content size with the video's aspect whose long and short
    /// sides meet the minimums. A fixed 16:9 minimum would distort 4:3 video,
    /// and a fixed minimum width would make vertical video taller than the screen.
    static func minimumContentSize(aspect: CGFloat, within area: NSSize? = nil) -> NSSize {
        let wide = max(aspect, 1 / aspect) // long side ÷ short side
        let long = max(minLongSide, minShortSide * wide)
        let short = long / wide
        var size = aspect >= 1 ? NSSize(width: long, height: short) : NSSize(width: short, height: long)
        // A minimum the screen cannot hold would force the window off screen.
        if let area, area.width > 0, area.height > 0 {
            let shrink = min(1, area.width / size.width, area.height / size.height)
            size = NSSize(width: size.width * shrink, height: size.height * shrink)
        }
        return NSSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
    }
    private static let userSizeKey = "PlayerWindowUserContentSize"

    /// Size the user chose by resizing; automatic fits are never remembered.
    private static var userContentSize: NSSize? {
        get {
            let stored = AppEnvironment.defaults.string(forKey: userSizeKey).map(NSSizeFromString)
            return stored.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        }
        set { AppEnvironment.defaults.set(newValue.map(NSStringFromSize), forKey: userSizeKey) }
    }

    /// Screen area excluding the menu bar and Dock.
    private static func usableArea(of screen: NSScreen?) -> NSRect {
        (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// A rect with the video's aspect: sized to fit `preferredBox` (the user's
    /// last chosen size) or else at most the video's natural size; never over
    /// `maxScreenFraction` of `area`; centered on `center` and moved as
    /// needed to lie fully inside `area`.
    static func fittedContentRect(
        videoSize: NSSize,
        preferredBox: NSSize? = nil,
        around center: NSPoint,
        in area: NSRect,
    ) -> NSRect {
        let bound = NSSize(width: area.width * maxScreenFraction, height: area.height * maxScreenFraction)
        let box = preferredBox ?? videoSize
        let minimum = minimumContentSize(aspect: videoSize.width / videoSize.height)
        let scale = max(
            // Tiny videos (e.g. 320×240) are enlarged to the minimum size.
            minimum.width / videoSize.width,
            min(
                box.width / videoSize.width, box.height / videoSize.height,
                bound.width / videoSize.width, bound.height / videoSize.height,
            ),
        )
        // Extreme aspect ratios (ultra-wide, vertical) can make the minimum
        // size larger than the screen. The usable area wins: a window that
        // does not fit cannot be moved back on screen.
        let fitted = min(scale, area.width / videoSize.width, area.height / videoSize.height)
        let size = NSSize(width: (videoSize.width * fitted).rounded(.down), height: (videoSize.height * fitted).rounded(.down))
        var rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, area.minX), area.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, area.minY), area.maxY - rect.height)
        rect.origin = NSPoint(x: rect.origin.x.rounded(), y: rect.origin.y.rounded())
        return rect
    }

    /// The screen the library window is on, so playback opens where the
    /// user is looking rather than wherever the last player window was.
    private func presentationScreen() -> NSScreen? {
        NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeMain }?.screen ?? NSScreen.main
    }

    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    func toggleFullScreen() {
        guard let window else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: - Window lifecycle

    private func makeWindow(for player: PlayerViewModel) {
        // Opens at a 16:9 fit (the video's real shape isn't known until the
        // stream loads; setVideoAspectRatio refits around the center). No
        // frame autosave: a restored frame belongs to a previous video and
        // possibly another display.
        let area = Self.usableArea(of: presentationScreen())
        let initial = Self.fittedContentRect(
            videoSize: NSSize(width: 1280, height: 720),
            preferredBox: Self.userContentSize,
            around: NSPoint(x: area.midX, y: area.midY),
            in: area,
        )
        let window = NSWindow(
            contentRect: initial,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = Self.title(for: player)
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        // The HUD auto-hide relies on mouse-moved events reaching the local
        // monitor; windows don't deliver them by default (U3).
        window.acceptsMouseMovedEvents = true
        // The HUD draws the centered title; a transparent titlebar would
        // draw the window title a second time next to the traffic lights.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.contentMinSize = Self.minimumContentSize(aspect: 16.0 / 9.0)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        // This controller owns the window's size (aspect lock, aspect-aware
        // minimum, fitting). A hosting view installed as the window's
        // contentView feeds its SwiftUI layout back into the window: it
        // rewrote the min size to the HUD's and resized the window on its
        // own. Hosted inside a plain container it just fills its bounds.
        let hostingView = NSHostingView(rootView: PlayerScreenView(player: player))
        hostingView.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: initial.size))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        window.contentView = container

        self.window = window
        player.windowController = self
        installMonitor(for: player)
        window.makeKeyAndOrderFront(nil)
    }

    static func title(for player: PlayerViewModel) -> String {
        player.displayTitle
    }

    /// Only a live resize is the user's choice; remember it for future videos.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window, !isFullScreen else { return }
        Self.userContentSize = window.contentRect(forFrameRect: window.frame).size
    }

    func windowWillClose(_ notification: Notification) {
        removeMonitor()
        // The window is already closing — the VM must not ask to close it
        // again (T11).
        player?.close(fromWindow: true)
        window = nil
        fittedAspect = nil
    }

    func setControlsVisible(_ visible: Bool) {
        guard let window, !isFullScreen else { return }
        let alpha: CGFloat = visible ? 1.0 : 0.0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.standardWindowButton(.closeButton)?.superview?.animator().alphaValue = alpha
        }
    }

    // MARK: - Full screen transition

    /// Windowed frame to return to when leaving full screen.
    private var windowedFrame: NSRect?

    /// The system transition scales a snapshot of the window to the screen's
    /// shape, stretching the video whenever the two aspects differ. Like
    /// QuickTime, animate the real window frame instead: the video view
    /// re-renders at each size and stays aspect-correct throughout.
    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        windowedFrame = window.frame
        return [window]
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        guard let screenFrame = window.screen?.frame else { return }
        window.styleMask.insert(.fullScreen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = max(duration, Self.minTransitionDuration)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(screenFrame, display: true)
        }
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        let target = windowedFrame ?? window.frame
        window.styleMask.remove(.fullScreen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = max(duration, Self.minTransitionDuration)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        }
    }

    /// If a custom transition fails, restore a consistent windowed state.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        if let windowedFrame {
            window.setFrame(windowedFrame, display: true)
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        player?.isFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        player?.isFullScreen = false
        setControlsVisible(player?.hudVisible ?? true)
    }

    // MARK: - Keyboard

    /// The player's shortcut matrix. Returns true when the event was consumed
    /// (monitor swallows it); unmatched keys pass through to the system.
    func handleKey(_ event: NSEvent, player: PlayerViewModel) -> Bool {
        // Bare keys only: ⌘M (Minimize), ⌘F, ⌘K, ⌃⌘F… must reach the menu
        // bar and the system (D3). Arrow keys carry .numericPad/.function,
        // which are not modifiers.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Shift+←/→ doubles the seek step; every other shortcut is bare.
        let step = player.preferences.seekStepSeconds
        if modifiers == .shift, event.keyCode == 123 || event.keyCode == 124 {
            player.seek(by: event.keyCode == 123 ? -step * 2 : step * 2)
            player.showHUD()
            return true
        }
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 49, 40: // Space, K
            // Holding Space must not machine-gun play/pause.
            guard !event.isARepeat else { return true }
            player.togglePlayPause()
        case 123, 38: // ← / J: seek back one step
            player.seek(by: -step)
            player.showHUD()
        case 124, 37: // → / L: seek forward one step
            player.seek(by: step)
            player.showHUD()
        case 1: // S: skip the active intro/credits, else the manual skip
            guard !event.isARepeat else { return true }
            if player.activeSkip != nil { player.skipActiveSegment() } else { player.manualSkip() }
        case 47: // .: next frame
            player.frameStep(forward: true)
        case 43: // ,: previous frame
            player.frameStep(forward: false)
        case 126: // ↑ volume +5
            player.setVolume(min(100, player.volume + 5))
            player.showHUD()
        case 125: // ↓ volume -5
            player.setVolume(max(0, player.volume - 5))
            player.showHUD()
        case 3: // F
            guard !event.isARepeat else { return true }
            toggleFullScreen()
        case 46: // M
            guard !event.isARepeat else { return true }
            player.toggleMute()
            player.showHUD()
        case 6: // Z: subtitle delay −0.1 s
            player.adjustSubtitleDelay(by: -0.1)
            player.showHUD()
        case 7: // X: subtitle delay +0.1 s
            player.adjustSubtitleDelay(by: 0.1)
            player.showHUD()
        case 45: // N
            guard !event.isARepeat else { return true }
            player.playNextEpisode()
        case 53: // Esc: dismiss Up Next, leave fullscreen, then close
            if player.upNext != nil {
                player.dismissUpNext()
            } else if isFullScreen {
                toggleFullScreen()
            } else {
                player.close()
            }
        default:
            return false
        }
        return true
    }

    private func installMonitor(for player: PlayerViewModel) {
        removeMonitor()
        let controller = self
        inputMonitor = PlayerInputMonitor(
            // Only intercept keys aimed at the player window; typing in the
            // main window's fields is untouched even while playback runs.
            targetsEvent: { event in event.window === controller.window },
            keyHandler: { event in
                guard let player = controller.player else { return false }
                return controller.handleKey(event, player: player)
            },
            activityHandler: {
                controller.player?.showHUD()
            },
        )
    }

    private func removeMonitor() {
        inputMonitor = nil
    }
}

/// Local key/mouse monitors scoped to the player window. Key events the
/// handler does not consume are returned to the responder chain — the old
/// implementation returned `nil` for everything, eating ⌘W/⌘Q/⌘Tab.
final class PlayerInputMonitor {
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private let targetsEvent: (NSEvent) -> Bool
    private let keyHandler: (NSEvent) -> Bool
    private let activityHandler: () -> Void

    init(
        targetsEvent: @escaping (NSEvent) -> Bool,
        keyHandler: @escaping (NSEvent) -> Bool,
        activityHandler: @escaping () -> Void,
    ) {
        self.targetsEvent = targetsEvent
        self.keyHandler = keyHandler
        self.activityHandler = activityHandler

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.targetsEvent(event) else { return event }
            // Text editing in the player window (none today, but future-proof):
            // never steal keys from an active field editor.
            // Local monitors are always invoked on the main thread.
            let editingText = MainActor.assumeIsolated {
                NSApp.keyWindow?.firstResponder is NSTextView
            }
            if editingText {
                return event
            }
            return self.keyHandler(event) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.targetsEvent(event) else { return event }
            self.activityHandler()
            return event
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }
}
