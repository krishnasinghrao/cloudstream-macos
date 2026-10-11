import AppKit
import ImageIO

/// Decodes artwork without letting its pixel dimensions decide memory use.
enum BoundedImageDecoder {
    /// Above this the file is rejected before any pixel buffer is allocated.
    static let maxSourcePixels = 64_000_000
    /// Longest side of the decoded rendition; larger sources are downsampled.
    static let maxRenditionDimension = 2560

    struct Rendition {
        let image: NSImage
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Pixel count of the encoded image, read from its header without
    /// decoding; nil when it is not an image or exceeds the source limit.
    static func sourcePixels(of data: Data) -> Int? {
        dimensions(of: data).map { $0.width * $0.height }
    }

    private static func dimensions(of data: Data) -> (source: CGImageSource, width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxSourcePixels / height else { return nil }
        return (source, width, height)
    }

    /// - Parameter maxDimension: longest side wanted; never above
    ///   `maxRenditionDimension`, never upscaled.
    static func decode(_ data: Data, maxDimension: Int = maxRenditionDimension) -> Rendition? {
        guard let (source, width, height) = dimensions(of: data) else { return nil }
        let rendition = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxRenditionDimension, max(1, maxDimension)),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, rendition) else { return nil }
        return Rendition(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                         pixelWidth: image.width, pixelHeight: image.height)
    }
}
