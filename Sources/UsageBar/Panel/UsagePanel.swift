import AppKit
import SwiftUI
import UsageBarCore

/// The menu bar popover. Composes the header, scrolling quota content, work journal, and chrome.
struct UsagePanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updates: AppUpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var showCredits = false
    @State private var showPace = false
    private var provider: ProviderID { store.selectedProvider }
    private var snapshot: ProviderSnapshot? { store.selectedState.snapshot }

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
            }
            .defaultScrollAnchor(.top)
            .id(provider)
            WorkJournalPanel(store: store) { showWindow("work-journal") }
            PanelStatusBar(store: store)
            PanelUpdateRow(updates: updates)
            Divider()
            PanelFooter(provider: provider, openWindow: showWindow)
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

    @ViewBuilder private func content(_ snapshot: ProviderSnapshot) -> some View {
        if let first = store.trackedWindow(for: provider) {
            QuotaRow(store: store, window: first, prominent: true)
            ConnectionNotice(store: store)
            let others = store.sortedWindows(for: provider).filter { $0.id != first.id }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    Text("다른 한도").font(UsageType.sectionHeading).foregroundStyle(UsageTheme.secondaryInk)
                    ForEach(others) { QuotaRow(store: store, window: $0, prominent: false) }
                }
            }
            if store.freshness(for: provider) == .current,
               let pace = UsagePace.evaluate(window: first, observedAt: snapshot.fetchedAt, now: store.clockNow) {
                Divider()
                PaceSection(pace: pace, isExpanded: $showPace)
            }
        } else {
            Label("제공된 한도 정보가 없어요", systemImage: "info.circle")
                .foregroundStyle(UsageTheme.secondaryInk).font(.callout)
            ConnectionNotice(store: store)
        }
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
