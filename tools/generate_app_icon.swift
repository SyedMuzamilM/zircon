// Preserve the supplied artwork inside a macOS-style inset, rounded silhouette.
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let sourceURL = root.appendingPathComponent("assets/branding/zircon-logo.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fatalError("Cannot read supplied application artwork")
}

func icon(size: Int) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4,
        bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot allocate application icon")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    let center = CGFloat(size) / 2
    let radius = 412 * scale
    let silhouette = NSBezierPath()
    for step in 0...720 {
        let angle = Double(step) * .pi / 360
        let cosine = cos(angle)
        let sine = sin(angle)
        let point = NSPoint(
            x: center + radius * CGFloat(copysign(pow(abs(cosine), 0.4), cosine)),
            y: center + radius * CGFloat(copysign(pow(abs(sine), 0.4), sine))
        )
        if step == 0 {
            silhouette.move(to: point)
        } else {
            silhouette.line(to: point)
        }
    }
    silhouette.close()
    silhouette.addClip()
    source.draw(in: NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let large = icon(size: 1024)
guard let png = large.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode application icon")
}
try png.write(to: root.appendingPathComponent("assets/branding/zircon-app-icon.png"))
let small = icon(size: 256)
var rgba = Data(count: 256 * 256 * 4)
rgba.withUnsafeMutableBytes { raw in
    let bytes = raw.bindMemory(to: UInt8.self)
    for y in 0..<256 {
        for x in 0..<256 {
            let color = small.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let offset = (y * 256 + x) * 4
            bytes[offset] = UInt8((color.redComponent * 255).rounded())
            bytes[offset + 1] = UInt8((color.greenComponent * 255).rounded())
            bytes[offset + 2] = UInt8((color.blueComponent * 255).rounded())
            bytes[offset + 3] = UInt8((color.alphaComponent * 255).rounded())
        }
    }
}
try rgba.write(to: root.appendingPathComponent("apps/zircon/src/assets/zircon-logo.rgba"))
print("Generated the rounded application PNG and runtime RGBA icon.")
