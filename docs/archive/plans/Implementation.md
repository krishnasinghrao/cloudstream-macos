# Implementation Blueprint: CloudStream macOS

## 1. Project Directory & Workspace Layout

The macOS project is structured into two cleanly isolated sub-projects within `macos/`:

```
macos/
├── daemon/                           # Headless Kotlin JVM Scraper Daemon
│   ├── build.gradle.kts             # Gradle config (imports root :library)
│   ├── src/main/kotlin/
│   │   └── com/lagradost/macos/
│   │       ├── Main.kt              # Daemon entry point & Ktor server
│   │       ├── PluginBridge.kt      # dex2jar + URLClassLoader runner with cache
│   │       ├── AndroidStubs.kt      # Pure-Java stubs for Context, Base64, Log, Uri
│   │       ├── RepositoryService.kt # repo.json parser & SHA-256 verifier
│   │       ├── ProviderExecutor.kt  # Parallel search & loadLinks runner
│   │       ├── Sanitizer.kt         # URL tracking parameter stripper
│   │       └── models/              # IPC JSON Data Transfer Objects
│   └── src/main/resources/
│       └── application.conf         # Ktor server configuration
│
├── client/                           # Native macOS SwiftUI Application
│   ├── CloudStreamMac.xcodeproj     # Xcode project configuration
│   ├── Sources/
│   │   ├── App/                     # App lifecycle & Process Supervisor
│   │   ├── UI/
│   │   │   ├── Navigation/          # Apple TV Sidebar & Clean Window Chrome
│   │   │   ├── Home/                # HomeView, Provider Switcher, Continue Watching
│   │   │   ├── Search/              # Dedicated Search Bar, History, & Results Grid
│   │   │   ├── Library/             # LibraryView with WatchType Tabs (Watching, Plan, Done)
│   │   │   ├── Details/             # Apple TV Media Hero, Action Pills, Episode List
│   │   │   ├── Player/              # CAMetalLayer libmpv Viewport & Floating Glass HUD
│   │   │   ├── Downloads/           # Downloaded Titles & Active Queue Table
│   │   │   └── Settings/            # Extensions, Providers, Player, Accounts
│   │   ├── ViewModels/              # Observable state controllers
│   │   ├── Services/                # IPC client, JIT downloader, mpv player
│   │   └── Models/                  # SwiftData / local state entities
│   └── Resources/
│       ├── Assets.xcassets          # App icons & imagery
│       └── Binaries/                # Universal ffmpeg & libmpv frameworks
│
└── scripts/                          # Packaging and distribution automation
    ├── bundle_runtime.sh            # jlink minimal JVM extractor
    └── package_app.sh               # Notarized universal .dmg packager
```

---

## 2. Kotlin Daemon Implementation (`engine`)

### 2.1 Android API Stubbing (`AndroidStubs.kt`)
To guarantee that community `.cs3` plugins run on pure OpenJDK without throwing `NoClassDefFoundError`:

```kotlin
package android.content

// Pure Java Stub for android.content.Context
class Context {
    fun getPackageName(): String = "com.lagradost.cloudstream3"
    fun getFilesDir(): java.io.File = java.io.File(System.getProperty("user.home"), ".cloudstream-macos/data")
    fun getCacheDir(): java.io.File = java.io.File(System.getProperty("user.home"), ".cloudstream-macos/cache")
    fun getString(resId: Int, vararg formatArgs: Any?): String = ""
}

package android.util

// Pure Java Stub for android.util.Base64
object Base64 {
    const val DEFAULT = 0
    const val NO_WRAP = 2
    const val URL_SAFE = 8

    fun encodeToString(input: ByteArray, flags: Int): String {
        return java.util.Base64.getEncoder().encodeToString(input)
    }

    fun decode(str: String, flags: Int): ByteArray {
        return java.util.Base64.getDecoder().decode(str.trim())
    }
}

// Pure Java Stub for android.util.Log
object Log {
    fun d(tag: String, msg: String): Int = 0.also { println("DEBUG: [$tag] $msg") }
    fun i(tag: String, msg: String): Int = 0.also { println("INFO:  [$tag] $msg") }
    fun w(tag: String, msg: String): Int = 0.also { println("WARN:  [$tag] $msg") }
    fun e(tag: String, msg: String, tr: Throwable? = null): Int = 0.also { 
        System.err.println("ERROR: [$tag] $msg")
        tr?.printStackTrace()
    }
}
```

