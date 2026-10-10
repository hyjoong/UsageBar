import AppKit
import SwiftUI
import UsageBarCore

extension ProviderID {
    var tint: Color { self == .claude ? Color(red: 0.77, green: 0.48, blue: 0.30) : Color(red: 0.22, green: 0.65, blue: 0.52) }
    var symbol: String { self == .claude ? "asterisk.circle.fill" : "terminal.fill" }
    var dashboardURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
}

struct UsagePanel: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var showCredits = false
    @State private var setupMessage: String?
    private var provider: ProviderID { store.selectedProvider }
    private var snapshot: ProviderSnapshot? { store.selectedState.snapshot }
    private var demo: Bool { store.isDemo }
    private var panelHeight: CGFloat {
        guard let snapshot else { return 520 }
        let extras = (snapshot.resetCreditCount == nil ? 0 : 70) + ((snapshot.dailyUsage?.isEmpty ?? true) ? 0 : 40)
        return CGFloat(min(690, 420 + snapshot.windows.count * 100 + extras + (showCredits ? 80 : 0)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let snapshot {
                        if let first = store.trackedWindow(for: provider) {
                            quota(first, prominent: true)
                            if store.freshness(for: provider) == .current,
                               let pace = UsagePace.evaluate(window: first, observedAt: snapshot.fetchedAt, now: store.clockNow) {
                                paceCard(pace)
                            }
                            ForEach(store.sortedWindows(for: provider).filter { $0.id != first.id }) { quota($0, prominent: false) }
                        } else {
                            Label("제공된 한도 정보가 없어요", systemImage: "info.circle")
                                .foregroundStyle(.secondary).font(.callout)
                        }
                        timeline(snapshot)
                        if let count = snapshot.resetCreditCount {
                            Button { showCredits.toggle() } label: {
                                HStack {
                                    Label("초기화권", systemImage: "ticket")
                                    Spacer()
                                    Text("\(count)장").monospacedDigit()
                                    Image(systemName: showCredits ? "chevron.up" : "chevron.down")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            if showCredits { credits(snapshot) }
                        }
                        if let daily = snapshot.dailyUsage, !daily.isEmpty {
                            Button { showWindow("history") } label: {
                                HStack {
                                    Label("최근 일별 토큰", systemImage: "chart.bar")
                                    Spacer()
                                    Text(Self.tokenLabel(daily.last?.tokens ?? 0)).monospacedDigit()
                                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    } else {
                        emptyState
                    }
                    if snapshot != nil, let message = store.selectedState.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if snapshot != nil, store.selectedState.requiresConnection, provider == .claude {
                        Button("Claude 다시 연결") { openClaudeSetup() }.buttonStyle(.bordered)
                        if let setupMessage { Text(setupMessage).font(.caption).foregroundStyle(.orange) }
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 510)
            status
            Divider()
            footer
        }
        .frame(width: 370, height: panelHeight)
        .background(.background)
        .tint(provider.tint)
        .task { await store.refresh(provider) }
        .onChange(of: store.selectedProvider) { _, newValue in
            showCredits = false
            Task { await store.refresh(newValue) }
        }
    }

    private var header: some View {
        VStack(spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(provider.tint)
                    .frame(width: 36, height: 36).background(provider.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.title).font(.system(size: 17, weight: .semibold))
                    Text(snapshot?.plan ?? "계정 사용량").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if demo {
                    Text("예시 데이터").font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
            }
            Picker("서비스", selection: $store.selectedProvider) {
                ForEach(ProviderID.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
        }.padding(20)
    }

    private func quota(_ window: UsageWindow, prominent: Bool) -> some View {
            VStack(alignment: .leading, spacing: prominent ? 13 : 9) {
            HStack(alignment: .firstTextBaseline) {
                Button { store.selectWindow(window.id, for: provider) } label: {
                    HStack(spacing: 5) {
                        Text(window.label)
                        Image(systemName: prominent ? "pin.fill" : "pin")
                            .font(.system(size: 9))
                    }.foregroundStyle(prominent ? provider.tint : .secondary)
                }
                .buttonStyle(.plain)
                .help(prominent ? "메뉴바에 표시 중" : "클릭해서 메뉴바에 표시")
                .accessibilityLabel("\(window.label), \(prominent ? "메뉴바에 표시 중" : "메뉴바에 표시하기")")
                Spacer()
                (Text(window.remainingPercent, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: prominent ? 32 : 15, weight: .medium, design: .rounded))
                 + Text("% 남음").font(.system(size: prominent ? 13 : 12)))
                .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(window.remainingPercent <= 20 ? Color.orange : provider.tint)
                        .frame(width: max(0, proxy.size.width * window.remainingPercent / 100))
                }
            }.frame(height: prominent ? 7 : 5)
        }
        .accessibilityElement(children: .contain)
    }

    private func paceCard(_ pace: UsagePace) -> some View {
        let title: String = switch pace.position {
        case .behind: "여유 있는 속도"
        case .onTrack: "기준과 비슷한 속도"
        case .ahead: "빠르게 사용 중"
        }
        let color = pace.position == .ahead ? Color.orange : provider.tint
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("사용 속도", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            }
            VStack(spacing: 7) {
                paceRow("기간 경과", percent: pace.elapsedPercent, color: .secondary)
                paceRow("한도 사용", percent: pace.usedPercent, color: color)
            }
            Text("조회 시점 · 기간을 고르게 사용하는 기준")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(13)
        .background(provider.tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        .help("마지막 조회 시점의 기간 경과율과 실제 한도 사용률을 비교해요. 사용 패턴에 따라 차이가 날 수 있어요.")
    }

    private func paceRow(_ label: String, percent: Double, color: Color) -> some View {
        HStack(spacing: 9) {
            Text(label).frame(width: 47, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: proxy.size.width * percent / 100)
                }
            }.frame(height: 4)
            Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 31, alignment: .trailing)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(label) \(Int(percent.rounded()))퍼센트")
    }

    private func timeline(_ snapshot: ProviderSnapshot) -> some View {
        let valid = UsageWindowSelection.validWindows(snapshot.windows)
        let upcoming = valid.filter { $0.resetsAt != nil }.sorted { $0.resetsAt! < $1.resetsAt! }
        let credit = snapshot.resetCredits?.filter {
            $0.status.lowercased() == "available" && ($0.expiresAt.map { $0 > Date() } ?? false)
        }.min { $0.expiresAt! < $1.expiresAt! }
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(upcoming.prefix(3)) { window in
                if let date = window.resetsAt {
                    event(title: "\(window.label) 리셋", date: date, expiry: false)
                }
            }
            if let date = credit?.expiresAt { event(title: "첫 초기화권 만료", date: date, expiry: true) }
            ForEach(valid.filter { $0.resetsAt == nil }) { window in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(window.label) 리셋").font(.caption)
                    Text(window.resetDescription ?? "리셋 시각이 제공되지 않았어요")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func event(title: String, date: Date, expiry: Bool) -> some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 0) {
                Circle().fill(expiry ? Color.secondary : provider.tint).frame(width: 6, height: 6)
                Rectangle().fill(.quaternary).frame(width: 1, height: 44)
            }.padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.relativeDate(date, now: context.date, expiry: expiry))
                        .font(.caption).foregroundStyle(provider.tint)
                }
                Text(title).font(.system(size: 15, weight: .medium))
                Text(date.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().weekday().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private func credits(_ snapshot: ProviderSnapshot) -> some View {
        if let credits = snapshot.resetCredits {
            if credits.isEmpty {
                Text("표시할 초기화권 상세가 없어요").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(credits) { credit in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(credit.title.isEmpty ? "초기화권" : credit.title)
                        Text(Self.creditStatus(credit.status)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(credit.expiresAt.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "만료 없음")
                        .foregroundStyle(.secondary)
                }.font(.caption)
            }
        } else {
            Text("초기화권 상세가 제공되지 않았어요").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            if store.selectedState.isRefreshing {
                ProgressView().controlSize(.small)
                Text("\(provider.title) 한도 확인 중").font(.headline)
                Text(provider == .claude ? "Claude Code의 사용량 화면을 확인하고 있어요." : "로그인된 Codex 계정의 한도를 확인하고 있어요.")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                Image(systemName: "link.circle").font(.system(size: 30)).foregroundStyle(provider.tint)
                Text("\(provider.title) 연결 확인").font(.headline)
                Text(store.selectedState.errorMessage ?? (provider == .claude ? "로그인된 Claude Code의 한도와 리셋 시각을 확인해요." : "로그인된 Codex의 한도와 토큰 기록을 확인해요."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("다시 확인") { Task { await store.refresh(provider, force: true) } }
                    .buttonStyle(.borderedProminent)
                if provider == .claude {
                    Button("Claude 연결 설정") { openClaudeSetup() }
                        .buttonStyle(.bordered)
                    Text("터미널에서 처음 한 번 연결을 확인해 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let setupMessage {
                        Text(setupMessage).font(.caption).foregroundStyle(.orange)
                    }
                }
                Button("공식 사용량 화면 열기") { NSWorkspace.shared.open(provider.dashboardURL) }
                    .font(.caption).buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 26)
    }

    private var status: some View {
        HStack(spacing: 7) {
            if store.selectedState.isRefreshing { ProgressView().controlSize(.mini) }
            else { Circle().fill(store.freshness(for: provider) == .current ? provider.tint : Color.orange).frame(width: 5, height: 5) }
            if let last = snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("\(Self.freshness(last, now: context.date)) · \(store.isStale(for: provider) ? store.connectionStatus(for: provider) : "계정 전체")")
                }
            } else {
                Text(store.selectedState.isRefreshing ? "확인 중" : "아직 확인한 기록이 없어요")
            }
            Spacer()
            Button { Task { await store.refresh(provider, force: true) } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 25, height: 25)
            }.buttonStyle(.plain).help("사용량 새로고침").accessibilityLabel("사용량 새로고침")
                .disabled(store.selectedState.isRefreshing)
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 13)
    }

    private var footer: some View {
        HStack {
            Button { showWindow("history") } label: { Label("사용 기록", systemImage: "chart.bar") }
            Spacer()
            Button { showWindow("settings") } label: { Label("설정", systemImage: "slider.horizontal.3") }
            Menu {
                Button("공식 사용량 화면") { NSWorkspace.shared.open(provider.dashboardURL) }
                Divider()
                Button("UsageBar 종료", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
        }.font(.caption).buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func showWindow(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }

    private func openClaudeSetup() {
        do {
            try ClaudeProvider.prepareConnectionDirectory()
            guard let script = Bundle.main.url(forResource: "setup-claude", withExtension: "command") else {
                setupMessage = "build 폴더의 UsageBar.app에서 연결 설정을 열어 주세요."
                return
            }
            setupMessage = NSWorkspace.shared.open(script) ? nil : "터미널을 열지 못했어요. 연결 설정 파일을 다시 열어 주세요."
        } catch { setupMessage = error.localizedDescription }
    }

    private static func creditStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "available": return "사용 가능"
        case "used", "consumed", "redeemed": return "사용 완료"
        case "expired": return "만료"
        default: return "상태 확인 필요"
        }
    }

    static func freshness(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "방금 확인" }
        if minutes < 60 { return "\(minutes)분 전 기록" }
        return "\(minutes / 60)시간 전 기록"
    }

    static func relativeDate(_ date: Date, now: Date, expiry: Bool) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return expiry ? "만료 시각 경과" : "리셋 시각 지남 · 확인 필요" }
        let minutes = max(1, seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440)일 \((minutes % 1440) / 60)시간 후" }
        if minutes >= 60 { return "\(minutes / 60)시간 \(minutes % 60)분 후" }
        return "\(minutes)분 후"
    }

    static func tokenLabel(_ number: Int64) -> String {
        if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", Double(number) / 1_000) }
        return String(number)
    }
}
