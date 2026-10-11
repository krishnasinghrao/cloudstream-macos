#!/usr/bin/env swift
// Regenerates client/Resources/Assets.xcassets/AppIcon.appiconset from the
// full-bleed source artwork in Icons/. The artwork is placed on Apple's macOS
// icon grid (824pt body centred on a 1024pt transparent canvas) so it matches
// the size and margins of system icons in the Dock and Finder.
//
// Usage (from the repository root): swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Icons/Cloudstream MacOS icon.png")
let output = root.appendingPathComponent("client/Resources/Assets.xcassets/AppIcon.appiconset")

guard let src = NSImage(contentsOf: source),
      let full = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot load \(source.path)")
}

// Trim any transparent margin baked into the source so the artwork body
// always lands exactly on the 824pt grid, whatever padding the export had.
func opaqueBounds(_ image: CGImage) -> CGRect {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 127 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { fatalError("Source artwork is fully transparent") }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let bounds = opaqueBounds(full)
guard let cg = full.cropping(to: bounds) else { fatalError("Cannot crop source artwork") }
print("Source \(full.width)x\(full.height), artwork bounds \(bounds)")

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(px) / 1024
    let body = 824 * scale
    let inset = (CGFloat(px) - body) / 2
    // Subtle drop shadow, as on Apple's icon template.
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    // Aspect-fit the trimmed artwork inside the body square.
    let fit = body / CGFloat(max(cg.width, cg.height))
    let w = CGFloat(cg.width) * fit, h = CGFloat(cg.height) * fit
    ctx.draw(cg, in: CGRect(x: inset + (body - w) / 2, y: inset + (body - h) / 2, width: w, height: h))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(size * scale).write(to: output.appendingPathComponent(name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(size)x\(size)" }
        """)
    }
}
let json = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try json.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(images.count) icons to \(output.path)")
