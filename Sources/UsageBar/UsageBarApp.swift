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
    @Environment(\.colorScheme) private var menuBarScheme
    #if DEBUG
    @State private var openedCheckWindow = false
    #endif

    init(store: AppStore) {
        self.store = store
        _journal = ObservedObject(wrappedValue: store.workJournal)
    }

    var body: some View {
        // A menu bar extra label draws only its first Image and first Text and drops inline symbols,
        // so the whole label is rendered into one template image.
        Image(nsImage: renderedLabel)
        .onReceive(NotificationCenter.default.publisher(for: .usageBarReopen)) { _ in
            openWindow(id: "panel")
            NSApp.activate(ignoringOtherApps: true)
        }
        .help(store.menuProviders.map { store.menuDescription(for: $0) }.joined(separator: "\n"))
        .accessibilityLabel("UsageBar, " + (journal.state.active == nil ? "" : String(localized: "작업 기록 중") + ", ")
                            + store.menuProviders.map { store.menuDescription(for: $0) }.joined(separator: ", "))
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

    /// Normally rendered black as a template so the menu bar tints it for light, dark and highlighted states.
    /// When a service is at or below the low-limit line, only that service is drawn in orange: a template
    /// cannot carry color, so the image is drawn in color and everything else takes the menu bar's own
    /// text color, read from the label's color scheme (it follows the menu bar, not the system setting).
    /// Orange reads on both light and dark menu bars.
    /// This runs on every label update, so the content must not host a TimelineView: `.periodic(from: .now)`
    /// would reschedule on each render and spin the main thread. The store's clock ticks once a minute.
    private var renderedLabel: NSImage {
        let low = store.menuIsLow
        let renderer = ImageRenderer(content: content
            .font(Font(NSFont.menuBarFont(ofSize: 0)))
            .foregroundStyle(plainColor))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? UsageBrandMark.menuImage
        image.isTemplate = !low
        return image
    }

    /// Black for the template; in a colored image, the menu bar's own text color.
    private var plainColor: Color { store.menuIsLow && menuBarScheme == .dark ? .white : .black }

    private var content: some View {
        HStack(spacing: 6) {
            if store.menuShowsIcon { Image(nsImage: UsageBrandMark.menuImage).renderingMode(.template) }
            if store.isDemo { Text("예시").font(.caption2) }
            if let active = journal.state.active {
                HStack(spacing: 3) {
                    Image(systemName: "record.circle").font(.system(size: 10, weight: .semibold))
                    Text(verbatim: UsageFormat.compactDuration(store.clockNow.timeIntervalSince(active.startedAt))).monospacedDigit()
                }
            }
            ForEach(store.menuProviders) { provider in
                HStack(spacing: 4) {
                    if store.menuProviders.count > 1 {
                        Image(systemName: provider.symbol).font(.system(size: 10, weight: .semibold))
                    }
                    let title = store.menuTitle(for: provider)
                    if !title.isEmpty { Text(verbatim: title).monospacedDigit() }
                }
                .foregroundStyle(store.menuIsLow(for: provider) ? Color(nsColor: .systemOrange) : plainColor)
                .opacity(store.isStale(for: provider) ? 0.6 : 1)
            }
        }
        .fixedSize()
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
