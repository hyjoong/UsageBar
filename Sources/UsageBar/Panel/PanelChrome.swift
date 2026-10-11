import AppKit
import SwiftUI
import UsageBarCore

/// Row announcing an update found by a background check.
struct PanelUpdateRow: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        if let version = updates.availableVersion {
            Button { updates.checkForUpdates() } label: {
                HStack {
                    Label("\(version) 업데이트 가능", systemImage: "arrow.down.circle")
                    Spacer()
                    Text("확인").foregroundStyle(UsageTheme.accent)
                }.font(UsageType.secondary).padding(.horizontal, UsageSpacing.panelInset).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(!updates.canCheckForUpdates)
        }
    }
}

/// Freshness on the left; refresh, history, settings, and the overflow menu on the right.
struct PanelFooter: View {
    @ObservedObject var store: AppStore
    let openWindow: (String) -> Void
    private var provider: ProviderID { store.selectedProvider }
    private var current: Bool { store.freshness(for: provider) == .current }

    var body: some View {
        HStack(spacing: UsageSpacing.tight) {
            status
            Spacer(minLength: UsageSpacing.item)
            iconButton("arrow.clockwise", help: "사용량 새로고침") {
                Task { await store.refresh(provider, force: true) }
            }
            .disabled(!store.canRefresh(provider))
            .keyboardShortcut("r", modifiers: .command)
            iconButton("chart.xyaxis.line", help: "사용 기록") { openWindow("history") }
            iconButton("slider.horizontal.3", help: "설정") { openWindow("settings") }
                .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("공식 사용량 화면") { NSWorkspace.shared.open(provider.dashboardURL) }
                Button("서비스 장애 현황") { NSWorkspace.shared.open(provider.statusURL) }
                Divider()
                Button("UsageBar 종료", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(UsageTheme.secondaryInk)
                .frame(width: UsageSpacing.control, height: UsageSpacing.control)
                .accessibilityLabel("추가 메뉴")
        }
        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
        .padding(.leading, UsageSpacing.panelInset).padding(.trailing, UsageSpacing.panelInset - 6)
        .padding(.vertical, UsageSpacing.compact)
    }

    private var status: some View {
        HStack(spacing: UsageSpacing.compact) {
            if store.selectedState.isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: current ? "checkmark.circle" : "clock.badge.exclamationmark")
                    .foregroundStyle(current ? UsageTheme.secondaryInk : UsageTheme.warning)
                    .accessibilityHidden(true)
            }
            if let last = store.selectedState.snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(statusText(last: last, now: context.date))
                }
            } else {
                Text(store.selectedState.isRefreshing ? "확인 중" : "아직 확인한 기록이 없어요")
            }
        }
        .lineLimit(1)
        .help("계정 전체 사용량 · 다른 창·기기에서 쓴 양도 포함돼요")
    }

    private func statusText(last: Date, now: Date) -> String {
        var parts = [UsageFormat.freshness(last, now: now)]
        if store.isStale(for: provider) { parts.append(store.connectionStatus(for: provider)) }
        return parts.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(UsageType.label)
                .frame(width: UsageSpacing.control, height: UsageSpacing.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
