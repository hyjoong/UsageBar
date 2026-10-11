import SwiftUI
import UsageBarCore

/// One quota window: the pinned one gets the calibrated instrument, the others a compact bar.
struct QuotaRow: View {
    @ObservedObject var store: AppStore
    let window: UsageWindow
    let prominent: Bool
    private var provider: ProviderID { store.selectedProvider }
    private var current: Bool { store.freshness(for: provider) == .current }

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? UsageSpacing.item : UsageSpacing.compact) {
            if prominent {
                HStack {
                    Text(window.label).font(UsageType.headline)
                    Text("메뉴바에 표시 중").font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                    Spacer()
                    QuotaPinButton(store: store, window: window, selected: true)
                }
                QuotaInstrument(window: window, freshness: store.freshness(for: provider), now: store.clockNow)
            } else {
                HStack(spacing: 9) {
                    Text(window.label).font(UsageType.body)
                    Spacer()
                    Text("\(Int(window.remainingPercent.rounded()))% 남음")
                        .font(UsageType.headline).monospacedDigit()
                    QuotaPinButton(store: store, window: window, selected: false)
                }
                compactBar
                resetSummary
            }
            if window.remainingPercent <= 20 {
                Label(current ? "남은 한도가 20% 이하예요" : "마지막 기록에서 20% 이하였어요", systemImage: "exclamationmark.circle")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.warning)
            }
        }
    }

    private var compactBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(UsageTheme.mutedSurface)
                Capsule().fill(!current
                    ? UsageTheme.secondaryInk
                    : (window.remainingPercent <= 20 ? UsageTheme.warning : UsageTheme.ink.opacity(0.8)))
                    .frame(width: max(0, proxy.size.width * window.remainingPercent / 100))
            }
        }.frame(height: 4)
            .accessibilityLabel("\(window.label) 남은 한도")
            .accessibilityValue("\(Int(window.remainingPercent.rounded()))퍼센트")
    }

    private var resetSummary: some View {
        HStack(alignment: .top, spacing: UsageSpacing.compact) {
            Image(systemName: "arrow.turn.down.right")
                .font(UsageType.micro).padding(.top, 2).accessibilityHidden(true)
            if let date = window.resetsAt {
                VStack(alignment: .leading, spacing: 3) {
                    Text("리셋 · \(UsageFormat.relativeDate(date, now: store.clockNow, expiry: false))")
                        .foregroundStyle(date <= store.clockNow ? UsageTheme.warning : UsageTheme.secondaryInk)
                    Text(date.formatted(UsageFormat.koreanDateTime))
                }
            } else {
                Text(window.resetDescription ?? "리셋 시각이 제공되지 않았어요")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !current {
                Text("이전 기록").foregroundStyle(UsageTheme.warning)
            }
        }
        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
        .accessibilityElement(children: .combine)
    }
}

/// Chooses which window the menu bar shows for the current provider.
struct QuotaPinButton: View {
    @ObservedObject var store: AppStore
    let window: UsageWindow
    let selected: Bool

    var body: some View {
        Button { store.selectWindow(window.id, for: store.selectedProvider) } label: {
            Image(systemName: selected ? "pin.fill" : "pin")
                .font(UsageType.captionMedium)
                .foregroundStyle(selected ? UsageTheme.accent : UsageTheme.secondaryInk)
                .frame(width: UsageSpacing.control, height: UsageSpacing.control)
                .background(selected ? UsageTheme.accent.opacity(0.10) : .clear,
                            in: RoundedRectangle(cornerRadius: UsageRadius.control))
        }
        .buttonStyle(.plain)
        .help(selected ? "메뉴바에 표시 중" : "이 한도를 메뉴바에 표시")
        .accessibilityLabel("\(window.label) 메뉴바에 표시")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
    }
}

/// Selection fallback, fetch errors, retry timing, and the Claude reconnect shortcut.
struct ConnectionNotice: View {
    @ObservedObject var store: AppStore
    @State private var setupMessage: String?
    private var provider: ProviderID { store.selectedProvider }

    var body: some View {
        if let notice = store.selectionNotice(for: provider) {
            Label(notice, systemImage: "pin.slash")
                .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = store.selectedState.errorMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(UsageType.secondary).foregroundStyle(UsageTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button("서비스 장애 현황 확인") { NSWorkspace.shared.open(provider.statusURL) }
                .buttonStyle(.link).font(.caption)
        }
        if let retry = store.retryMessage(for: provider) {
            Label(retry, systemImage: "clock")
                .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
        }
        if store.selectedState.requiresConnection, provider == .claude {
            Button("Claude 다시 연결") { setupMessage = ClaudeSetupLauncher.open() }.buttonStyle(.bordered)
            if let setupMessage { Text(setupMessage).font(.caption).foregroundStyle(UsageTheme.warning) }
        }
    }
}

/// Compares elapsed period against consumed quota for the pinned window.
struct PaceSection: View {
    let pace: UsagePace
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            card.padding(.top, UsageSpacing.group)
        } label: {
            HStack {
                Text("사용 속도")
                Spacer()
                Text(title).foregroundStyle(UsageTheme.secondaryInk)
            }.font(UsageType.secondary)
        }
    }

    private var title: String {
        switch pace.position {
        case .behind: "여유 있는 속도"
        case .onTrack: "기준과 비슷한 속도"
        case .ahead: "빠르게 사용 중"
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("기간 경과", percent: pace.elapsedPercent, color: UsageTheme.secondaryInk)
            row("한도 사용", percent: pace.usedPercent, color: pace.position == .ahead ? UsageTheme.warning : UsageTheme.ink)
            Text("마지막 조회 시점 · 기간을 고르게 사용하는 기준")
                .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("기간 경과율과 실제 한도 사용률을 비교해요. 사용 패턴에 따라 차이가 날 수 있어요.")
    }

    private func row(_ label: String, percent: Double, color: Color) -> some View {
        HStack(spacing: 9) {
            Text(label).frame(width: 55, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageTheme.mutedSurface)
                    Capsule().fill(color).frame(width: proxy.size.width * percent / 100)
                }
            }.frame(height: 4)
            Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 36, alignment: .trailing)
        }.font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(label) \(Int(percent.rounded()))퍼센트")
    }
}
