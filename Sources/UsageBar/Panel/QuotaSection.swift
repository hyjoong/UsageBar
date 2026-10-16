import SwiftUI
import UsageBarCore

/// One quota window. The pinned window gets the large numeral; the others share the same gauge at a smaller size.
struct QuotaRow: View {
    @ObservedObject var store: AppStore
    let window: UsageWindow
    let prominent: Bool
    private var provider: ProviderID { store.selectedProvider }
    private var current: Bool { store.freshness(for: provider) == .current }
    private var low: Bool { window.remainingPercent <= 20 }
    private var remaining: Int { Int(window.remainingPercent.rounded()) }
    private var tone: QuotaGauge.Tone { !current ? .stale : (low ? .low : .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? UsageSpacing.item : UsageSpacing.compact) {
            if prominent { hero } else { compact }
            resetLine
            if low {
                Label(current ? "남은 한도가 20% 이하예요" : "마지막 기록에서 20% 이하였어요", systemImage: "exclamationmark.circle")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.warning)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(current ? "\(window.label), \(remaining)퍼센트 남음" : "\(window.label), \(remaining)퍼센트 남음, 이전 기록")
    }

    @ViewBuilder private var hero: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: UsageSpacing.compact) {
                Text(window.label).font(UsageType.headline)
                staleBadge
            }
            if current {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(remaining, format: .number)
                        .font(UsageType.display).tracking(-2).monospacedDigit()
                    Text("%").font(UsageType.displayUnit).foregroundStyle(UsageTheme.secondaryInk)
                    Text("남음").font(UsageType.body).foregroundStyle(UsageTheme.secondaryInk).padding(.leading, UsageSpacing.tight)
                }
                .help("\(window.label) \(Int(window.usedPercent.rounded()))% 사용 · 계정 전체 기준")
            } else {
                // The record's age is in the footer; here only the cached value, set apart from a live reading.
                Text("마지막 확인 시 \(remaining)% 남음")
                    .font(UsageType.headline).monospacedDigit()
                    .foregroundStyle(UsageTheme.secondaryInk)
            }
        }
        QuotaGauge(remainingPercent: window.remainingPercent, tone: tone, height: 10)
    }

    @ViewBuilder private var compact: some View {
        HStack(spacing: UsageSpacing.compact) {
            Text(window.label).font(UsageType.body)
            staleBadge
            Spacer()
            Text(current ? "\(remaining)% 남음" : "당시 \(remaining)% 남음")
                .font(UsageType.headline).monospacedDigit()
        }
        QuotaGauge(remainingPercent: window.remainingPercent, tone: tone, height: 6)
    }

    @ViewBuilder private var staleBadge: some View {
        if !current {
            Text("이전 기록").font(UsageType.caption).foregroundStyle(UsageTheme.warning)
        }
    }

    private var resetLine: some View {
        Group {
            if let date = window.resetsAt {
                let relative = UsageFormat.relativeDate(date, now: store.clockNow, expiry: false)
                if date <= store.clockNow {
                    Text(verbatim: relative).foregroundStyle(UsageTheme.warning)
                } else {
                    Text("리셋 \(relative) · \(UsageFormat.resetClock(date, now: store.clockNow))")
                        .foregroundStyle(UsageTheme.secondaryInk)
                }
            } else {
                Text(window.resetDescription ?? String(localized: "리셋 시각이 제공되지 않았어요"))
                    .foregroundStyle(UsageTheme.secondaryInk)
            }
        }
        .font(prominent ? UsageType.secondary : UsageType.caption)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fetch errors, retry timing, and connection recovery for both providers.
struct ConnectionNotice: View {
    @ObservedObject var store: AppStore
    @State private var setupMessage: String?
    private var provider: ProviderID { store.selectedProvider }

    var body: some View {
        if RecoveryCard.applies(to: store.selectedState, provider: provider) {
            RecoveryCard(store: store)
        } else {
            failureNotice
        }
    }

    @ViewBuilder private var failureNotice: some View {
        if let message = store.selectedState.errorMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(UsageType.secondary).foregroundStyle(UsageTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            if !store.selectedState.requiresConnection {
                Button("서비스 장애 현황 확인") { NSWorkspace.shared.open(provider.statusURL) }
                    .buttonStyle(.link).font(.caption)
            }
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

/// Compares elapsed period against consumed quota for the pinned window, and when a short window
/// would run out at the recent rate, leads with that time.
struct PaceSection: View {
    let pace: UsagePace
    let projection: UsageProjection?
    let observedAt: Date
    let now: Date
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            card.padding(.top, UsageSpacing.group)
        } label: {
            HStack {
                Text("사용 속도")
                Spacer()
                headline
            }.font(UsageType.secondary)
        }
    }

    private var title: String {
        switch pace.position {
        case .behind: String(localized: "여유 있는 속도")
        case .onTrack: String(localized: "기준과 비슷한 속도")
        case .ahead: String(localized: "빠르게 사용 중")
        }
    }

    @ViewBuilder private var headline: some View {
        switch projection?.outcome {
        case .runsOut(let at):
            Text("\(UsageFormat.resetClock(at, now: now)) 소진 예상").foregroundStyle(UsageTheme.warning)
        case .lastsUntilReset:
            Text("리셋까지 여유").foregroundStyle(UsageTheme.secondaryInk)
        case nil:
            Text(title).foregroundStyle(UsageTheme.secondaryInk)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let projection { projectionDetail(projection) }
            row(String(localized: "기간 경과"), percent: pace.elapsedPercent, color: UsageTheme.secondaryInk)
            row(String(localized: "한도 사용"), percent: pace.usedPercent, color: pace.position == .ahead ? UsageTheme.warning : UsageTheme.ink)
            Text("마지막 조회 시점 · 기간을 고르게 사용하는 기준")
                .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("기간 경과율과 실제 한도 사용률을 비교해요. 사용 패턴에 따라 차이가 날 수 있어요.")
    }

    private func projectionDetail(_ projection: UsageProjection) -> some View {
        let minutes = max(1, Int(observedAt.timeIntervalSince(projection.sampledSince) / 60))
        let rate = projection.ratePerHour
        let rateText = rate >= 10 || rate == 0 ? String(format: "%.0f", rate) : String(format: "%.1f", rate)
        return VStack(alignment: .leading, spacing: 2) {
            switch projection.outcome {
            case .runsOut(let at):
                Text("이 속도면 \(UsageFormat.resetClock(at, now: now))에 소진돼요").foregroundStyle(UsageTheme.warning)
            case .lastsUntilReset:
                Text("이 속도면 리셋까지 남아요")
            }
            Text("최근 \(minutes)분 동안 시간당 \(rateText)%p 사용")
                .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk).monospacedDigit()
        }
        .font(UsageType.headline)
    }

    private func row(_ label: String, percent: Double, color: Color) -> some View {
        HStack(spacing: 9) {
            Text(verbatim: label).frame(width: 55, alignment: .leading)
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
