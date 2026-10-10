import AppKit
import SwiftUI
import UsageBarCore

@main
struct UsageBarApp: App {
    @StateObject private var store: AppStore
    @NSApplicationDelegateAdaptor(UsageBarDelegate.self) private var delegate

    init() {
        let model = AppStore(demo: CommandLine.arguments.contains("--demo"))
        _store = StateObject(wrappedValue: model)
        UsageBarDelegate.store = model
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            UsageMenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("사용 기록 · UsageBar", id: "history") {
            HistoryView(store: store)
        }
        .defaultSize(width: 760, height: 660)
        .windowResizability(.contentMinSize)

        Window("작업 영수증 · UsageBar", id: "work-journal") {
            WorkJournalView(store: store)
        }
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentMinSize)

        Window("설정 · UsageBar", id: "settings") {
            PreferencesView(store: store)
        }
        .defaultSize(width: 500, height: 650)
        .windowResizability(.contentSize)
    }
}

private struct UsageMenuLabel: View {
    @ObservedObject var store: AppStore
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    @State private var openedCheckWindow = false
    #endif

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: UsageBrandMark.menuImage)
            if store.isDemo { Text("예시").font(.caption2) }
            ForEach(store.menuProviders) { provider in
                HStack(spacing: 4) {
                    if store.menuProviders.count > 1 {
                        Text(provider == .claude ? "CL" : "CX").font(.system(size: 10, weight: .semibold))
                    }
                    if store.showPercentage { Text(store.menuTitle(for: provider)).monospacedDigit() }
                }
                .opacity(store.isStale(for: provider) ? 0.6 : 1)
            }
        }
        .help(store.menuProviders.map { store.menuDescription(for: $0) }.joined(separator: "\n"))
        .accessibilityLabel("UsageBar, " + store.menuProviders.map { store.menuDescription(for: $0) }.joined(separator: ", "))
        #if DEBUG
        .task {
            guard store.isDemo, !openedCheckWindow else { return }
            openedCheckWindow = true
            if CommandLine.arguments.contains("--ui-settings") { openWindow(id: "settings") }
            if CommandLine.arguments.contains("--ui-history") { openWindow(id: "history") }
            if CommandLine.arguments.contains("--ui-work-journal") { openWindow(id: "work-journal") }
        }
        #endif
    }
}

@MainActor
final class UsageBarDelegate: NSObject, NSApplicationDelegate {
    static var store: AppStore?
    #if DEBUG
    private var checkWindow: NSWindow?
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.store?.applyAppearance()
        #if DEBUG
        if Self.store?.isDemo == true {
            if CommandLine.arguments.contains("--ui-dark") { Self.store?.appearanceMode = .dark }
            if CommandLine.arguments.contains("--ui-light") { Self.store?.appearanceMode = .light }
        }
        #endif
        Self.store?.start()
        #if DEBUG
        if CommandLine.arguments.contains("--ui-check"), let store = Self.store, store.isDemo {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UsagePanel(store: store)))
            window.title = "UsageBar · 예시 화면 검증"
            window.styleMask = [.titled, .closable]
            window.isRestorable = false
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            checkWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { Self.store?.stop() }
}
