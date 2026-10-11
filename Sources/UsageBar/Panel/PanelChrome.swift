import AppKit
import SwiftUI
import UsageBarCore

/// Freshness line with the manual refresh button.
struct PanelStatusBar: View {
    @ObservedObject var store: AppStore
    private var provider: ProviderID { store.selectedProvider }
    private var current: Bool { store.freshness(for: provider) == .current }

    var body: some View {
        HStack(spacing: 7) {
            if store.selectedState.isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: current ? "checkmark.circle" : "clock.badge.exclamationmark")
                    .foregroundStyle(current ? UsageTheme.secondaryInk : UsageTheme.warning)
                    .accessibilityHidden(true)
            }
            if let last = store.selectedState.snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("\(UsageFormat.freshness(last, now: context.date)) · \(store.isStale(for: provider) ? store.connectionStatus(for: provider) : "계정 전체")")
                }
            } else {
                Text(store.selectedState.isRefreshing ? "확인 중" : "아직 확인한 기록이 없어요")
            }
            Spacer()
            Button { Task { await store.refresh(provider, force: true) } } label: {
                Image(systemName: "arrow.clockwise").frame(width: UsageSpacing.control, height: UsageSpacing.control)
            }.buttonStyle(.plain).help("사용량 새로고침").accessibilityLabel("사용량 새로고침")
                .disabled(!store.canRefresh(provider))
                .keyboardShortcut("r", modifiers: .command)
        }.font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            .padding(.horizontal, UsageSpacing.panelInset).padding(.vertical, UsageSpacing.item)
    }
}

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

/// History and settings shortcuts plus the overflow menu.
struct PanelFooter: View {
    let provider: ProviderID
    let openWindow: (String) -> Void

    var body: some View {
        HStack {
            Button { openWindow("history") } label: {
                Label("사용 기록", systemImage: "chart.xyaxis.line").frame(minHeight: UsageSpacing.control)
            }
            Spacer()
            Button { openWindow("settings") } label: {
                Label("설정", systemImage: "slider.horizontal.3").frame(minHeight: UsageSpacing.control)
            }
            .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("공식 사용량 화면") { NSWorkspace.shared.open(provider.dashboardURL) }
                Button("서비스 장애 현황") { NSWorkspace.shared.open(provider.statusURL) }
                Divider()
                Button("UsageBar 종료", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).tint(UsageTheme.secondaryInk)
                .frame(width: UsageSpacing.control, height: UsageSpacing.control)
                .accessibilityLabel("추가 메뉴")
        }.font(UsageType.secondary).buttonStyle(.plain)
            .padding(.horizontal, UsageSpacing.panelInset).padding(.vertical, UsageSpacing.item)
    }
}
