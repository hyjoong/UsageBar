import SwiftUI

/// A segmented bar that fills from the left with the remaining share of a quota.
/// Twenty segments give a calibrated feel without reading as a slider.
struct QuotaGauge: View {
    enum Tone { case current, low, stale }

    let remainingPercent: Double
    let tone: Tone
    var height: CGFloat = 10
    /// Remaining percent before a session; the band between it and `remainingPercent` is the session's slice.
    var consumedFrom: Double? = nil

    private let segments = 20
    private let gap: CGFloat = 2
    private var fill: Color {
        switch tone {
        case .current: UsageTheme.accent
        case .low: UsageTheme.warning
        case .stale: UsageTheme.secondaryInk
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let remaining = max(0, min(100, remainingPercent))
            ZStack(alignment: .leading) {
                track(UsageTheme.mutedSurface)
                track(consumedFrom == nil ? fill : fill.opacity(0.35))
                    .mask(alignment: .leading) { Rectangle().frame(width: width * remaining / 100) }
                if let consumedFrom {
                    let before = max(remaining, min(100, consumedFrom))
                    track(fill)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: width * (before - remaining) / 100)
                                .offset(x: width * remaining / 100)
                        }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func track(_ color: Color) -> some View {
        HStack(spacing: gap) {
            ForEach(0..<segments, id: \.self) { _ in
                RoundedRectangle(cornerRadius: height / 4).fill(color)
            }
        }
    }
}