### 2.2 Cached Plugin Loading Pipeline (`PluginBridge.kt`)
```kotlin
package com.lagradost.macos

import com.googlecode.dex2jar.tools.Dex2jarCmd
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.plugins.BasePlugin
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.net.URLClassLoader
import java.security.MessageDigest
import java.util.zip.ZipFile

object PluginBridge {
    private val json = Json { ignoreUnknownKeys = true }
    private val loadedPlugins = mutableMapOf<String, MainAPI>()

    fun loadPluginFromCs3(cs3File: File): MainAPI? {
        val cacheDir = File(System.getProperty("user.home"), ".cloudstream-macos/cache/plugins")
        cacheDir.mkdirs()

        // 1. Compute SHA-256 for persistent bytecode caching
        val fileHash = computeSha256(cs3File)
        val cachedJar = File(cacheDir, "$fileHash.jar")

        var pluginClassName: String? = null

        // 2. Extract manifest.json
        ZipFile(cs3File).use { zip ->
            val manifestEntry = zip.getEntry("manifest.json") ?: return null
            val manifestJson = zip.getInputStream(manifestEntry).bufferedReader().readText()
            pluginClassName = json.parseToJsonElement(manifestJson)
                .jsonObject["pluginClassName"]?.jsonPrimitive?.content
        }

        if (pluginClassName == null) return null

        // 3. Convert classes.dex -> classes.jar if not already cached
        if (!cachedJar.exists() || cachedJar.length() == 0L) {
            try {
                Dex2jarCmd.main("-f", "-o", cachedJar.absolutePath, cs3File.absolutePath)
            } catch (t: Throwable) {
                System.err.println("dex2jar translation failed for ${cs3File.name}: ${t.message}")
                return null
            }
        }

        // 4. Load class using URLClassLoader with CloudStream :library and AndroidStubs on classpath
        val classLoader = URLClassLoader(arrayOf(cachedJar.toURI().toURL()), this::class.java.classLoader)
        val clazz = classLoader.loadClass(pluginClassName)
        val instance = clazz.getDeclaredConstructor().newInstance()

        // Handle both Plugin and BasePlugin registration
        if (instance is BasePlugin) {
            instance.load()
        }

        val mainApi = (instance as? MainAPI) ?: return null
        loadedPlugins[mainApi.name] = mainApi
        return mainApi
    }

    fun getAllLoadedPlugins(): List<MainAPI> = loadedPlugins.values.toList()

    private fun computeSha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(8192)
            var bytesRead: Int
            while (stream.read(buffer).also { bytesRead = it } != -1) {
                digest.update(buffer, 0, bytesRead)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
```

---

## 3. Swift Frontend Implementation (`client`)

### 3.1 Embedded Metal Video Player (`MpvPlayerView.swift`)
Integrates `libmpv` with modern `CAMetalLayer` and `mpv_render_context`:

```swift
import SwiftUI
import AppKit
import MetalKit

struct MpvPlayerView: NSViewRepresentable {
    let streamURL: String
    let headers: [String: String]
    @Binding var isPlaying: Bool
    @Binding var currentTime: Double
    @Binding var duration: Double

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView()
        view.setupMpv(streamURL: streamURL, headers: headers)
        return view
    }

    func updateNSView(_ nsView: MetalVideoView, context: Context) {
        nsView.setPlaying(isPlaying)
    }
}

final class MetalVideoView: NSView {
    private var mpv: OpaquePointer?
    private var mpvContext: OpaquePointer?
    private var metalLayer: CAMetalLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        self.layer = layer
        self.metalLayer = layer
    }

    required init?(coder: NSCoder) { fatalError() }

    func setupMpv(streamURL: String, headers: [String: String]) {
        guard let mpv = mpv_create() else { return }
        self.mpv = mpv

        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "gpu-api", "metal")
        mpv_set_option_string(mpv, "hwdec", "auto")

        let headerStr = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        mpv_set_option_string(mpv, "http-header-fields", headerStr)

        mpv_initialize(mpv)

        var metalParams = mpv_metal_init_params(layer: Unmanaged.passUnretained(metalLayer!).toOpaque())
        var renderParams: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: MPV_RENDER_API_TYPE_METAL)),
            mpv_render_param(type: MPV_RENDER_PARAM_METAL_INIT_PARAMS, data: &metalParams),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
        ]

        mpv_render_context_create(&self.mpvContext, mpv, &renderParams)

        var args: [UnsafePointer<CChar>?] = [
            UnsafePointer(strdup("loadfile")),
            UnsafePointer(strdup(streamURL)),
            nil
        ]
        mpv_command(mpv, &args)
    }

    func setPlaying(_ play: Bool) {
        var flag: Int32 = play ? 0 : 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    deinit {
        if let mpvContext = mpvContext { mpv_render_context_free(mpvContext) }
        if let mpv = mpv { mpv_destroy(mpv) }
    }
}
```

