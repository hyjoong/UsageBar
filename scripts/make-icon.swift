import AppKit
import Foundation

// Regenerate with:
// swift scripts/make-icon.swift build/AppIcon.iconset Resources/AppIcon.icns
guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Usage: swift scripts/make-icon.swift <output.iconset> [output.icns]\n", stderr)
    exit(1)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard folder.pathExtension == "iconset" else {
    fputs("The output folder must have the .iconset extension.\n", stderr)
    exit(1)
}
let iconURL = CommandLine.arguments.count == 3
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : folder.deletingPathExtension().appendingPathExtension("icns")
let previewURL = folder.deletingLastPathComponent().appendingPathComponent("icon-preview.png")
let fileManager = FileManager.default
try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
try fileManager.createDirectory(at: iconURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func iconPNG(pixels: Int) -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Cannot create the \(pixels)-pixel icon canvas.")
    }
    context.setShouldAntialias(true)
    // The mark's shared SVG coordinates start at the top left. Flip once here.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

    color(0x292A27).setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                 xRadius: 190, yRadius: 190).fill()

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x * 1024, y: y * 1024)
    }
    let body = NSBezierPath()
    body.move(to: point(0.22, 0.20))
    body.line(to: point(0.22, 0.61))
    body.curve(to: point(0.78, 0.61), controlPoint1: point(0.22, 0.82),
               controlPoint2: point(0.78, 0.82))
    body.line(to: point(0.78, 0.44))
    body.lineWidth = 0.14 * 1024
    body.lineCapStyle = .round
    body.lineJoinStyle = .round
    color(0xF3EFE6).setStroke()
    body.stroke()

    let tick = NSBezierPath()
    tick.move(to: point(0.78, 0.20))
    tick.line(to: point(0.78, 0.25))
    tick.lineWidth = body.lineWidth
    tick.lineCapStyle = .round
    color(0xD77855).setStroke()
    tick.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode the \(pixels)-pixel icon.")
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let png = iconPNG(pixels: size * scale)
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        if size == 512 && scale == 2 { try png.write(to: previewURL, options: .atomic) }
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", folder.path, "-o", iconURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
let iconData = try Data(contentsOf: iconURL)
guard iconData.count > 8, String(data: iconData.prefix(4), encoding: .ascii) == "icns" else {
    fatalError("iconutil did not produce a valid ICNS file.")
}
print("Generated \(folder.path), \(iconURL.path), and \(previewURL.path)")
