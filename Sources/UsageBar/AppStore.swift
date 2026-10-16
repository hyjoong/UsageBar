import AppKit
import Combine
import Foundation
import UsageBarCore
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case selected, all
    var id: String { rawValue }
    var title: String { self == .selected ? String(localized: "선택한 서비스") : String(localized: "사용 중인 서비스 모두") }
}

/// UI language. Localization is resolved at launch, so a change needs a relaunch.
enum UsageLanguage: String, CaseIterable, Identifiable {
    case system, ko, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "시스템 설정 따르기")
        case .ko: "한국어"
        case .en: "English"
        }
    }
    /// What AppleLanguages must contain for this choice, or nil to follow the system.
    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .ko: ["ko", "en"]
        case .en: ["en", "ko"]
        }
    }

    static func current(from defaults: UserDefaults = .standard) -> UsageLanguage {
        guard defaults.bool(forKey: "usageBarLanguageOverride"),
              let first = defaults.stringArray(forKey: "AppleLanguages")?.first else { return .system }
        return first.hasPrefix("ko") ? .ko : (first.hasPrefix("en") ? .en : .system)
    }
}

enum UsageAppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: String(localized: "어둡게")
        case .light: String(localized: "밝게")
        case .system: String(localized: "시스템 설정 따르기")
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

struct ProviderState {
    enum ConnectionIssue {
        case setup, authentication, unsupported
    }

