import AppKit
import SwiftUI
import XCTest
@testable import CloudStream

final class LibraryArtworkLayoutTests: XCTestCase {
    func testLayoutPreferencesDecodeOlderAndUnknownValuesAndKeepDataIdentity() throws {
        let old = try JSONDecoder().decode(LibraryViewOptions.self, from: Data(#"{"sort":"alphabetical","provider":"P"}"#.utf8))
        XCTAssertEqual(old.displayMode, .grid)
        let future = try JSONDecoder().decode(LibraryViewOptions.self, from: Data(#"{"displayMode":"future","reversed":true}"#.utf8))
        XCTAssertEqual(future.displayMode, .grid)
        XCTAssertTrue(future.reversed)
        for mode in LibraryDisplayMode.allCases {
            var changed = old
            changed.displayMode = mode
            XCTAssertEqual(try JSONDecoder().decode(LibraryViewOptions.self, from: JSONEncoder().encode(changed)), changed)
            XCTAssertEqual(changed.orderingAndFilters, old.orderingAndFilters)
        }
    }

    func testCategoriesUseMeasuredShapesAndKeepUnknownArtworkHonest() {
        XCTAssertEqual(LibraryArtworkCategory(geometry: ArtworkGeometry(width: 1280, height: 720)), .landscape)
        XCTAssertEqual(LibraryArtworkCategory(geometry: ArtworkGeometry(width: 600, height: 900)), .portrait)
        XCTAssertEqual(LibraryArtworkCategory(geometry: ArtworkGeometry(width: 800, height: 800)), .square)
        XCTAssertEqual(LibraryArtworkCategory(geometry: nil), .unclassified)
    }

    func testGalleryRowsFillTheWidthAndGiveLandscapeArtworkItsTrueShape() throws {
        typealias Layout = LibraryGalleryLayout
        let ids = ["portrait-a", "landscape-a", "portrait-b", "landscape-b", "square", "portrait-c", "landscape-c"]
        let ratios: [String: CGFloat] = ["portrait-a": 2 / 3, "landscape-a": 16 / 9, "portrait-b": 2 / 3,
                                         "landscape-b": 16 / 9, "square": 1, "portrait-c": 2 / 3, "landscape-c": 16 / 9]
        let width: CGFloat = 1000
        let target = Layout.targetHeight(width: width)
        let membership = Layout.rowMembership(ids: ids, ratios: ratios, width: width, targetHeight: target)
        XCTAssertEqual(membership.flatMap { $0 }, ids, "every title appears once, in sort order")
        let rows = Layout.rows(membership: membership, ratios: ratios, width: width, targetHeight: target)
        XCTAssertGreaterThan(rows.count, 1)
        for row in rows.dropLast() {
            let used = row.slots.map(\.width).reduce(0, +) + CGFloat(row.slots.count - 1) * Layout.spacing
            XCTAssertEqual(used, width, accuracy: 0.5, "full rows reach both edges")
            XCTAssertLessThanOrEqual(row.height, target * Layout.maximumStretch)
            XCTAssertGreaterThan(row.height, target * 0.6)
        }
        let last = try XCTUnwrap(rows.last)
        XCTAssertLessThanOrEqual(last.height, target, "the last row is never stretched to fill")

        // In the same row, a 16:9 card is as tall as a poster and keeps its shape.
        let first = rows[0]
        let portrait = try XCTUnwrap(first.slots.first { $0.id == "portrait-a" })
        let landscape = try XCTUnwrap(first.slots.first { $0.id == "landscape-a" })
        XCTAssertEqual(portrait.width / first.height, 2 / 3, accuracy: 0.001)
        XCTAssertEqual(landscape.width / first.height, 16 / 9, accuracy: 0.001)
        XCTAssertGreaterThan(landscape.width * first.height, portrait.width * first.height * 2,
                             "landscape artwork is no longer a third of a poster's size")

        // Unknown or invalid shapes are laid out as posters; extremes are bounded.
        XCTAssertEqual(Layout.ratio(nil), 2 / 3)
        XCTAssertEqual(Layout.ratio(.nan), 2 / 3)
        XCTAssertEqual(Layout.ratio(10), 2.2)
        XCTAssertEqual(Layout.ratio(0.1), 0.55)
        XCTAssertEqual(Layout.targetHeight(width: .infinity), 240)
        XCTAssertEqual(Layout.targetHeight(width: 400), 220)
        XCTAssertEqual(Layout.targetHeight(width: 5000), 320)
    }

    func testANarrowWindowGivesWideArtworkARowOfItsOwn() {
        typealias Layout = LibraryGalleryLayout
        let ratios: [String: CGFloat] = ["wide": 2.2, "poster": 2 / 3]
        let membership = Layout.rowMembership(ids: ["wide", "poster"], ratios: ratios, width: 300, targetHeight: 220)
        XCTAssertEqual(membership, [["wide"], ["poster"]])
        let rows = Layout.rows(membership: membership, ratios: ratios, width: 300, targetHeight: 220)
        XCTAssertEqual(rows[0].slots[0].width, 300, accuracy: 0.5, "never wider than the window")
        XCTAssertEqual(Layout.rowMembership(ids: [], ratios: [:], width: 300, targetHeight: 220), [])
    }

    func testTenThousandCardsKeepEveryTitleInOrder() {
        let ids = (0..<10_000).map(String.init)
        let ratios = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGFloat($0.offset % 3 == 0 ? 16.0 / 9 : 2.0 / 3)) })
        let membership = LibraryGalleryLayout.rowMembership(ids: ids, ratios: ratios, width: 1000, targetHeight: 250)
        XCTAssertEqual(membership.flatMap { $0 }, ids)
        XCTAssertTrue(membership.allSatisfy { !$0.isEmpty })
    }

    @MainActor
    func testCatalogRejectsStaleGeometryAndGalleryKeepsRowsOnImageCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(directory: directory)
        let catalog = LibraryArtworkCatalog()
        let entries = (0..<12).map { LibraryArtworkItem(id: String($0), url: "https://example.invalid/\($0).png") }
        await catalog.prepare(entries, cache: cache)
        let gallery = LibraryGalleryArrangement()
        let before = gallery.update(entries, width: 800, catalog: catalog)
        let original = gallery.membership
        catalog.record(try XCTUnwrap(ArtworkGeometry(width: 1280, height: 720)), for: entries[0])
        try await Task.sleep(for: .milliseconds(150))
        let after = gallery.update(entries, width: 800, catalog: catalog)
        XCTAssertEqual(gallery.membership, original, "image completion must not move cards into other rows")
        XCTAssertGreaterThan(after[0].slots[0].width, before[0].slots[0].width, "the measured card takes its landscape shape")
        var replaced = entries
        replaced[0] = LibraryArtworkItem(id: entries[0].id, url: "https://example.invalid/replacement.png")
        catalog.record(try XCTUnwrap(ArtworkGeometry(width: 600, height: 900)), for: entries[0])
        await catalog.prepare(replaced, cache: cache)
        catalog.record(try XCTUnwrap(ArtworkGeometry(width: 600, height: 900)), for: entries[0])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(catalog.geometry(for: replaced[0]), "an old URL cannot classify its replacement")
        let narrow = gallery.update(replaced, width: 400, catalog: catalog)
        XCTAssertEqual(narrow.flatMap { $0.slots.map(\.id) }, replaced.map(\.id), "resizing regroups rows, in order")
    }

