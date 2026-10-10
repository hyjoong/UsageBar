import AppKit
import SwiftUI
import UsageBarCore

extension ProviderID {
    var tint: Color { UsageTheme.accent }
    var symbol: String { self == .claude ? "asterisk.circle.fill" : "terminal.fill" }
    var statusURL: URL { URL(string: self == .claude ? "https://status.claude.com" : "https://status.openai.com")! }
    var dashboardURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
}

struct UsagePanel: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var showCredits = false
    @State private var showPace = false
    @State private var setupMessage: String?
    private var provider: ProviderID { store.selectedProvider }
    private var snapshot: ProviderSnapshot? { store.selectedState.snapshot }
    private var demo: Bool { store.isDemo }
    private var planLabel: String {
        guard let snapshot else { return "연결 확인" }
        let plan = snapshot.plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plan.isEmpty ? "계정 사용량" : plan
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let snapshot {
                        if let first = store.trackedWindow(for: provider) {
                            quota(first, prominent: true)
                            connectionNotice
                            timeline(snapshot, excluding: first.id)
                            let others = store.sortedWindows(for: provider).filter { $0.id != first.id }
                            if !others.isEmpty {
                                VStack(alignment: .leading, spacing: 15) {
                                    sectionLabel("다른 한도")
                                    ForEach(others) { quota($0, prominent: false) }
                                }
                            }
                            if store.freshness(for: provider) == .current,
                               let pace = UsagePace.evaluate(window: first, observedAt: snapshot.fetchedAt, now: store.clockNow) {
                                Divider()
                                DisclosureGroup(isExpanded: $showPace) {
                                    paceCard(pace).padding(.top, 12)
                                } label: {
                                    HStack {
                                        Text("사용 속도")
                                        Spacer()
                                        Text(paceTitle(pace)).foregroundStyle(UsageTheme.secondaryInk)
                                    }.font(.system(size: 12))
                                }
                            }
                        } else {
                            Label("제공된 한도 정보가 없어요", systemImage: "info.circle")
                                .foregroundStyle(UsageTheme.secondaryInk).font(.callout)
                            connectionNotice
                        }
                        if let count = snapshot.resetCreditCount {
                            DisclosureGroup(isExpanded: $showCredits) {
                                VStack(spacing: 12) { credits(snapshot) }.padding(.top, 12)
                            } label: {
                                HStack {
                                    Label("초기화권", systemImage: "ticket")
                                    Spacer()
                                    Text("\(count)장").monospacedDigit()
                                }.font(.system(size: 12))
                            }
                        }
                        if let daily = snapshot.dailyUsage, !daily.isEmpty {
                            Button { showWindow("history") } label: {
                                HStack {
                                    Label("최근 일별 토큰", systemImage: "chart.bar")
                                    Spacer()
                                    Text(Self.tokenLabel(daily.last?.tokens ?? 0)).monospacedDigit()
                                    Image(systemName: "arrow.up.right").foregroundStyle(UsageTheme.secondaryInk)
                                }.font(.system(size: 12)).frame(minHeight: 28)
                            }.buttonStyle(.plain)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
            }
            .defaultScrollAnchor(.top)
            .id(provider)
            WorkJournalShortcut(journal: store.workJournal) { showWindow("work-journal") }
            status
            Divider()
            footer
        }
        .frame(width: 392, height: 640)
        .background(UsageTheme.canvas)
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        .task { await store.refresh(provider) }
        .onChange(of: store.selectedProvider) { _, newValue in
            showCredits = false
            showPace = false
            Task { await store.refresh(newValue) }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                UsageBrandMark().frame(width: 28, height: 28)
                Text("UsageBar").font(.system(size: 15, weight: .semibold))
                Spacer()
                if demo {
                    Text("예시 데이터").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                } else {
                    Text("계정 전체").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                }
            }
            HStack(spacing: 14) {
                if store.activeProviders.count > 1 {
                    Picker("서비스", selection: $store.selectedProvider) {
                        ForEach(store.activeProviders) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 185)
                } else {
                    Label(provider.title, systemImage: provider.symbol)
                        .font(.system(size: 13, weight: .medium))
                }
                Spacer(minLength: 0)
                Text(planLabel)
                    .font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
                    .lineLimit(2).multilineTextAlignment(.trailing)
            }
        }.padding(.horizontal, 22).padding(.vertical, 14)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(UsageTheme.secondaryInk)
    }

    private func pin(_ window: UsageWindow, selected: Bool) -> some View {
        Button { store.selectWindow(window.id, for: provider) } label: {
            Image(systemName: selected ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? UsageTheme.accent : UsageTheme.secondaryInk)
                .frame(width: 28, height: 28)
                .background(selected ? UsageTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(selected ? "메뉴바에 표시 중" : "이 한도를 메뉴바에 표시")
        .accessibilityLabel("\(window.label) 메뉴바에 표시")
        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
    }

    private func quota(_ window: UsageWindow, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: prominent ? 8 : 6) {
            if prominent {
                HStack {
                    Text(window.label).font(.system(size: 13, weight: .medium))
                    Text("메뉴바에 표시 중").font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                    Spacer()
                    pin(window, selected: true)
                }
                QuotaInstrument(window: window, freshness: store.freshness(for: provider), now: store.clockNow)
            } else {
                HStack(spacing: 9) {
                    Text(window.label).font(.system(size: 13))
                    Spacer()
                    Text("\(Int(window.remainingPercent.rounded()))% 남음")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    pin(window, selected: false)
                }
            }
            if !prominent {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(UsageTheme.mutedSurface)
                        Capsule().fill(window.remainingPercent <= 20 ? UsageTheme.warning : UsageTheme.ink.opacity(0.8))
                            .frame(width: max(0, proxy.size.width * window.remainingPercent / 100))
                    }
                }.frame(height: 4)
                    .accessibilityLabel("\(window.label) 남은 한도")
                    .accessibilityValue("\(Int(window.remainingPercent.rounded()))퍼센트")
            }
            if prominent && window.remainingPercent <= 20 {
                Label(store.freshness(for: provider) == .current ? "남은 한도가 20% 이하예요" : "마지막 기록에서 20% 이하였어요", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(UsageTheme.warning)
            }
        }
    }

    @ViewBuilder private var connectionNotice: some View {
        if let notice = store.selectionNotice(for: provider) {
            Label(notice, systemImage: "pin.slash")
                .font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = store.selectedState.errorMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(UsageTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button("서비스 장애 현황 확인") { NSWorkspace.shared.open(provider.statusURL) }
                .buttonStyle(.link).font(.caption)
        }
        if let retry = store.retryMessage(for: provider) {
            Label(retry, systemImage: "clock")
                .font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
        }
        if store.selectedState.requiresConnection, provider == .claude {
            Button("Claude 다시 연결") { openClaudeSetup() }.buttonStyle(.bordered)
            if let setupMessage { Text(setupMessage).font(.caption).foregroundStyle(UsageTheme.warning) }
        }
    }

    private func paceTitle(_ pace: UsagePace) -> String {
        switch pace.position {
        case .behind: "여유 있는 속도"
        case .onTrack: "기준과 비슷한 속도"
        case .ahead: "빠르게 사용 중"
        }
    }

    private func paceCard(_ pace: UsagePace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            paceRow("기간 경과", percent: pace.elapsedPercent, color: UsageTheme.secondaryInk)
            paceRow("한도 사용", percent: pace.usedPercent, color: pace.position == .ahead ? UsageTheme.warning : UsageTheme.ink)
            Text("마지막 조회 시점 · 기간을 고르게 사용하는 기준")
                .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("기간 경과율과 실제 한도 사용률을 비교해요. 사용 패턴에 따라 차이가 날 수 있어요.")
    }

    private func paceRow(_ label: String, percent: Double, color: Color) -> some View {
        HStack(spacing: 9) {
            Text(label).frame(width: 55, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageTheme.mutedSurface)
                    Capsule().fill(color).frame(width: proxy.size.width * percent / 100)
                }
            }.frame(height: 4)
            Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 36, alignment: .trailing)
        }.font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(label) \(Int(percent.rounded()))퍼센트")
    }

    private struct ResetEvent: Identifiable {
        let id: String
        let title: String
        let date: Date
        let expiry: Bool
    }

    @ViewBuilder private func timeline(_ snapshot: ProviderSnapshot, excluding selectedID: String) -> some View {
        let valid = UsageWindowSelection.validWindows(snapshot.windows).filter { $0.id != selectedID }
        let resets = valid.compactMap { window in
            window.resetsAt.map { ResetEvent(id: "window-" + window.id, title: window.label, date: $0, expiry: false) }
        }
        let credit = snapshot.resetCredits?.filter {
            $0.status.lowercased() == "available" && ($0.expiresAt.map { $0 > store.clockNow } ?? false)
        }.min { $0.expiresAt! < $1.expiresAt! }
        let expiry = credit?.expiresAt.map { [ResetEvent(id: "credit-expiry", title: "첫 초기화권 만료", date: $0, expiry: true)] } ?? []
        let events = (resets + expiry).sorted { $0.date < $1.date }.prefix(3)
        if !events.isEmpty || valid.contains(where: { $0.resetsAt == nil }) {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("다른 리셋 일정")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(UsageTheme.secondaryInk).frame(width: 10, height: 2)
                                Rectangle().fill(UsageTheme.separator)
                                    .frame(width: 1, height: index == events.count - 1 ? 0 : 40)
                            }.frame(width: 10).padding(.top, 7).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(event.title).font(.system(size: 12, weight: .medium))
                                    Spacer(minLength: 3)
                                    Text(Self.relativeDate(event.date, now: store.clockNow, expiry: event.expiry))
                                        .font(.system(size: 12)).monospacedDigit()
                                        .multilineTextAlignment(.trailing)
                                }
                                Text(event.date.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().weekday().hour().minute()))
                                    .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                            }.padding(.bottom, index == events.count - 1 ? 0 : 14)
                        }.accessibilityElement(children: .combine)
                    }
                }
                ForEach(valid.filter { $0.resetsAt == nil }) { window in
                    Text("\(window.label) · \(window.resetDescription ?? "리셋 시각 미제공")")
                        .font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func credits(_ snapshot: ProviderSnapshot) -> some View {
        if let credits = snapshot.resetCredits {
            if credits.isEmpty {
                Text("표시할 초기화권 상세가 없어요").font(.caption).foregroundStyle(UsageTheme.secondaryInk)
            }
            ForEach(credits) { credit in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(credit.title.isEmpty ? "초기화권" : credit.title)
                        Text(Self.creditStatus(credit.status)).foregroundStyle(UsageTheme.secondaryInk)
                    }
                    Spacer()
                    Text(credit.expiresAt.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "만료 없음")
                        .foregroundStyle(UsageTheme.secondaryInk)
                }.font(.caption)
            }
        } else {
            Text("초기화권 상세가 제공되지 않았어요").font(.caption).foregroundStyle(UsageTheme.secondaryInk)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            if store.selectedState.isRefreshing {
                ProgressView().controlSize(.small)
                Text("\(provider.title) 한도 확인 중").font(.headline)
                Text(provider == .claude ? "Claude Code의 사용량 화면을 확인하고 있어요." : "로그인된 Codex 계정의 한도를 확인하고 있어요.")
                    .foregroundStyle(UsageTheme.secondaryInk).font(.caption)
            } else {
                Image(systemName: "link.circle").font(.system(size: 30)).foregroundStyle(provider.tint)
                Text("\(provider.title) 연결 확인").font(.headline)
                Text(store.selectedState.errorMessage ?? (provider == .claude ? "로그인된 Claude Code의 한도와 리셋 시각을 확인해요." : "로그인된 Codex의 한도와 토큰 기록을 확인해요."))
                    .font(.callout).foregroundStyle(UsageTheme.secondaryInk).fixedSize(horizontal: false, vertical: true)
                Button("다시 확인") { Task { await store.refresh(provider, force: true) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canRefresh(provider))
                if let retry = store.retryMessage(for: provider) {
                    Text(retry).font(.caption).foregroundStyle(UsageTheme.secondaryInk)
                }
                if provider == .claude {
                    Button("Claude 연결 설정") { openClaudeSetup() }
                        .buttonStyle(.bordered)
                    Button("Claude Code 설치 안내") {
                        NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/quickstart")!)
                    }.font(.caption).buttonStyle(.link)
                    Text("터미널에서 처음 한 번 연결을 확인해 주세요.")
                        .font(.caption).foregroundStyle(UsageTheme.secondaryInk)
                    if let setupMessage {
                        Text(setupMessage).font(.caption).foregroundStyle(UsageTheme.warning)
                    }
                }
                Button("공식 사용량 화면 열기") { NSWorkspace.shared.open(provider.dashboardURL) }
                    .font(.caption).buttonStyle(.link)
                Button("서비스 장애 현황 확인") { NSWorkspace.shared.open(provider.statusURL) }
                    .font(.caption).buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 26)
    }

    private var status: some View {
        HStack(spacing: 7) {
            if store.selectedState.isRefreshing { ProgressView().controlSize(.mini) }
            else { Image(systemName: store.freshness(for: provider) == .current ? "checkmark.circle" : "clock.badge.exclamationmark").foregroundStyle(store.freshness(for: provider) == .current ? UsageTheme.secondaryInk : UsageTheme.warning).accessibilityHidden(true) }
            if let last = snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("\(Self.freshness(last, now: context.date)) · \(store.isStale(for: provider) ? store.connectionStatus(for: provider) : "계정 전체")")
                }
            } else {
                Text(store.selectedState.isRefreshing ? "확인 중" : "아직 확인한 기록이 없어요")
            }
            Spacer()
            Button { Task { await store.refresh(provider, force: true) } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }.buttonStyle(.plain).help("사용량 새로고침").accessibilityLabel("사용량 새로고침")
                .disabled(!store.canRefresh(provider))
                .keyboardShortcut("r", modifiers: .command)
        }.font(.system(size: 11)).foregroundStyle(UsageTheme.secondaryInk).padding(.horizontal, 22).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button { showWindow("history") } label: { Label("사용 기록", systemImage: "chart.xyaxis.line").frame(minHeight: 28) }
            Spacer()
            Button { showWindow("settings") } label: { Label("설정", systemImage: "slider.horizontal.3").frame(minHeight: 28) }
                .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("공식 사용량 화면") { NSWorkspace.shared.open(provider.dashboardURL) }
                Button("서비스 장애 현황") { NSWorkspace.shared.open(provider.statusURL) }
                Divider()
                Button("UsageBar 종료", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).tint(UsageTheme.secondaryInk).frame(width: 28, height: 28).accessibilityLabel("추가 메뉴")
        }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 22).padding(.vertical, 8)
    }

    private func showWindow(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }

    private func openClaudeSetup() {
        do {
            guard let script = Bundle.main.url(forResource: "setup-claude", withExtension: "command") else {
                setupMessage = "build 폴더의 UsageBar.app에서 연결 설정을 열어 주세요."
                return
            }
            let launcher = try ClaudeProvider.prepareConnectionScript(scriptURL: script)
            setupMessage = NSWorkspace.shared.open(launcher) ? nil : "터미널을 열지 못했어요. 연결 설정 파일을 다시 열어 주세요."
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

private struct WorkJournalShortcut: View {
    @ObservedObject var journal: WorkJournalController
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: journal.state.active == nil ? "receipt" : "record.circle")
                    .foregroundStyle(UsageTheme.accent)
                if let active = journal.state.active {
                    Text("\(active.kind.title) 기록 중").fontWeight(.medium)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let elapsed = context.date.timeIntervalSince(active.startedAt)
                        let minutes = elapsed.isFinite ? Int(min(max(0, elapsed / 60), Double(Int.max / 2))) : 0
                        Text("\(minutes)분")
                            .monospacedDigit()
                    }
                } else {
                    Text("작업 영수증")
                    Spacer()
                    Text("이번 작업의 한도 변화").foregroundStyle(UsageTheme.secondaryInk)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(journal.state.active == nil ? "작업 영수증 열기" : "진행 중인 작업 영수증 열기")
        .padding(.horizontal, 22).padding(.top, 7)
    }
}