### 3.2 Downloader with Just-In-Time Link Resolution (`DownloadService.swift`)
```swift
import Foundation

@Observable
final class DownloadService {
    static let shared = DownloadService()

    struct QueueItem: Identifiable {
        let id = UUID()
        let title: String
        let episodeName: String
        let pluginId: String
        let mediaData: String
        let destinationURL: URL
        var progress: Double = 0.0
        var speed: String = "Queued"
        var isCompleted: Bool = false
    }

    var queue: [QueueItem] = []
    private var activeProcess: Process?

    func enqueue(item: QueueItem) {
        queue.append(item)
        processNextInQueue()
    }

    private func processNextInQueue() {
        guard activeProcess == nil, let nextItem = queue.first(where: { !$0.isCompleted && $0.progress == 0 }) else { return }

        Task {
            // JIT link resolution right before download to avoid expired host tokens
            guard let link = await DaemonClient.shared.resolveBestLink(pluginId: nextItem.pluginId, data: nextItem.mediaData) else {
                print("Failed to resolve link for: \(nextItem.title)")
                return
            }

            self.executeDownload(item: nextItem, streamURL: link.url, headers: link.headers)
        }
    }

    private func executeDownload(item: QueueItem, streamURL: String, headers: [String: String]) {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil, inDirectory: "Binaries") else { return }

        let formattedHeaders = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y",
            "-headers", formattedHeaders,
            "-i", streamURL,
            "-c", "copy",
            "-movflags", "+faststart",
            item.destinationURL.path
        ]

        let pipe = Pipe()
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self.parseFfmpegProgress(for: item.id, line: output) }
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.markCompleted(id: item.id)
                self?.activeProcess = nil
                self?.processNextInQueue()
            }
        }

        self.activeProcess = proc
        try? proc.run()
    }

    private func parseFfmpegProgress(for id: UUID, line: String) {
        // Parse time=HH:MM:SS.ms and compute progress
    }

    private func markCompleted(id: UUID) {
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            queue[idx].isCompleted = true
            queue[idx].speed = "Completed"
        }
    }
}
```

### 3.3 Asynchronous Daemon Supervisor (`DaemonSupervisor.swift`)
```swift
import Foundation

@Observable
final class DaemonSupervisor {
    static let shared = DaemonSupervisor()

    enum DaemonState {
        case initializing
        case ready(port: Int)
        case error(String)
    }

    private(set) var state: DaemonState = .initializing
    private(set) var authToken: String = ""
    private var process: Process?

    func start() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.authToken = bytes.map { String(format: "%02hhx", $0) }.joined()
        let port = Int.random(in: 49152...65535)

        guard let jrePath = Bundle.main.path(forResource: "java", ofType: nil, inDirectory: "runtime/bin"),
              let daemonJar = Bundle.main.path(forResource: "daemon", ofType: "jar", inDirectory: "tools") else {
            self.state = .error("Bundled runtime or daemon jar missing")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: jrePath)
        proc.arguments = ["-jar", daemonJar, String(port), authToken]
        
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.state = .initializing
                self?.start() // Auto-restart
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.pollHealth(port: port)
        } catch {
            self.state = .error("Failed to spawn process: \(error.localizedDescription)")
        }
    }

    private func pollHealth(port: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { timer in
            URLSession.shared.dataTask(with: url) { _, res, _ in
                if (res as? HTTPURLResponse)?.statusCode == 200 {
                    DispatchQueue.main.async {
                        self.state = .ready(port: port)
                        timer.invalidate()
                    }
                }
            }.resume()
        }
    }
}
```

