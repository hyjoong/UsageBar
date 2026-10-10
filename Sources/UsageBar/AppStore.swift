import AppKit
import Combine
import Foundation
import UsageBarCore
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case selected, all
    var id: String { rawValue }
    var title: String { self == .selected ? "선택한 서비스" : "사용 중인 서비스 모두" }
}

enum UsageAppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: "어둡게"
        case .light: "밝게"
        case .system: "시스템 설정 따르기"
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
    var snapshot: ProviderSnapshot?
    var isRefreshing = false
    var errorMessage: String?
    var requiresConnection = false
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
    @Published private(set) var historyPoints: [HistoryPoint] = []
    @Published private(set) var storageNotice: String?
    @Published private(set) var notificationMessage: String?

    let isDemo: Bool
    private let defaults: UserDefaults
    private let providers: [ProviderID: any UsageProvider]
    private let historyStore: HistoryStore?
    private var refreshTasks: [ProviderID: Task<Void, Never>] = [:]
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
        defaults = preferences
        providers = providerOverrides ?? (demo ? [:] : [.claude: ClaudeProvider(), .codex: CodexProvider()])
        historyStore = demo || providerOverrides != nil ? nil : HistoryStore()
        states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderState()) })
        if demo {
            installDemo()
        } else {
            appearanceMode = UsageAppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .dark
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
            if let saved = defaults.dictionary(forKey: "trackedWindowIDs") as? [String: String] {
                trackedWindowIDs = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                    ProviderID(rawValue: key).map { ($0, value) }
                })
            }
        }
    }

    func applyAppearance() {
        NSApplication.shared.appearance = appearanceMode.appearance
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
        return retry.rateLimited ? "약 \(minutes)분 후 다시 확인할 수 있어요" : "자동 조회 잠시 대기 · 직접 다시 확인할 수 있어요"
    }

    func canRefresh(_ provider: ProviderID) -> Bool {
        guard enabledProviders.contains(provider), states[provider]?.isRefreshing != true else { return false }
        if let retry = retryStates[provider], retry.rateLimited, retry.notBefore > clockNow { return false }
        return true
    }

    var menuTitle: String { menuTitle(for: selectedProvider) }

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
        guard enabledProviders.contains(provider) else { return "조회 꺼짐" }
        let state = states[provider] ?? ProviderState()
        if state.isRefreshing { return "확인 중" }
        if state.requiresConnection { return "다시 연결 필요" }
        if let retry = retryStates[provider], retry.rateLimited, retry.notBefore > clockNow { return "요청 제한 · 대기 중" }
        if state.errorMessage != nil { return state.snapshot == nil ? "조회 실패" : "조회 실패 · 이전 기록" }
        switch freshness(for: provider) {
        case .unavailable: return "연결 확인 필요"
        case .stale: return "오래된 기록"
        case .resetDue: return "리셋 확인 필요"
        case .current: return "연결됨"
        }
    }

    var nextReset: Date? {
        trackedWindow(for: selectedProvider)?.resetsAt
    }

    func selectionNotice(for provider: ProviderID) -> String? {
        guard let savedID = trackedWindowIDs[provider],
              let displayed = trackedWindow(for: provider), displayed.id != savedID else { return nil }
        return "고정한 한도가 제공되지 않아 \(displayed.label)을 임시로 표시해요."
    }

    func menuDescription(for provider: ProviderID) -> String {
        let window = trackedWindow(for: provider)
        var details = [provider.title, window?.label ?? "사용량"]
        if let window {
            details.append("\(Int(window.remainingPercent.rounded()))퍼센트 남음")
            if let reset = window.resetsAt {
                details.append(reset <= clockNow ? "리셋 시각 경과, 확인 필요" : "리셋 \(reset.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        details.append(connectionStatus(for: provider))
        return details.joined(separator: " · ")
    }

    func trackedWindow(for provider: ProviderID) -> UsageWindow? {
        UsageWindowSelection.select(from: states[provider]?.snapshot?.windows ?? [], preferredID: trackedWindowIDs[provider])
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
            if let historyStore = self.historyStore {
                do {
                    let cached = try await historyStore.load()
                    guard !Task.isCancelled, self.started else { return }
                    self.historyPoints = cached.points
                    for (id, snapshot) in cached.snapshots where self.states[id]?.snapshot == nil {
                        self.states[id]?.snapshot = snapshot
                    }
                } catch {
                    self.storageNotice = "저장된 기록을 읽지 못했어요. 새로 확인한 값부터 표시할게요."
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
            await self.performRefresh(id, provider: provider, generation: currentGeneration)
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

    private func performRefresh(_ id: ProviderID, provider: any UsageProvider, generation expected: Int) async {
        guard !Task.isCancelled, enabledProviders.contains(id), generation == expected else { return }
        states[id]?.isRefreshing = true
        states[id]?.lastAttempt = Date()
        defer { if generation == expected { states[id]?.isRefreshing = false } }
        do {
            let snapshot = try await provider.fetch()
            guard !Task.isCancelled, generation == expected else { return }
            guard snapshot.provider == id else { throw ProviderError.unavailable("제공자 정보를 확인하지 못했어요.") }
            let previousKey = states[id]?.snapshot?.accountKey
            if previousKey != snapshot.accountKey {
                resetNotificationTracking(for: id)
                resetRefreshes[id] = [:]
                historyPoints.removeAll { $0.provider == id }
            }
            states[id]?.snapshot = snapshot
            clockNow = Date()
            states[id]?.errorMessage = nil
            states[id]?.requiresConnection = false
            retryStates[id] = nil
            if let historyStore {
                do {
                    let history = try await historyStore.record(snapshot)
                    guard !Task.isCancelled, generation == expected else { return }
                    historyPoints = history.points
                    if history.accountChanged { resetNotificationTracking(for: id) }
                    storageNotice = nil
                } catch {
                    storageNotice = "현재 사용량은 확인했지만 기록을 저장하지 못했어요."
                }
            }
            guard !Task.isCancelled, generation == expected else { return }
            await updateNotifications(snapshot)
        } catch is CancellationError {
            // Cancellation is not a failed account connection and must not replace a cached value.
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            let attempt = (retryStates[id]?.attempts ?? 0) + 1
            var connection = false
            var limited = false
            var delay = min(300, 30 * pow(2, Double(min(attempt - 1, 4))))
            if let providerError = error as? ProviderError {
                switch providerError {
                case .setupRequired, .authenticationRequired: connection = true
                case .rateLimited(let retryAfter):
                    limited = true
                    delay = max(1, retryAfter ?? min(3_600, 300 * pow(2, Double(min(attempt - 1, 4)))))
                default: break
                }
            }
            clockNow = Date()
            retryStates[id] = RetryState(attempts: attempt, notBefore: clockNow.addingTimeInterval(delay), rateLimited: limited)
            states[id]?.errorMessage = (error as? LocalizedError)?.errorDescription ?? "지금 사용량을 가져올 수 없어요."
            states[id]?.requiresConnection = connection
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        let settingToken = UUID()
        notificationSettingToken = settingToken
        notificationMessage = nil
        if isDemo { notificationsEnabled = enabled; return }
        if !enabled {
            notificationsEnabled = false
            defaults.set(false, forKey: "notificationsEnabled")
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard notificationSettingToken == settingToken else { return }
            notificationsEnabled = granted
            defaults.set(granted, forKey: "notificationsEnabled")
            if !granted { notificationMessage = "알림 권한이 꺼져 있어요. 시스템 설정에서 변경할 수 있어요." }
        } catch {
            guard notificationSettingToken == settingToken else { return }
            notificationsEnabled = false
            defaults.set(false, forKey: "notificationsEnabled")
            notificationMessage = "알림 권한을 확인하지 못했어요."
        }
    }

    func clearHistory() async {
        if isDemo { historyPoints = []; return }
        do {
            try await historyStore?.clear()
            historyPoints = []
            storageNotice = nil
        } catch { storageNotice = "기록을 지우지 못했어요." }
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
            if decision.shouldNotify && notificationsEnabled && !isDemo {
                let content = UNMutableNotificationContent()
                content.title = "\(snapshot.provider.title) 한도가 얼마 남지 않았어요"
                content.body = "\(window.label) · \(Int(remaining.rounded()))% 남음"
                content.sound = .default
                let period = nextState.periodResetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
                let request = UNNotificationRequest(identifier: "usage.\(key).\(period)", content: content, trigger: nil)
                do { try await UNUserNotificationCenter.current().add(request); nextState.hasNotified = true }
                catch { notificationMessage = "사용량 알림을 보내지 못했어요." }
            }
            notificationTracking[key] = nextState
        }
    }

    private func installDemo() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        for id in ProviderID.allCases {
            let snapshot = ProviderSnapshot(provider: id, plan: id == .claude ? "Max · 예시" : "Pro · 예시",
                windows: [
                    UsageWindow(id: "weekly", label: "주간 한도", usedPercent: 24,
                                resetsAt: now.addingTimeInterval(5 * 86_400), durationMinutes: 10_080),
                    UsageWindow(id: "session", label: "5시간 한도", usedPercent: 32,
                                resetsAt: now.addingTimeInterval(3 * 3_600), durationMinutes: 300)
                ], resetCreditCount: id == .codex ? 3 : nil,
                resetCredits: id == .codex ? (1...3).map {
                    ResetCredit(id: "demo-\($0)", title: "예시 초기화권 \($0)",
                                expiresAt: now.addingTimeInterval(Double($0 * 7) * 86_400), status: "available")
                } : nil,
                dailyUsage: id == .codex ? (0..<7).map {
                    DailyUsage(day: formatter.string(from: now.addingTimeInterval(-Double(6 - $0) * 86_400)),
                               tokens: Int64([2_100_000, 3_600_000, 1_200_000, 5_300_000, 6_000_000, 4_800_000, 8_400_000][$0]))
                } : nil, fetchedAt: now, source: "예시 데이터 · 외부 연결 없음")
            states[id] = ProviderState(snapshot: snapshot)
            for index in 0..<16 {
                historyPoints.append(HistoryPoint(provider: id, date: now.addingTimeInterval(-Double(15 - index) * 3_600),
                                                  remaining: 96 - Double(index) * (20.0 / 15),
                                                  windowName: "주간 한도 · 예시", windowID: "weekly",
                                                  resetsAt: snapshot.windows.first?.resetsAt))
            }
        }
    }
}
