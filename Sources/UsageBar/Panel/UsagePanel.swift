import AppKit
import SwiftUI
import UsageBarCore

/// The menu bar popover. Hugs its content up to a ceiling, then scrolls the quota area.
struct UsagePanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updates: AppUpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var showCredits = false
    @State private var showPace = false
    @State private var contentHeight: CGFloat = Self.maxContentHeight
    private var provider: ProviderID { store.selectedProvider }
    private var snapshot: ProviderSnapshot? { store.selectedState.snapshot }

    static let width: CGFloat = 360
    static let maxContentHeight: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(store: store)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: UsageSpacing.section) {
                    if let snapshot {
                        content(snapshot)
                    } else {
                        PanelEmptyState(store: store)
                    }
                }
                .padding(.horizontal, UsageSpacing.panelInset).padding(.vertical, 16)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(height: min(contentHeight, Self.maxContentHeight))
            .defaultScrollAnchor(.top)
            .id(provider)
            WorkJournalPanel(store: store) { showWindow("work-journal") }
            PanelUpdateRow(updates: updates)
            Divider().padding(.top, UsageSpacing.compact)
            PanelFooter(store: store, openWindow: showWindow)
        }
        .frame(width: Self.width)
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

    @ViewBuilder private func content(_ snapshot: ProviderSnapshot) -> some View {
        if let first = store.primaryWindow(for: provider) {
            QuotaRow(store: store, window: first, prominent: true)
            if store.freshness(for: provider) == .current,
               let pace = UsagePace.evaluate(window: first, observedAt: snapshot.fetchedAt, now: store.clockNow) {
                PaceSection(pace: pace, isExpanded: $showPace)
            }
            ConnectionNotice(store: store)
            let others = store.sortedWindows(for: provider).filter { $0.id != first.id }
            if !others.isEmpty {
                Divider()
                ForEach(others) { QuotaRow(store: store, window: $0, prominent: false) }
            }
        } else {
            Label("제공된 한도 정보가 없어요", systemImage: "info.circle")
                .foregroundStyle(UsageTheme.secondaryInk).font(.callout)
            ConnectionNotice(store: store)
        }
        let extras = snapshot.resetCreditCount != nil || !(snapshot.dailyUsage ?? []).isEmpty
        if extras { Divider() }
        CreditExpiryRow(snapshot: snapshot, now: store.clockNow)
        if let count = snapshot.resetCreditCount {
            CreditsSection(snapshot: snapshot, count: count, isExpanded: $showCredits)
        }
        if let daily = snapshot.dailyUsage, !daily.isEmpty {
            DailyTokensRow(daily: daily) { showWindow("history") }
        }
    }

    private func showWindow(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
