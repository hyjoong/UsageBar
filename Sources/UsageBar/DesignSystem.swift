import AppKit
import SwiftUI

/// A quiet, adaptive palette shared by the menu, history, and settings.
enum UsageTheme {
    static let ink = Color(nsColor: .labelColor)
    static let secondaryInk = adaptive(light: 0x656760, dark: 0xB7B9AF)
    static let separator = Color(nsColor: .separatorColor)
    static let canvas = adaptive(light: 0xF5F3EF, dark: 0x232421)
    static let surface = adaptive(light: 0xFCFBF8, dark: 0x2C2D29)
    static let mutedSurface = adaptive(light: 0xE9E6DF, dark: 0x373832)
    static let accent = adaptive(light: 0xA44D32, dark: 0xE5A084)
    static let warning = adaptive(light: 0x986318, dark: 0xE8BD72)
    static let danger = adaptive(light: 0xB53E36, dark: 0xF39489)
    static let chartColors: [Color] = [
        accent,
        adaptive(light: 0x526A82, dark: 0xA2B9D1),
        adaptive(light: 0x776C58, dark: 0xC6BCA6),
        adaptive(light: 0x6A5B74, dark: 0xBCAAC7),
        adaptive(light: 0x5D6063, dark: 0xADB0B3)
    ]

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

/// An open U with a detached level mark; the same geometry is used in the app icon.
struct UsageBrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Path { path in
                path.move(to: CGPoint(x: side * 0.22, y: side * 0.20))
                path.addLine(to: CGPoint(x: side * 0.22, y: side * 0.61))
                path.addCurve(to: CGPoint(x: side * 0.78, y: side * 0.61),
                              control1: CGPoint(x: side * 0.22, y: side * 0.82),
                              control2: CGPoint(x: side * 0.78, y: side * 0.82))
                path.addLine(to: CGPoint(x: side * 0.78, y: side * 0.44))
                path.move(to: CGPoint(x: side * 0.78, y: side * 0.20))
                path.addLine(to: CGPoint(x: side * 0.78, y: side * 0.25))
            }
            .stroke(style: StrokeStyle(lineWidth: side * 0.14, lineCap: .round, lineJoin: .round))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }

    @MainActor static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let side = rect.width
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: side * 0.22, y: side * 0.20))
            path.line(to: NSPoint(x: side * 0.22, y: side * 0.61))
            path.curve(to: NSPoint(x: side * 0.78, y: side * 0.61),
                       controlPoint1: NSPoint(x: side * 0.22, y: side * 0.82),
                       controlPoint2: NSPoint(x: side * 0.78, y: side * 0.82))
            path.line(to: NSPoint(x: side * 0.78, y: side * 0.44))
            path.move(to: NSPoint(x: side * 0.78, y: side * 0.20))
            path.line(to: NSPoint(x: side * 0.78, y: side * 0.25))
            path.lineWidth = side * 0.14
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Type scale shared by the panel and windows. Names describe the role, not the point size,
/// so a later visual pass can retune sizes in one place.
enum UsageType {
    // Numerals
    static let display = Font.system(size: 44, weight: .light, design: .rounded)
    static let displayUnit = Font.system(size: 20, weight: .light)
    static let metric = Font.system(size: 30, weight: .medium, design: .rounded)
    static let duration = Font.system(size: 19, weight: .medium, design: .rounded)
    static let durationCompact = Font.system(size: 17, weight: .medium, design: .rounded)
    static let emphasis = Font.system(size: 15, weight: .medium)

    // Text
    static let windowTitle = Font.system(size: 24, weight: .semibold)
    static let title = Font.system(size: 15, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .medium)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 12, weight: .medium)
    static let secondary = Font.system(size: 12)
    static let sectionHeading = Font.system(size: 11, weight: .semibold)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionMono = Font.system(size: 11, design: .monospaced)
    static let micro = Font.system(size: 10)
}

/// Spacing scale. Insets frame a surface; the rest separate content inside it.
enum UsageSpacing {
    static let panelInset: CGFloat = 22
    static let windowInset: CGFloat = 28
    static let section: CGFloat = 18
    static let group: CGFloat = 12
    static let item: CGFloat = 8
    static let compact: CGFloat = 6
    static let tight: CGFloat = 4
    /// Minimum hit size for icon buttons and tappable rows.
    static let control: CGFloat = 28
}

enum UsageRadius {
    static let card: CGFloat = 14
    static let panelCard: CGFloat = 10
    static let control: CGFloat = 7
}
