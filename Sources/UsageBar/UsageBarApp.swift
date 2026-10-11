import AppKit
import SwiftUI
import UserNotifications
import UsageBarCore

@main
struct UsageBarApp: App {
    @StateObject private var store: AppStore
    @StateObject private var updates: AppUpdateController
    @NSApplicationDelegateAdaptor(UsageBarDelegate.self) private var delegate

    init() {
        let fixture = UpdateConfiguration.isIsolatedFixture(info: Bundle.main.infoDictionary ?? [:], bundleIdentifier: Bundle.main.bundleIdentifier)
        let demo = fixture || CommandLine.arguments.contains("--demo")
        let preferences = UserDefaults(suiteName: demo ? "UsageBar.Preview.Preferences" : "UsageBar.Preferences")!
        let model = AppStore(demo: demo, preferences: preferences)
        let updater = AppUpdateController(demo: demo, journal: model.workJournal)
        _store = StateObject(wrappedValue: model)
        _updates = StateObject(wrappedValue: updater)
        UsageBarDelegate.store = model
        UsageBarDelegate.updates = updater
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store, updates: updates)
        } label: {
            UsageMenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("UsageBar", id: "panel") {
            UsagePanel(store: store, updates: updates)
                .background(FloatingWindowConfigurator())
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Window("사용 기록 · UsageBar", id: "history") {
            HistoryView(store: store)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)

        Window("작업 영수증 · UsageBar", id: "work-journal") {
            WorkJournalView(store: store)
        }
        .defaultSize(width: 520, height: 600)
        .windowResizability(.contentMinSize)

        Window("설정 · UsageBar", id: "settings") {
            PreferencesView(store: store, updates: updates)
        }
        .defaultSize(width: 500, height: 620)
        .windowResizability(.contentSize)
        .commands { UsageBarCommands(updates: updates) }
    }
}

private struct UsageBarCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updates: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("업데이트 확인…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
        CommandGroup(replacing: .appSettings) {
            Button("설정…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let usageBarReopen = Notification.Name("dev.hyjoong.usagebar.reopen")
}

private struct UsageMenuLabel: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var journal: WorkJournalController
    @Environment(\.openWindow) private var openWindow
    #if DEBUG
    @State private var openedCheckWindow = false
    #endif

    init(store: AppStore) {
        self.store = store
        _journal = ObservedObject(wrappedValue: store.workJournal)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: UsageBrandMark.menuImage)
            if store.isDemo { Text("예시").font(.caption2) }
            if let active = journal.state.active {
                // The label is rendered to an image on every update, so it must not host a TimelineView:
                // `.periodic(from: .now)` would reschedule on each render and spin the main thread.
                // The store's clock already ticks once a minute.
                HStack(spacing: 3) {
                    Image(systemName: "record.circle").font(.system(size: 10, weight: .semibold))
                    Text(Self.compactDuration(store.clockNow.timeIntervalSince(active.startedAt))).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("작업 기록 중")
            }
            ForEach(store.menuProviders) { provider in
                HStack(spacing: 4) {
                    if store.menuProviders.count > 1 {
                        Image(systemName: provider.symbol).font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    if store.showPercentage { Text(store.menuTitle(for: provider)).monospacedDigit() }
                }
                .opacity(store.isStale(for: provider) ? 0.6 : 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageBarReopen)) { _ in
            openWindow(id: "panel")
            NSApp.activate(ignoringOtherApps: true)
        }
        .help(store.menuProviders.map { store.menuDescription(for: $0) }.joined(separator: "\n"))
        .accessibilityLabel("UsageBar, " + store.menuProviders.map { store.menuDescription(for: $0) }.joined(separator: ", "))
        #if DEBUG
        .task {
            guard store.isDemo, !openedCheckWindow else { return }
            openedCheckWindow = true
            if CommandLine.arguments.contains("--ui-settings") || UpdateConfiguration.isIsolatedFixture(info: Bundle.main.infoDictionary ?? [:], bundleIdentifier: Bundle.main.bundleIdentifier) { openWindow(id: "settings") }
            if CommandLine.arguments.contains("--ui-history") { openWindow(id: "history") }
            if CommandLine.arguments.contains("--ui-work-journal") { openWindow(id: "work-journal") }
            if CommandLine.arguments.contains("--ui-window") { openWindow(id: "panel") }
            if CommandLine.arguments.contains("--ui-demo-flow") {
                store.workJournal.runDemoFlow { id in try await store.workSnapshot(for: id) }
            }
        }
        #endif
    }

    /// Short enough for the menu bar: minutes under an hour, whole hours after.
    private static func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes < 60 ? String(localized: "\(minutes)분") : String(localized: "\(minutes / 60)시간")
    }
}

@MainActor
final class UsageBarDelegate: NSObject, NSApplicationDelegate {
    static var store: AppStore?
    static var updates: AppUpdateController?
    #if DEBUG
    private var checkWindow: NSWindow?
    #endif
    static let workSessionCategory = "work-session"
    static let finishAction = "work.finish"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.store?.applyAppearance()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let finish = UNNotificationAction(identifier: Self.finishAction, title: String(localized: "작업 종료"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.workSessionCategory, actions: [finish],
                                                                intentIdentifiers: [], options: [])])
        #if DEBUG
        if Self.store?.isDemo == true {
            if CommandLine.arguments.contains("--ui-dark") { Self.store?.appearanceMode = .dark }
            if CommandLine.arguments.contains("--ui-light") { Self.store?.appearanceMode = .light }
        }
        #endif
        Self.store?.start()
        Self.updates?.start()
        #if DEBUG
        if CommandLine.arguments.contains("--ui-check"), let store = Self.store, let updates = Self.updates, store.isDemo {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UsagePanel(store: store, updates: updates)))
            window.title = String(localized: "UsageBar · 예시 화면 검증")
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

    /// Launching the app again (Spotlight, Finder, Dock) opens the panel as a window. This is the
    /// only way in when the menu bar is full and macOS hides the status item under the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .usageBarReopen, object: nil)
        return false
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { Self.store?.stop() }
}

extension UsageBarDelegate: UNUserNotificationCenterDelegate {
    /// The Finish button ends the session without opening the panel; tapping the banner opens the panel window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            if let store = UsageBarDelegate.store {
                if action == UsageBarDelegate.finishAction {
                    await store.workJournal.finish { id in try await store.workSnapshot(for: id) }
                } else {
                    NotificationCenter.default.post(name: .usageBarReopen, object: nil)
                }
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Keeps the detached panel above other windows so it can stay visible during a long task.
private struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FloatingWindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FloatingWindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.level != .floating else { return }
            window.level = .floating
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        }
    }
}
