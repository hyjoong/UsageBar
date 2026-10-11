import SwiftUI

/// A segmented bar that fills from the left with the remaining share of a quota.
/// Twenty segments give a calibrated feel without reading as a slider.
struct QuotaGauge: View {
    enum Tone { case current, low, stale }

    let remainingPercent: Double
    let tone: Tone
    var height: CGFloat = 10

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
            ZStack(alignment: .leading) {
                track(UsageTheme.mutedSurface)
                track(fill)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: proxy.size.width * max(0, min(100, remainingPercent)) / 100)
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
