import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(1) }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let multiplier = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: multiplier); transform.concat()
        let surface = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 206, yRadius: 206)
        NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.25, alpha: 1),
                   ending: NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1))!.draw(in: surface, angle: -90)
        let heights: [CGFloat] = [245, 420, 555]
        for (index, height) in heights.enumerated() {
            NSColor(calibratedRed: 0.91, green: 0.69, blue: 0.48, alpha: index == 0 ? 0.48 : index == 1 ? 0.72 : 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 252 + CGFloat(index) * 184, y: 230, width: 116, height: height), xRadius: 40, yRadius: 40).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try png.write(to: folder.appendingPathComponent(name))
    }
}
