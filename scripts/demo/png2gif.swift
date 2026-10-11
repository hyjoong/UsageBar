import AppKit
import ImageIO
import UniformTypeIdentifiers
// usage: png2gif <out.gif> <fps> <maxWidth> <frame1.png> <frame2.png> ...
// Frames are top-aligned and padded to the tallest frame with the app's dark canvas color.
let args = CommandLine.arguments
let output = URL(fileURLWithPath: args[1]); let fps = Double(args[2])!; let maxWidth = Double(args[3])!
let frames = args[4...].compactMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
let width = frames.map(\.width).max()!, height = frames.map(\.height).max()!
let scale = min(1, maxWidth / Double(width))
let outW = Int(Double(width) * scale), outH = Int(Double(height) * scale)
guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
let canvas = CGColor(red: 0x23 / 255.0, green: 0x24 / 255.0, blue: 0x21 / 255.0, alpha: 1)
for frame in frames {
    let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(canvas); ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
    ctx.interpolationQuality = .high
    let fw = Double(frame.width) * scale, fh = Double(frame.height) * scale
    ctx.draw(frame, in: CGRect(x: 0, y: Double(outH) - fh, width: fw, height: fh))
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props)
}
guard CGImageDestinationFinalize(dest) else { print("finalize failed"); exit(1) }
let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("wrote \(frames.count) frames \(outW)x\(outH), \(size / 1024) KB")
