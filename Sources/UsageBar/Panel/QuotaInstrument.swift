import SwiftUI
import UsageBarCore

/// A calibrated quota scale. Its ticks describe percent, never elapsed time or history.
struct QuotaInstrument: View {
    let window: UsageWindow
    let freshness: UsageFreshness
    let now: Date
    private var current: Bool { freshness == .current }
    private var marker: Color {
        !current ? UsageTheme.secondaryInk : (window.remainingPercent <= 20 ? UsageTheme.warning : UsageTheme.accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: UsageSpacing.tight) {
                Text(window.remainingPercent, format: .number.precision(.fractionLength(0)))
                    .font(UsageType.display)
                    .tracking(-3).monospacedDigit()
                Text("%").font(UsageType.displayUnit).foregroundStyle(UsageTheme.secondaryInk)
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(current ? "남은 한도" : "이전 기록")
                        .font(UsageType.label)
                        .foregroundStyle(current ? UsageTheme.ink : UsageTheme.warning)
                    Text("\(Int(window.usedPercent.rounded()))% 사용")
                        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.label), \(Int(window.remainingPercent.rounded()))퍼센트 남음\(current ? "" : ", 이전 기록")")

            scale

            if let date = window.resetsAt {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(UsageType.label)
                        .foregroundStyle(marker).padding(.top, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: UsageSpacing.tight) {
                        Text("이 한도 리셋").font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        Text(UsageFormat.relativeDate(date, now: now, expiry: false))
                            .font(UsageType.emphasis).monospacedDigit()
                            .foregroundStyle(date <= now ? UsageTheme.warning : marker)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Text(date.formatted(UsageFormat.koreanDateTime))
                        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        .multilineTextAlignment(.trailing).padding(.top, 2)
                }.accessibilityElement(children: .combine)
            } else {
                Text(window.resetDescription ?? "리셋 시각이 제공되지 않았어요")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scale: some View {
        VStack(spacing: UsageSpacing.compact) {
            GeometryReader { proxy in
                let width = max(0, proxy.size.width - 4)
                let position = width * window.remainingPercent / 100
                ZStack(alignment: .topLeading) {
                    ForEach(0..<21) { index in
                        let percent = Double(index) * 5
                        let filled = percent < window.remainingPercent
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(filled ? UsageTheme.ink.opacity(current ? 0.8 : 0.45) : UsageTheme.mutedSurface)
                            .frame(width: index % 5 == 0 ? 2 : 1.5,
                                   height: index % 5 == 0 ? 20 : 10)
                            .offset(x: width * percent / 100 + 1, y: 9)
                    }
                    RoundedRectangle(cornerRadius: 1)
                        .fill(marker).frame(width: 3, height: 28)
                        .offset(x: position + 0.5, y: 2)
                    Circle().fill(marker).frame(width: 5, height: 5)
                        .offset(x: min(max(0, position - 0.5), proxy.size.width - 5), y: 0)
                }
            }.frame(height: 31)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    HStack {
                        Text("0")
                        Spacer()
                        Text("100%")
                    }
                    ForEach([25, 50, 75], id: \.self) { value in
                        Text("\(value)")
                            .frame(width: 40, height: 14)
                            .position(x: max(0, proxy.size.width - 4) * Double(value) / 100 + 2, y: 7)
                    }
                }
            }.frame(height: 14)
            .font(UsageType.captionMono).foregroundStyle(UsageTheme.secondaryInk)
        }
        .accessibilityHidden(true)
    }
}