    func testMetadataClearRejectsAnAlreadyScheduledWriteAndNeverStoresRawURLs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArtworkMetadataStore(directory: directory)
        let key = String(repeating: "a", count: 64)
        let value = ArtworkMetadataStore.Record(geometry: try XCTUnwrap(ArtworkGeometry(width: 1280, height: 720)), updated: 1)
        let generation = store.generation
        store.write([key: value], generation: generation)
        XCTAssertEqual(store.read()[key]?.geometry, value.geometry)
        store.invalidate()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("artwork-layout.json"))
        store.write([key: value], generation: generation)
        XCTAssertTrue(store.read().isEmpty, "a late write cannot undo Clear Cache")
        let invalid = Data(#"{"width":-1,"height":2}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ArtworkGeometry.self, from: invalid))
    }
    @MainActor
    func testGalleryRendersMixedArtworkWithConsistentGapsAndCategorizedPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(directory: directory)
        let server = try RangeHTTPServer()
        let samples: [(Int, Int, String)] = [(600, 900, "PORTRAIT"), (1280, 720, "LANDSCAPE"),
            (600, 900, "POSTER"), (800, 800, "SQUARE"), (1280, 720, "VIDEO"),
            (600, 900, "MOVIE"), (1280, 720, "THUMBNAIL"), (800, 800, "ALBUM"), (600, 900, "SERIES")]
        var entries: [LibraryArtworkItem] = []
        for (index, sample) in samples.enumerated() {
            let path = "/sample-\(index).png"
            server.set(path, .init(body: try fixture(width: sample.0, height: sample.1, title: sample.2, index: index), contentType: "image/png"))
            let url = server.url(path)
            _ = await cache.image(for: url, rendition: .thumbnail)
            entries.append(.init(id: String(index), url: url))
        }
        entries.append(.init(id: "missing", url: nil))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/artwork-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for mode in [LibraryDisplayMode.gallery, .categorized] {
            let catalog = LibraryArtworkCatalog()
            await catalog.prepare(entries, cache: cache)
            let frames = CardFrames()
            let content = ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Library").font(.largeTitle.bold())
                        Spacer()
                        Label(mode.title, systemImage: mode.symbol).font(.callout)
                    }
                    LibraryArtworkCollection(entries: entries, mode: mode, imageCache: cache, catalog: catalog) { entry, geometry, catalog in
                        PosterCard(title: entry.id == "missing" ? "Artwork unavailable" : samples[Int(entry.id)!].2.capitalized,
                                   subtitle: "Saved to Library", posterURL: entry.request?.url, imageCache: cache,
                                   geometryHint: geometry, onGeometry: { catalog.record($0, for: entry) })
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("LibraryPreview")) } action: {
                                frames.values[entry.id] = $0
                            }
                    }
                }
                .padding(24)
                .coordinateSpace(name: "LibraryPreview")
            }
            .background(Color.canvas)
            .environment(\.colorScheme, .dark)
            let size = NSSize(width: 1000, height: mode == .gallery ? 850 : 1550)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.alphaValue = 0
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("library-\(mode.rawValue).png"))
            XCTAssertGreaterThan(frames.values.count, 4, "the lazy layout must display its initial viewport")
            if mode == .gallery {
                let rows = Dictionary(grouping: frames.values.values) { Int($0.minY.rounded()) }
                XCTAssertGreaterThan(rows.count, 1)
                var measuredGaps = 0
                for row in rows.values where row.count > 1 {
                    let sorted = row.sorted { $0.minX < $1.minX }
                    for pair in zip(sorted, sorted.dropFirst()) {
                        XCTAssertEqual(pair.1.minX - pair.0.maxX, LibraryGalleryLayout.spacing, accuracy: 1,
                                       "cards in a row are separated by one consistent gap")
                        measuredGaps += 1
                    }
                }
                XCTAssertGreaterThan(measuredGaps, 2)
                let landscape = try XCTUnwrap(frames.values["1"])
                let poster = try XCTUnwrap(frames.values["0"])
                XCTAssertEqual(landscape.minY, poster.minY, accuracy: 1, "the first landscape card shares the posters' row")
                XCTAssertGreaterThan(landscape.width, poster.width * 2, "and is drawn at its true shape")
            }
        }
    }

    @MainActor private final class CardFrames { var values: [String: CGRect] = [:] }

    @MainActor
    private func fixture(width: Int, height: Int, title: String, index: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let colors: [NSColor] = [.systemIndigo, .systemTeal, .systemPurple, .systemOrange, .systemBlue]
        NSGradient(starting: colors[index % colors.count], ending: colors[(index + 1) % colors.count])!
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 35)
        (title as NSString).draw(in: NSRect(x: CGFloat(width) * 0.1, y: CGFloat(height) * 0.43,
            width: CGFloat(width) * 0.8, height: CGFloat(height) * 0.2), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(min(width, height)) / 12), .foregroundColor: NSColor.white])
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

}
