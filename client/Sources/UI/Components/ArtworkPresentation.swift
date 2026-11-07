import AppKit
import Observation
import SwiftUI

/// Geometry comes from the decoded, orientation-correct bitmap, never the
/// provider's name, media type, URL suffix or the name of its artwork field.
struct ArtworkGeometry: Equatable, Codable, Sendable {
    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    init?(image: NSImage) {
        // BoundedImageDecoder explicitly sets this size to the transformed
        // bitmap's pixel dimensions. AppKit may add larger Retina drawing
        // representations later; those are not additional source resolution.
        let size = image.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= CGFloat(BoundedImageDecoder.maxSourcePixels),
              size.height <= CGFloat(BoundedImageDecoder.maxSourcePixels) else { return nil }
        self.init(width: Int(size.width), height: Int(size.height))
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let width = try values.decode(Int.self, forKey: .width)
        let height = try values.decode(Int.self, forKey: .height)
        guard let valid = Self(width: width, height: height),
              width <= BoundedImageDecoder.maxSourcePixels, height <= BoundedImageDecoder.maxSourcePixels else {
            throw DecodingError.dataCorruptedError(forKey: .width, in: values, debugDescription: "Invalid artwork dimensions")
        }
        self = valid
    }

    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
    var isLandscape: Bool { aspectRatio > 1.15 }
    /// Taller than square: posters and covers.
    var isPortrait: Bool { aspectRatio < 0.85 }

    /// The artwork's own shape, used only by the library gallery, whose rows
    /// justify cards of any shape. Extreme panoramas and unusually tall covers
    /// get a bounded box, with aspect-fit inside it.
    var cardAspectRatio: CGFloat { min(2.2, max(0.55, aspectRatio)) }

    /// The shape every other card uses: 2:3 for portrait artwork, 16:9 for
    /// landscape and 1:1 for square, so cards line up in grids and shelves
    /// whatever size the provider's image happens to be.
    var standardCardRatio: CGFloat {
        if isLandscape { return ArtworkCardShape.landscapeRatio }
        if isPortrait { return ArtworkCardShape.posterRatio }
        return ArtworkCardShape.squareRatio
    }

    /// Every shape is as tall as a 2:3 poster of `posterWidth`, so a shelf
    /// mixing posters, stills and square covers keeps one row height.
    func shelfWidth(posterWidth: CGFloat) -> CGFloat {
        if isLandscape { return ArtworkCardShape.landscapeShelfWidth(posterWidth: posterWidth) }
        if isPortrait { return posterWidth }
        return ArtworkCardShape.shelfHeight(posterWidth: posterWidth) * ArtworkCardShape.squareRatio
    }
}

/// How a card's artwork box takes its shape from the artwork.
enum ArtworkCardShape {
    /// 2:3, 16:9 or 1:1, artwork filling the box. Grids, shelves, search, Home.
    case standard
    /// The artwork's own bounded shape, artwork fitted. The library gallery.
    case natural

    static let posterRatio: CGFloat = 2 / 3
    static let landscapeRatio: CGFloat = 16 / 9
    static let squareRatio: CGFloat = 1

    /// A shelf row's card height: that of a 2:3 poster.
    static func shelfHeight(posterWidth: CGFloat) -> CGFloat {
        posterWidth / posterRatio
    }

    /// A 16:9 card exactly as tall as the row's posters (≈ 2.67 × their width).
    static func landscapeShelfWidth(posterWidth: CGFloat) -> CGFloat {
        shelfHeight(posterWidth: posterWidth) * landscapeRatio
    }

    func ratio(for geometry: ArtworkGeometry?, placeholder: CGFloat) -> CGFloat {
        guard let geometry else { return placeholder }
        return self == .natural ? geometry.cardAspectRatio : geometry.standardCardRatio
    }

    var contentMode: ContentMode { self == .natural ? .fit : .fill }
}

extension EnvironmentValues {
    /// Set by the library gallery; every other container uses standard shapes.
    @Entry var artworkCardShape: ArtworkCardShape = .standard
}

struct ArtworkAsset {
    let image: NSImage
    let geometry: ArtworkGeometry

    init?(image: NSImage) {
        guard let geometry = ArtworkGeometry(image: image) else { return nil }
        self.image = image
        self.geometry = geometry
    }
}

/// The view and cache use the same identity, including credentials and decode
/// size. A URL-only task identity would keep stale artwork after either changes.
struct ArtworkRequest: Hashable, Sendable {
    let url: String
    let headers: [String: String]
    let rendition: ArtworkRendition
    let id: String

    init?(url: String?, headers: [String: String]? = nil, rendition: ArtworkRendition = .thumbnail) {
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        self.url = url
        self.headers = ImageCache.sanitizedHeaders(headers)
        self.rendition = rendition
        id = ImageCache.memoryKey(for: url, headers: self.headers, rendition: rendition)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ArtworkPhase {
    case empty
    case loading
    case success(ArtworkAsset)
    case failure

    var asset: ArtworkAsset? {
        if case .success(let asset) = self { return asset }
        return nil
    }
}

/// One view's subscription to the existing shared cache. The cache owns shared
/// work; cancelling one card must not cancel another card's image download.
@MainActor @Observable
final class ArtworkLoader {
    private struct Completion {
        let request: ArtworkRequest
        let asset: ArtworkAsset?
    }

    private var completion: Completion?
    @ObservationIgnored private var generation = UUID()

    func phase(for request: ArtworkRequest?, cache: ImageCache = .shared) -> ArtworkPhase {
        guard let request else { return .empty }
        if let completion, completion.request == request, let asset = completion.asset {
            return .success(asset)
        }
        // A memory hit is visible in the first frame, before .task runs.
        if let image = cache.synchronousMemoryImage(for: request.url, headers: request.headers, rendition: request.rendition),
           let asset = ArtworkAsset(image: image) { return .success(asset) }
        if completion?.request == request { return .failure }
        return .loading
    }

    func load(_ request: ArtworkRequest?, cache: ImageCache = .shared, force: Bool = false) async {
        let token = UUID()
        generation = token
        if !force, let request, completion?.request == request, completion?.asset != nil { return }
        completion = nil
        guard let request else { return }
        let image = await cache.image(for: request.url, headers: request.headers, rendition: request.rendition)
        guard !Task.isCancelled, generation == token else { return }
        completion = Completion(request: request, asset: image.flatMap { ArtworkAsset(image: $0) })
    }
}

/// The ratio placeholder owns layout; bitmap intrinsic size never participates
/// in SwiftUI's unbounded horizontal-scroll sizing negotiation.
struct ArtworkSurface: View {
    let asset: ArtworkAsset?
    var contentMode: ContentMode = .fit
    var alignment: Alignment = .center
    var placeholderIcon = "film"

    var body: some View {
        Color.cardSurface
            .overlay(alignment: alignment) {
                if let asset {
                    Image(nsImage: asset.image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .overlay {
                if asset == nil {
                    Image(systemName: placeholderIcon)
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

enum ArtworkCardLayout {
    case grid
    case shelf(posterWidth: CGFloat, landscapeHint: Bool = false)

    var placeholderRatio: CGFloat {
        if case .shelf(_, true) = self { return ArtworkCardShape.landscapeRatio }
        return ArtworkCardShape.posterRatio
    }

    func width(for geometry: ArtworkGeometry?) -> CGFloat? {
        guard case .shelf(let posterWidth, let landscapeHint) = self else { return nil }
        return geometry?.shelfWidth(posterWidth: posterWidth)
            ?? (landscapeHint ? ArtworkCardShape.landscapeShelfWidth(posterWidth: posterWidth) : posterWidth)
    }
}