### 3.4 Asynchronous IPC Client (`DaemonClient.swift`)
```swift
import Foundation

actor DaemonClient {
    static let shared = DaemonClient()

    struct StreamLink: Codable {
        let url: String
        let name: String
        let quality: String
        let headers: [String: String]
    }

    func resolveBestLink(pluginId: String, data: String) async -> StreamLink? {
        guard case .ready(let port) = DaemonSupervisor.shared.state else { return nil }
        guard var components = URLComponents(string: "http://127.0.0.1:\(port)/links") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "plugin", value: pluginId),
            URLQueryItem(name: "data", value: data)
        ]

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(DaemonSupervisor.shared.authToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let links = try JSONDecoder().decode([StreamLink].self, from: data)
            return links.first // Best quality or first mirror
        } catch {
            return nil
        }
    }
}
```

### 3.5 SwiftData Local Persistence (`LibraryDatabase.swift`)
```swift
import SwiftData
import Foundation

@Model
final class StoredMediaItem {
    @Attribute(.unique) var id: String
    var title: String
    var posterURL: String?
    var bannerURL: String?
    var providerName: String
    var watchTypeRaw: Int // 0=Watching, 1=Completed, 2=OnHold, 3=Dropped, 4=PlanToWatch
    var lastWatchedSeason: Int?
    var lastWatchedEpisode: Int?
    var progressSeconds: Double
    var totalDurationSeconds: Double
    var lastUpdated: Date

    init(id: String, title: String, posterURL: String?, providerName: String, watchType: Int) {
        self.id = id
        self.title = title
        self.posterURL = posterURL
        self.providerName = providerName
        self.watchTypeRaw = watchType
        self.progressSeconds = 0.0
        self.totalDurationSeconds = 0.0
        self.lastUpdated = Date()
    }
}
```

### 3.6 macOS Control Center & Media Keys (`NowPlayingService.swift`)
Integrates `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for native hardware media key support:

```swift
import MediaPlayer
import AppKit

@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()
    private let center = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()

    func setupRemoteCommands(player: MetalVideoView) {
        commandCenter.playCommand.addTarget { _ in
            player.setPlaying(true)
            return .success
        }
        commandCenter.pauseCommand.addTarget { _ in
            player.setPlaying(false)
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            // Toggle playback state
            return .success
        }
    }

    func updateNowPlaying(title: String, episodeTitle: String, duration: Double, elapsed: Double) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = episodeTitle
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        center.nowPlayingInfo = info
    }
}
```

---

## 4. Packaging & Notarization Scripts (`scripts`)

### 4.1 Minimal JRE Extractor (`scripts/bundle_runtime.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="client/Resources/runtime"
rm -rf "$OUTPUT_DIR"

# Assemble minimal OpenJDK modular runtime via jlink (~35 MB)
jlink \
  --add-modules java.base,java.net.http,java.sql,java.desktop,jdk.unsupported \
  --strip-debug \
  --no-man-pages \
  --no-header-files \
  --compress=2 \
  --output "$OUTPUT_DIR"

echo "Minimal OpenJDK JRE bundled at $OUTPUT_DIR"
```

### 4.2 Notarized Universal DMG Builder (`scripts/package_app.sh`)
```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CloudStream"
BUILD_DIR="build/Release"
DMG_PATH="build/${APP_NAME}.dmg"

echo "Building Xcode Release Archive..."
xcodebuild -project client/CloudStreamMac.xcodeproj \
  -scheme CloudStreamMac \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  archive -archivePath "build/${APP_NAME}.xcarchive"

echo "Signing with Hardened Runtime..."
codesign --force --options runtime --deep --sign "Developer ID Application: YourName" \
  --entitlements client/CloudStreamMac.entitlements \
  "build/${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app"

echo "Creating DMG..."
hdiutil create -volname "${APP_NAME}" -srcfolder "build/${APP_NAME}.xcarchive/Products/Applications" -ov -format UDZO "${DMG_PATH}"

echo "Notarizing with Apple Notary Service..."
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "AC_PASSWORD" --wait

xcrun stapler staple "${DMG_PATH}"
echo "Release DMG created and stapled at ${DMG_PATH}"
```