    var snapshot: ProviderSnapshot?
    var isRefreshing = false
    var errorMessage: String?
    var connectionIssue: ConnectionIssue?
    var requiresConnection: Bool { connectionIssue != nil }
    var lastAttempt: Date?
}

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedProvider: ProviderID = .claude {
        didSet { if !isDemo { defaults.set(selectedProvider.rawValue, forKey: "selectedProvider") } }
    }
    @Published var appearanceMode: UsageAppearanceMode = .dark {
        didSet {
            if !isDemo { defaults.set(appearanceMode.rawValue, forKey: "appearanceMode") }
            applyAppearance()
        }
    }
    @Published var language: UsageLanguage = .system {
        didSet {
            guard !isDemo, language != oldValue else { return }
            let standard = UserDefaults.standard
            if let languages = language.appleLanguages {
                standard.set(languages, forKey: "AppleLanguages")
                standard.set(true, forKey: "usageBarLanguageOverride")
            } else {
                standard.removeObject(forKey: "AppleLanguages")
                standard.removeObject(forKey: "usageBarLanguageOverride")
            }
            needsRelaunchForLanguage = language != languageAtLaunch
        }
    }
    @Published private(set) var needsRelaunchForLanguage = false
    private var languageAtLaunch: UsageLanguage = .system
    @Published private(set) var states: [ProviderID: ProviderState] = [:]
    @Published private(set) var clockNow = Date()
    @Published var menuBarDisplayMode: MenuBarDisplayMode = .selected {
        didSet { if !isDemo { defaults.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode") } }
    }
    @Published private(set) var enabledProviders: Set<ProviderID> = Set(ProviderID.allCases)
    @Published var showResetCountdown = false {
        didSet { if !isDemo { defaults.set(showResetCountdown, forKey: "showResetCountdown") } }
    }
    @Published var showPercentage = true {
        didSet { if !isDemo { defaults.set(showPercentage, forKey: "showPercentage") } }
    }
    @Published var trackedWindowIDs: [ProviderID: String] = [:] {
        didSet {
            if !isDemo {
                defaults.set(Dictionary(uniqueKeysWithValues: trackedWindowIDs.map { ($0.key.rawValue, $0.value) }),
                             forKey: "trackedWindowIDs")
            }
        }
    }
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var recoveryNotificationsEnabled = false
    @Published private(set) var runOutNotificationsEnabled = false
    /// Keeps the Claude Code status line file current. Turned on by installing or copying the status line.
    @Published private(set) var statusLineEnabled = false {
        didSet { if !isDemo { defaults.set(statusLineEnabled, forKey: "statusLineEnabled") } }
    }
    @Published private(set) var statusLineState: ClaudeStatusLine.State = .notConfigured
    @Published private(set) var statusLineMessage: String?
    /// Run-out warnings already sent, by provider, window and period. One per period is enough.
    private var runOutNotified: Set<String> = []
    /// Reminds about a running work session: a check-in after two hours and a warning before the limit resets.
    @Published var workRemindersEnabled = true {
        didSet {
            if !isDemo { defaults.set(workRemindersEnabled, forKey: "workRemindersEnabled") }
            Task { await syncWorkReminders() }
        }
    }
    /// Adds models, tokens and project folders from this Mac's CLI session logs to each receipt.
    @Published var sessionDetailsEnabled = true {
        didSet { if !isDemo { defaults.set(sessionDetailsEnabled, forKey: "sessionDetailsEnabled") } }
    }
    private var journalObservation: AnyCancellable?
    /// UNUserNotificationCenter needs a real app bundle; tests and demo runs must never touch it.
    private let notificationsAvailable: Bool
    @Published private(set) var historyPoints: [HistoryPoint] = []
    @Published private(set) var storageNotice: String?
    @Published private(set) var notificationMessage: String?

    let isDemo: Bool
    let workJournal: WorkJournalController
    private let defaults: UserDefaults
    private let providers: [ProviderID: any UsageProvider]
    private let historyStore: HistoryStore?
    private var refreshTasks: [ProviderID: Task<Void, Never>] = [:]
    private var successfulRefreshTokens: [ProviderID: UUID] = [:]
    private var taskTokens: [ProviderID: UUID] = [:]
    @Published private var retryStates: [ProviderID: RetryState] = [:]
    private var observations: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var resetRefreshes: [ProviderID: [String: Date]] = [:]
    private var startupTask: Task<Void, Never>?
    private var started = false
    private var sleeping = false
    private var generation = 0
    private var notificationTracking: [String: QuotaAlertState] = [:]
    private var notificationSettingToken = UUID()

    private struct RetryState {
        var attempts: Int
        var notBefore: Date
        var rateLimited: Bool
    }

    init(demo: Bool = false, providerOverrides: [ProviderID: any UsageProvider]? = nil,
         preferences: UserDefaults = UserDefaults(suiteName: "UsageBar.Preferences")!) {
        isDemo = demo
        workJournal = WorkJournalController(demo: demo, usesPersistence: providerOverrides == nil)
        defaults = preferences
        providers = providerOverrides ?? (demo ? [:] : [.claude: ClaudeProvider(), .codex: CodexProvider()])
        historyStore = demo || providerOverrides != nil ? nil : HistoryStore()
        notificationsAvailable = !demo && providerOverrides == nil && Bundle.main.bundleIdentifier != nil
        states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderState()) })
        journalObservation = workJournal.$state.map { $0.active?.id }.removeDuplicates()
            .sink { [weak self] _ in Task { await self?.syncWorkReminders(); self?.exportStatusLine() } }
        workJournal.historyProvider = { [weak self] provider in self?.history(for: provider) ?? [] }
        workJournal.activityCollector = { [weak self] provider, start, end in
            guard let self, self.sessionDetailsEnabled else { return nil }
            if self.isDemo { return .demo }
            guard self.historyStore != nil else { return nil }   // tests with fake providers never touch the home folder
            return await Task.detached(priority: .utility) {
                LocalSessionLogs.activity(for: provider, between: start, and: end)
            }.value
        }
        if demo {
            installDemo()
        } else {
            appearanceMode = UsageAppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .dark
            languageAtLaunch = UsageLanguage.current()
            language = languageAtLaunch
            selectedProvider = ProviderID(rawValue: defaults.string(forKey: "selectedProvider") ?? "") ?? .claude
            menuBarDisplayMode = MenuBarDisplayMode(rawValue: defaults.string(forKey: "menuBarDisplayMode") ?? "") ?? .selected
            if defaults.object(forKey: "showPercentage") != nil { showPercentage = defaults.bool(forKey: "showPercentage") }
            showResetCountdown = defaults.bool(forKey: "showResetCountdown")
            if let saved = defaults.stringArray(forKey: "enabledProviders") {
                let enabled = Set(saved.compactMap(ProviderID.init(rawValue:)))
                enabledProviders = enabled.isEmpty ? [.claude] : enabled
            }
            if !enabledProviders.contains(selectedProvider) {
                selectedProvider = activeProviders.first ?? .claude
            }
            notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
            recoveryNotificationsEnabled = defaults.bool(forKey: "recoveryNotificationsEnabled")
            runOutNotificationsEnabled = defaults.bool(forKey: "runOutNotificationsEnabled")
            statusLineEnabled = defaults.bool(forKey: "statusLineEnabled")
            if defaults.object(forKey: "workRemindersEnabled") != nil {
                workRemindersEnabled = defaults.bool(forKey: "workRemindersEnabled")
            }
            if defaults.object(forKey: "sessionDetailsEnabled") != nil {
                sessionDetailsEnabled = defaults.bool(forKey: "sessionDetailsEnabled")
            }
            if let saved = defaults.dictionary(forKey: "trackedWindowIDs") as? [String: String] {
                trackedWindowIDs = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                    ProviderID(rawValue: key).map { ($0, value) }
                })
            }
        }
    }

    /// Keeps pending session reminders in step with the active session and the current reset time.
    func syncWorkReminders() async {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: WorkReminderKind.allIdentifiers)
        guard workRemindersEnabled, let active = workJournal.state.active else { return }
        // Hidden override for testing the flow without waiting two hours:
        // defaults write dev.hyjoong.usagebar workReminderCheckInMinutes 1
        let checkInMinutes = UserDefaults.standard.integer(forKey: "workReminderCheckInMinutes")
        let plan = WorkReminderPlan.reminders(startedAt: active.startedAt,
                                              resetsAt: primaryWindow(for: active.provider)?.resetsAt, now: Date(),
                                              checkInAfter: TimeInterval(checkInMinutes > 0 ? checkInMinutes : 120) * 60)
        guard !plan.isEmpty else { return }
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        for reminder in plan {
            let content = UNMutableNotificationContent()
            content.categoryIdentifier = UsageBarDelegate.workSessionCategory
            content.sound = .default
            switch reminder.kind {
            case .checkIn:
                content.title = String(localized: "작업 기록이 아직 진행 중이에요")
                content.body = String(localized: "\(active.kind.title) · \(active.provider.title) · 시작한 지 2시간")
            case .beforeReset:
                content.title = String(localized: "\(active.provider.title) 한도 리셋 10분 전")
                content.body = String(localized: "지금 종료해야 이번 작업의 한도 변화를 비교할 수 있어요")
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireAt.timeIntervalSinceNow), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.kind.notificationIdentifier, content: content, trigger: trigger))
        }
    }

    func applyAppearance() {
        NSApplication.shared.appearance = appearanceMode.appearance
    }

    /// Quits and reopens the app bundle so the new language takes effect. The helper waits for
    /// this process to exit first; opening too early would only re-activate the old instance.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    var selectedState: ProviderState { states[selectedProvider] ?? ProviderState() }

    var activeProviders: [ProviderID] { ProviderID.allCases.filter { enabledProviders.contains($0) } }
    var menuProviders: [ProviderID] { menuBarDisplayMode == .all ? activeProviders : [selectedProvider] }

    func setProviderEnabled(_ enabled: Bool, for provider: ProviderID) {
        guard enabled != enabledProviders.contains(provider) else { return }
        if enabled {
            enabledProviders.insert(provider)
        } else {
            guard enabledProviders.count > 1 else { return }
            enabledProviders.remove(provider)
            refreshTasks[provider]?.cancel()
            states[provider]?.isRefreshing = false
            if selectedProvider == provider { selectedProvider = activeProviders.first ?? .claude }
        }
        if !isDemo { defaults.set(activeProviders.map(\.rawValue), forKey: "enabledProviders") }
        if enabled && started && !isDemo {
            let previousTask = refreshTasks[provider]
            let previousToken = taskTokens[provider]
            Task { [weak self] in
                await previousTask?.value
                guard let self, self.enabledProviders.contains(provider), self.started else { return }
                if self.taskTokens[provider] == previousToken {
                    self.refreshTasks[provider] = nil
                    self.taskTokens[provider] = nil
                }
                await self.refresh(provider, force: true)
            }
        }
    }

    func retryMessage(for provider: ProviderID) -> String? {
        guard enabledProviders.contains(provider), let retry = retryStates[provider], retry.notBefore > clockNow else { return nil }
        let minutes = max(1, Int(ceil(retry.notBefore.timeIntervalSince(clockNow) / 60)))
        return retry.rateLimited ? String(localized: "약 \(minutes)분 후 다시 확인할 수 있어요") : String(localized: "자동 조회 잠시 대기 · 직접 다시 확인할 수 있어요")
    }

    func canRefresh(_ provider: ProviderID) -> Bool {
        guard enabledProviders.contains(provider), states[provider]?.isRefreshing != true else { return false }
        if let retry = retryStates[provider], retry.rateLimited, retry.notBefore > clockNow { return false }
        return true
    }

    var menuTitle: String { menuTitle(for: selectedProvider) }

    /// The menu bar shows only percentages. The mark appears only when there is no percentage to show,
    /// because an empty label would leave nothing to click.
    var menuShowsIcon: Bool {
        !showPercentage || menuProviders.allSatisfy { trackedWindow(for: $0) == nil }
    }

    func menuTitle(for provider: ProviderID) -> String {
        guard showPercentage else { return "" }
        guard let window = trackedWindow(for: provider) else { return states[provider]?.isRefreshing == true ? "…" : "—" }
        return UsageMenuBarFormatter.title(for: window, includeReset: showResetCountdown, now: clockNow) + (isStale(for: provider) ? " ·" : "")
    }

    func freshness(for provider: ProviderID) -> UsageFreshness {
        UsageFreshness.evaluate(snapshot: states[provider]?.snapshot,
                                hasError: states[provider]?.errorMessage != nil, now: clockNow)
    }

    func isStale(for provider: ProviderID) -> Bool {
        let value = freshness(for: provider)
        return value == .stale || value == .resetDue
    }

    func connectionStatus(for provider: ProviderID) -> String {
        guard enabledProviders.contains(provider) else { return String(localized: "조회 꺼짐") }
        let state = states[provider] ?? ProviderState()
        if state.isRefreshing { return String(localized: "확인 중") }
        if state.connectionIssue == .authentication { return String(localized: "로그인 확인 필요") }
        if state.requiresConnection { return String(localized: "다시 연결 필요") }
        if let retry = retryStates[provider], retry.rateLimited, retry.notBefore > clockNow { return String(localized: "요청 제한 · 대기 중") }
        if state.errorMessage != nil { return state.snapshot == nil ? String(localized: "조회 실패") : String(localized: "조회 실패 · 이전 기록") }
        switch freshness(for: provider) {
        case .unavailable: return String(localized: "연결 확인 필요")
        case .stale: return String(localized: "오래된 기록")
        case .resetDue: return String(localized: "리셋 확인 필요")
        case .current: return String(localized: "연결됨")
        }
    }

    var nextReset: Date? {
        trackedWindow(for: selectedProvider)?.resetsAt
    }

    func selectionNotice(for provider: ProviderID) -> String? {
        guard let savedID = trackedWindowIDs[provider],
              let displayed = trackedWindow(for: provider), displayed.id != savedID else { return nil }
        return String(localized: "고정한 한도 정보가 없어 \(displayed.label) 기준으로 임시 표시해요.")
    }

    func menuDescription(for provider: ProviderID) -> String {
        let window = trackedWindow(for: provider)
        var details = [provider.title, window?.label ?? String(localized: "사용량")]
        if let window {
            details.append(String(localized: "\(Int(window.remainingPercent.rounded()))퍼센트 남음"))
            if let reset = window.resetsAt {
                details.append(reset <= clockNow ? String(localized: "리셋 시각 경과, 확인 필요") : String(localized: "리셋 \(reset.formatted(date: .abbreviated, time: .shortened))"))
            }
        }
        details.append(connectionStatus(for: provider))
        return details.joined(separator: " · ")
    }

    /// The window the menu bar shows: the saved choice, otherwise the shortest window.
    func trackedWindow(for provider: ProviderID) -> UsageWindow? {
        UsageWindowSelection.select(from: states[provider]?.snapshot?.windows ?? [], preferredID: trackedWindowIDs[provider])
    }

    /// When the window runs out at the recent rate, from this period's polled history. Current readings only.
    func projection(for provider: ProviderID, window: UsageWindow) -> UsageProjection? {
        guard freshness(for: provider) == .current, let observedAt = states[provider]?.snapshot?.fetchedAt else { return nil }
        return UsageProjection.evaluate(window: window, history: history(for: provider), observedAt: observedAt, now: clockNow)
    }

    // MARK: Claude Code status line

    private var statusLineDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar", isDirectory: true)
    }
    private var statusLineFile: URL { statusLineDirectory.appendingPathComponent("statusline.txt") }
    var statusLineScript: URL { statusLineDirectory.appendingPathComponent("statusline.sh") }
    private var claudeSettingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    var statusLineCommand: String { ClaudeStatusLine.command(script: statusLineScript) }

    /// Recording state, each enabled service's leading limit, and the run-out time when one is near.
    func statusLineSegments() -> [ClaudeStatusLine.Segment] {
        var segments: [ClaudeStatusLine.Segment] = []
        if let active = workJournal.state.active {
            let elapsed = UsageFormat.compactDuration(clockNow.timeIntervalSince(active.startedAt))
            segments.append(.init(String(localized: "기록 중 \(elapsed)"), tone: .recording))
        }
        for provider in activeProviders {
            guard let window = primaryWindow(for: provider) else { continue }
            let current = freshness(for: provider) == .current
            let tone: ClaudeStatusLine.Segment.Tone = !current ? .dim : (window.remainingPercent <= 20 ? .warning : .normal)
            segments.append(.init("\(provider.title) \(Int(window.remainingPercent.rounded()))%", tone: tone))
            if let projection = projection(for: provider, window: window), case .runsOut(let at) = projection.outcome {
                segments.append(.init(String(localized: "\(UsageFormat.resetClock(at, now: clockNow)) 소진 예상"), tone: .warning))
            }
        }
        return segments
    }

    func refreshStatusLineState() {
        guard !isDemo else { return }
        statusLineState = ClaudeStatusLine.state(settings: claudeSettingsFile)
    }

    func installStatusLine() {
        statusLineMessage = nil
        if isDemo { statusLineState = .installed; return }
        do {
            try ClaudeStatusLine.install(settings: claudeSettingsFile, script: statusLineScript, lineFile: statusLineFile)
            statusLineEnabled = true
            exportStatusLine()
        } catch ClaudeStatusLine.Failure.otherStatusLine {
            statusLineMessage = String(localized: "이미 다른 상태줄이 설정돼 있어서 바꾸지 않았어요.")
        } catch ClaudeStatusLine.Failure.invalidSettings {
            statusLineMessage = String(localized: "~/.claude/settings.json을 읽을 수 없어 바꾸지 않았어요. 파일 형식을 확인해 주세요.")
        } catch {
            statusLineMessage = String(localized: "상태줄을 설정하지 못했어요.")
        }
        refreshStatusLineState()
    }

    func removeStatusLine() {
        statusLineMessage = nil
        if isDemo { statusLineState = .notConfigured; return }
        do { try ClaudeStatusLine.uninstall(settings: claudeSettingsFile) }
        catch { statusLineMessage = String(localized: "상태줄 설정을 지우지 못했어요.") }
        statusLineEnabled = false
        try? FileManager.default.removeItem(at: statusLineFile)
        refreshStatusLineState()
    }

    /// For people who already have a status line script: keep the line file current and hand them the command.
    func copyStatusLineCommand() {
        statusLineMessage = nil
        if !isDemo {
            do {
                try FileManager.default.createDirectory(at: statusLineDirectory, withIntermediateDirectories: true)
                try ClaudeStatusLine.script(lineFile: statusLineFile).write(to: statusLineScript, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusLineScript.path)
            } catch {
                statusLineMessage = String(localized: "상태줄 스크립트를 만들지 못했어요.")
                return
            }
            statusLineEnabled = true
            exportStatusLine()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statusLineCommand, forType: .string)
        statusLineMessage = String(localized: "명령을 복사했어요. 기존 상태줄 스크립트 끝에 붙여 넣으세요.")
    }

    /// Rewritten every minute so the script can tell a running UsageBar from a closed one by the file's age.
    private func exportStatusLine() {
        guard statusLineEnabled, !isDemo, historyStore != nil else { return }
        let line = ClaudeStatusLine.render(statusLineSegments())
        try? FileManager.default.createDirectory(at: statusLineDirectory, withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: statusLineFile, options: .atomic)
    }

    /// A menu bar percentage at or below the low-limit line, shown in the warning color.
    var menuIsLow: Bool {
        showPercentage && menuProviders.contains { trackedWindow(for: $0).map { $0.remainingPercent <= 20 } ?? false }
    }

    /// The window the panel leads with: always the shortest one (the 5-hour limit when present).
    func primaryWindow(for provider: ProviderID) -> UsageWindow? {
        UsageWindowSelection.select(from: states[provider]?.snapshot?.windows ?? [], preferredID: nil)
    }

    func selectWindow(_ id: String, for provider: ProviderID) {
        guard sortedWindows(for: provider).contains(where: { $0.id == id }) else { return }
        trackedWindowIDs[provider] = id
    }

    func sortedWindows(for provider: ProviderID) -> [UsageWindow] {
        (states[provider]?.snapshot?.windows ?? [])
            .filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
            .sorted {
                if $0.durationMinutes != $1.durationMinutes { return ($0.durationMinutes ?? -1) > ($1.durationMinutes ?? -1) }
                return $0.id < $1.id
            }
    }

    func history(for provider: ProviderID) -> [HistoryPoint] {
        historyPoints.filter { $0.provider == provider }
    }

    func start() {
        guard !started else { return }
        started = true
        sleeping = false
        startClock()
        guard !isDemo else { return }
        installWorkspaceObservers()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.workJournal.load()
            if let historyStore = self.historyStore {
                do {
                    let cached = try await historyStore.load()
                    guard !Task.isCancelled, self.started else { return }
                    self.historyPoints = cached.points
                    for (id, snapshot) in cached.snapshots where self.states[id]?.snapshot == nil {
                        self.states[id]?.snapshot = snapshot
                    }
                } catch {
                    self.storageNotice = String(localized: "저장된 기록을 읽지 못했어요. 새로 확인한 값부터 표시할게요.")
                }
            }
            guard !Task.isCancelled, self.started else { return }
            await self.refreshAll(force: true)
            if self.started && !self.sleeping { self.beginPolling() }
        }
    }

    func stop() {
        started = false
        startupTask?.cancel(); startupTask = nil
        pollTask?.cancel(); pollTask = nil
        clockTask?.cancel(); clockTask = nil
        cancelRefreshes()
        let center = NSWorkspace.shared.notificationCenter
        observations.forEach { center.removeObserver($0) }
        observations.removeAll()
    }

    func refresh(_ id: ProviderID, force: Bool = false) async {
        _ = await requestRefresh(id, force: force)
    }

    /// A work boundary must come from a successful live request, never a cached value.
    func workSnapshot(for id: ProviderID) async throws -> ProviderSnapshot {
        if isDemo, let snapshot = states[id]?.snapshot {
            #if DEBUG
            if CommandLine.arguments.contains("--ui-work-failure"), workJournal.state.active != nil {
                throw ProviderError.unavailable(String(localized: "예시 연결 오류: 종료 시 사용량을 확인하지 못했습니다. 기록은 유지되며 다시 시도하거나 한도 비교 없이 종료할 수 있어요."))
            }
            #endif
            return ProviderSnapshot(provider: snapshot.provider, accountKey: "demo-only", plan: snapshot.plan,
                windows: snapshot.windows, fetchedAt: Date(), source: String(localized: "예시 데이터"))
        }
        guard enabledProviders.contains(id), !sleeping else {
            throw ProviderError.unavailable(String(localized: "설정에서 \(id.title) 조회를 켜고 다시 시도해 주세요."))
        }
        let expectedGeneration = generation
        let previousSuccess = successfulRefreshTokens[id]
        if let task = refreshTasks[id], let token = taskTokens[id] {
            await task.value
            guard successfulRefreshTokens[id] == token else { throw workSnapshotError(for: id) }
        } else {
            let requested = await requestRefresh(id, force: true)
            guard requested, successfulRefreshTokens[id] != previousSuccess else { throw workSnapshotError(for: id) }
        }
        try Task.checkCancellation()
        guard generation == expectedGeneration, enabledProviders.contains(id), !sleeping,
              states[id]?.errorMessage == nil, let snapshot = states[id]?.snapshot,
              (0...60).contains(Date().timeIntervalSince(snapshot.fetchedAt)) else {
            throw workSnapshotError(for: id)
        }
        return snapshot
    }

    private func workSnapshotError(for id: ProviderID) -> ProviderError {
        .unavailable(retryMessage(for: id) ?? states[id]?.errorMessage ?? String(localized: "새 사용량을 확인하지 못했어요. 다시 시도해 주세요."))
    }

    private func requestRefresh(_ id: ProviderID, force: Bool = false) async -> Bool {
        guard !isDemo, !sleeping, enabledProviders.contains(id), refreshTasks[id] == nil, let provider = providers[id] else { return false }
        let now = Date()
        if let retry = retryStates[id], retry.notBefore > now, retry.rateLimited || !force { return false }
        if !force, let fetchedAt = states[id]?.snapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < 60 { return false }

        let token = UUID()
        let currentGeneration = generation
        taskTokens[id] = token
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(id, provider: provider, generation: currentGeneration, token: token)
        }
        refreshTasks[id] = task
        await task.value
        if taskTokens[id] == token {
            refreshTasks[id] = nil
            taskTokens[id] = nil
        }
        return true
    }

    func refreshAll() async { await refreshAll(force: false) }

    private func refreshAll(force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for id in activeProviders {
                group.addTask { [weak self] in await self?.refresh(id, force: force) }
            }
        }
    }

    private func performRefresh(_ id: ProviderID, provider: any UsageProvider, generation expected: Int, token: UUID) async {
        guard !Task.isCancelled, enabledProviders.contains(id), generation == expected else { return }
        defer { exportStatusLine() }
        states[id]?.isRefreshing = true
        states[id]?.lastAttempt = Date()
        defer { if generation == expected { states[id]?.isRefreshing = false } }
        do {
            let snapshot = try await provider.fetch()
            guard !Task.isCancelled, generation == expected else { return }
            guard snapshot.provider == id else { throw ProviderError.unavailable(String(localized: "제공자 정보를 확인하지 못했어요.")) }
            let previousKey = states[id]?.snapshot?.accountKey
            if previousKey != snapshot.accountKey {
                resetNotificationTracking(for: id)
                resetRefreshes[id] = [:]
                historyPoints.removeAll { $0.provider == id }
            }
            states[id]?.snapshot = snapshot
            successfulRefreshTokens[id] = token
            clockNow = Date()
            states[id]?.errorMessage = nil
            states[id]?.connectionIssue = nil
            retryStates[id] = nil
            if let historyStore {
                do {
                    let history = try await historyStore.record(snapshot)
                    guard !Task.isCancelled, generation == expected else { return }
                    historyPoints = history.points
                    if history.accountChanged { resetNotificationTracking(for: id) }
                    storageNotice = nil
                } catch {
                    storageNotice = String(localized: "현재 사용량은 확인했지만 기록을 저장하지 못했어요.")
                }
            }
            guard !Task.isCancelled, generation == expected else { return }
            await updateNotifications(snapshot)
            if workJournal.state.active?.provider == snapshot.provider { await syncWorkReminders() }
        } catch is CancellationError {
            // Cancellation is not a failed account connection and must not replace a cached value.
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            let attempt = (retryStates[id]?.attempts ?? 0) + 1
            var connectionIssue: ProviderState.ConnectionIssue?
            var limited = false
            var delay = min(300, 30 * pow(2, Double(min(attempt - 1, 4))))
            if let providerError = error as? ProviderError {
                switch providerError {
                case .setupRequired: connectionIssue = .setup
                case .authenticationRequired: connectionIssue = .authentication
                case .unsupported: connectionIssue = .unsupported
                case .rateLimited(let retryAfter):
                    limited = true
                    delay = max(1, retryAfter ?? min(3_600, 300 * pow(2, Double(min(attempt - 1, 4)))))
                default: break
                }
            }
            clockNow = Date()
            retryStates[id] = RetryState(attempts: attempt, notBefore: clockNow.addingTimeInterval(delay), rateLimited: limited)
            states[id]?.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "지금 사용량을 가져올 수 없어요.")
            states[id]?.connectionIssue = connectionIssue
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        await setNotificationSetting(\.notificationsEnabled, key: "notificationsEnabled", enabled: enabled)
    }

    func setRecoveryNotificationsEnabled(_ enabled: Bool) async {
        await setNotificationSetting(\.recoveryNotificationsEnabled, key: "recoveryNotificationsEnabled", enabled: enabled)
    }

    func setRunOutNotificationsEnabled(_ enabled: Bool) async {
        await setNotificationSetting(\.runOutNotificationsEnabled, key: "runOutNotificationsEnabled", enabled: enabled)
    }

    /// Turning any notification on asks for permission; the stored value reflects what macOS granted.
    private func setNotificationSetting(_ path: ReferenceWritableKeyPath<AppStore, Bool>, key: String, enabled: Bool) async {
        let settingToken = UUID()
        notificationSettingToken = settingToken
        notificationMessage = nil
        if isDemo { self[keyPath: path] = enabled; return }
        if !enabled {
            self[keyPath: path] = false
            defaults.set(false, forKey: key)
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard notificationSettingToken == settingToken else { return }
            self[keyPath: path] = granted
            defaults.set(granted, forKey: key)
            if !granted { notificationMessage = String(localized: "알림 권한이 꺼져 있어요. 시스템 설정에서 변경할 수 있어요.") }
        } catch {
            guard notificationSettingToken == settingToken else { return }
            self[keyPath: path] = false
            defaults.set(false, forKey: key)
            notificationMessage = String(localized: "알림 권한을 확인하지 못했어요.")
        }
    }

    func clearHistory() async {
        if isDemo { historyPoints = []; return }
        do {
            try await historyStore?.clear()
            historyPoints = []
            storageNotice = nil
        } catch { storageNotice = String(localized: "기록을 지우지 못했어요.") }
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self, self.started, !self.sleeping else { return }
                await self.refreshAll()
            }
        }
    }

    private func startClock() {
        clockTask?.cancel()
        clockNow = Date()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.started else { return }
                self.clockNow = Date()
                self.exportStatusLine()
                guard !self.isDemo, !self.sleeping else { continue }
                for provider in self.activeProviders {
                    let pending = (self.states[provider]?.snapshot?.windows ?? []).compactMap { window -> (String, Date)? in
                        guard let reset = window.resetsAt, reset <= self.clockNow else { return nil }
                        if let attempted = self.resetRefreshes[provider]?[window.id],
                           abs(attempted.timeIntervalSince(reset)) < 90 { return nil }
                        return (window.id, reset)
                    }
                    guard !pending.isEmpty else { continue }
                    // Normal refresh retains the existing minimum interval and backoff safeguards.
                    if await self.requestRefresh(provider) {
                        for (windowID, reset) in pending { self.resetRefreshes[provider, default: [:]][windowID] = reset }
                    }
                }
            }
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sleeping = true
                self.pollTask?.cancel(); self.pollTask = nil
                self.cancelRefreshes()
            }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.sleeping = false
                self.clockNow = Date()
                await self.refreshAll(force: true)
                if self.started { self.beginPolling() }
            }
        })
    }

    private func cancelRefreshes() {
        generation += 1
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll(); taskTokens.removeAll()
        for id in ProviderID.allCases { states[id]?.isRefreshing = false }
    }

    private func resetNotificationTracking(for provider: ProviderID) {
        notificationTracking = notificationTracking.filter { !$0.key.hasPrefix(provider.rawValue + "|") }
    }

    private func updateNotifications(_ snapshot: ProviderSnapshot) async {
        for window in snapshot.windows where window.usedPercent.isFinite && (0...100).contains(window.usedPercent) {
            let key = snapshot.provider.rawValue + "|" + window.id
            let remaining = window.remainingPercent
            guard let decision = QuotaAlertPolicy.evaluate(previous: notificationTracking[key], remaining: remaining,
                resetsAt: window.resetsAt, observedAt: snapshot.fetchedAt) else { continue }
            var nextState = decision.state
            let period = nextState.periodResetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            if decision.shouldNotify && notificationsEnabled && !isDemo {
                let delivered = await deliverNotification(id: "usage.\(key).\(period)",
                    title: String(localized: "\(snapshot.provider.title) 한도가 얼마 남지 않았어요"),
                    body: String(localized: "\(window.label) · \(Int(remaining.rounded()))% 남음"))
                if delivered { nextState.hasNotified = true }
            }
            if runOutNotificationsEnabled && !isDemo, !runOutNotified.contains("\(key).\(period)"), let resetsAt = window.resetsAt,
               let projection = UsageProjection.evaluate(window: window, history: history(for: snapshot.provider),
                                                         observedAt: snapshot.fetchedAt, now: Date()),
               projection.shouldWarn(resetsAt: resetsAt, now: Date()), case .runsOut(let at) = projection.outcome {
                let delivered = await deliverNotification(id: "runout.\(key).\(period)",
                    title: String(localized: "\(snapshot.provider.title) 한도가 곧 소진될 것 같아요"),
                    body: String(localized: "\(window.label) · 이 속도면 \(UsageFormat.resetClock(at, now: Date()))에 소진돼요"))
                if delivered { runOutNotified.insert("\(key).\(period)") }
            }
            if decision.shouldNotifyRecovery && recoveryNotificationsEnabled && !isDemo {
                _ = await deliverNotification(id: "recovery.\(key).\(period)",
                    title: String(localized: "\(snapshot.provider.title) 한도가 리셋됐어요"),
                    body: String(localized: "\(window.label) · \(Int(remaining.rounded()))% 남음"))
            }
            notificationTracking[key] = nextState
        }
    }

    private func deliverNotification(id: String, title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            notificationMessage = String(localized: "사용량 알림을 보내지 못했어요.")
            return false
        }
    }

    private func installDemo() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for id in ProviderID.allCases {
            let snapshot = ProviderSnapshot(provider: id, plan: id == .claude ? String(localized: "Max · 예시") : String(localized: "Pro · 예시"),
                windows: [
                    UsageWindow(id: "weekly", label: String(localized: "주간 한도"), usedPercent: 24,
                                resetsAt: now.addingTimeInterval(5 * 86_400), durationMinutes: 10_080),
                    UsageWindow(id: "session", label: String(localized: "5시간 한도"), usedPercent: 32,
                                resetsAt: now.addingTimeInterval(3 * 3_600), durationMinutes: 300)
                ], resetCreditCount: id == .codex ? 3 : nil,
                resetCredits: id == .codex ? (1...3).map {
                    ResetCredit(id: "demo-\($0)", title: String(localized: "예시 초기화권 \($0)"),
                                expiresAt: now.addingTimeInterval(Double($0 * 7) * 86_400), status: "available")
                } : nil,
                dailyUsage: id == .codex ? (0..<7).map {
                    DailyUsage(day: formatter.string(from: now.addingTimeInterval(-Double(6 - $0) * 86_400)),
                               tokens: Int64([2_100_000, 3_600_000, 1_200_000, 5_300_000, 6_000_000, 4_800_000, 8_400_000][$0]))
                } : nil, fetchedAt: now, source: String(localized: "예시 데이터 · 외부 연결 없음"))
            states[id] = ProviderState(snapshot: snapshot)
            let session = snapshot.windows.first { $0.id == "session" }
            for minutes in stride(from: 60, through: 5, by: -5) {
                // 12 points over the last hour: 68% left lasts past the 3-hour reset.
                historyPoints.append(HistoryPoint(provider: id, date: now.addingTimeInterval(-Double(minutes) * 60),
                                                  remaining: 68 + Double(minutes) / 5, windowName: String(localized: "5시간 한도"),
                                                  windowID: "session", resetsAt: session?.resetsAt))
            }
            for index in 0..<16 {
                historyPoints.append(HistoryPoint(provider: id, date: now.addingTimeInterval(-Double(15 - index) * 3_600),
                                                  remaining: 96 - Double(index) * (20.0 / 15),
                                                  windowName: String(localized: "주간 한도 · 예시"), windowID: "weekly",
                                                  resetsAt: snapshot.windows.first?.resetsAt))
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--ui-history-gaps"), let old = states[.codex]?.snapshot {
            let records = (old.dailyUsage ?? []).enumerated().compactMap { index, record -> DailyUsage? in
                if index == 2 { return nil }
                return DailyUsage(day: record.day, tokens: index == 4 ? 0 : record.tokens)
            }
            states[.codex] = ProviderState(snapshot: ProviderSnapshot(provider: .codex, plan: old.plan,
                windows: old.windows, resetCreditCount: old.resetCreditCount, resetCredits: old.resetCredits,
                dailyUsage: records, fetchedAt: old.fetchedAt, source: String(localized: "화면 검증용 예시")))
            selectedProvider = .codex
        }
        if CommandLine.arguments.contains("--ui-codex") { selectedProvider = .codex }
        if CommandLine.arguments.contains("--ui-runout"), let old = states[.claude]?.snapshot {
            // 12% left after 18 points in the last hour: runs out in about 40 minutes, before the reset.
            let windows = old.windows.map { window in
                window.id == "session" ? UsageWindow(id: window.id, label: window.label, usedPercent: 88,
                    resetsAt: window.resetsAt, durationMinutes: window.durationMinutes) : window
            }
            states[.claude]?.snapshot = ProviderSnapshot(provider: .claude, plan: old.plan, windows: windows,
                fetchedAt: old.fetchedAt, source: old.source)
            historyPoints.removeAll { $0.provider == .claude && $0.windowID == "session" }
            for minutes in stride(from: 60, through: 5, by: -5) {
                historyPoints.append(HistoryPoint(provider: .claude, date: now.addingTimeInterval(-Double(minutes) * 60),
                    remaining: 12 + Double(minutes) * 0.3, windowName: String(localized: "5시간 한도"),
                    windowID: "session", resetsAt: windows.first { $0.id == "session" }?.resetsAt))
            }
        }
        if CommandLine.arguments.contains("--ui-menu-all") { menuBarDisplayMode = .all }
        if CommandLine.arguments.contains("--ui-rate-limited") {
            for id in ProviderID.allCases {
                states[id] = ProviderState(errorMessage: ProviderError.rateLimited(retryAfter: 300).localizedDescription)
                retryStates[id] = RetryState(attempts: 1, notBefore: now.addingTimeInterval(300), rateLimited: true)
            }
            historyPoints = []
        }
        if CommandLine.arguments.contains("--ui-connection-required") {
            for id in ProviderID.allCases {
                states[id] = ProviderState(errorMessage: String(localized: "처음 한 번 터미널에서 연결을 확인해 주세요."), connectionIssue: .setup)
            }
            historyPoints = []
        }
        if CommandLine.arguments.contains("--ui-auth-required") {
            // Expired login with cached usage for Claude, first fetch for Codex.
            states[.claude]?.errorMessage = String(localized: "Claude Code에 로그인이 필요해요. 연결 설정을 열어 로그인한 뒤 다시 확인해 주세요.")
            states[.claude]?.connectionIssue = .authentication
            states[.codex] = ProviderState(errorMessage: String(localized: "Codex에 ChatGPT 계정으로 로그인해 주세요."), connectionIssue: .authentication)
        }
        if CommandLine.arguments.contains("--ui-codex-setup-error") {
            selectedProvider = .codex
            states[.codex] = ProviderState(snapshot: ProviderSnapshot(provider: .codex, plan: "pro",
                windows: [UsageWindow(id: "codex.secondary", label: String(localized: "주간 한도"),
                    usedPercent: 0, resetsAt: now.addingTimeInterval(6 * 86_400), durationMinutes: 10_080)],
                fetchedAt: now.addingTimeInterval(-23 * 3_600), source: String(localized: "화면 검증용 예시")),
                errorMessage: String(localized: "Codex CLI 버전을 확인하지 못했어요. 실행 파일 경로와 설치 상태를 확인해 주세요."),
                connectionIssue: .setup)
        }
        if CommandLine.arguments.contains("--ui-stale") || CommandLine.arguments.contains("--ui-reset-due") {
            let stale = CommandLine.arguments.contains("--ui-stale")
            for id in ProviderID.allCases {
                guard let old = states[id]?.snapshot else { continue }
                let windows = old.windows.map { window in
                    UsageWindow(id: window.id, label: window.label, usedPercent: stale ? 94 : window.usedPercent,
                        resetsAt: stale ? window.resetsAt : now.addingTimeInterval(-60),
                        durationMinutes: window.durationMinutes)
                }
                states[id] = ProviderState(snapshot: ProviderSnapshot(provider: id, plan: old.plan,
                    windows: windows, resetCreditCount: old.resetCreditCount, resetCredits: old.resetCredits,
                    dailyUsage: old.dailyUsage, fetchedAt: stale ? now.addingTimeInterval(-900) : now,
                    source: String(localized: "화면 검증용 예시")))
            }
        }
        #endif
    }
}
