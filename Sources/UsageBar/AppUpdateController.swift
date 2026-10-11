import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var message: String
    let configuration: UpdateConfiguration
    let version: String
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private var pendingInstall: AnyCancellable?
    private let journal: WorkJournalController

    init(demo: Bool, journal: WorkJournalController, bundle: Bundle = .main) {
        self.journal = journal
        let info = bundle.infoDictionary ?? [:]
        configuration = UpdateConfiguration(info: info, bundleIdentifier: bundle.bundleIdentifier,
                                            isDemo: demo, allowsLocalFixture: true)
        message = configuration.statusMessage
        version = UpdateConfiguration.displayVersion(info: info)
        super.init()
    }

    func start() {
        guard configuration.isReady, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &observations)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheckedAt = $0 }.store(in: &observations)
        do { try updater.start() }
        catch {
            message = String(localized: "업데이트 확인을 시작하지 못했어요. 앱을 다시 실행해 주세요.")
            observations.removeAll()
            self.controller = nil
            canCheckForUpdates = false
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // Scheduled updates are announced in the panel; user-requested checks still show Sparkle's UI.
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Sparkle's AppKit user driver invokes these callbacks on the main thread.
        MainActor.assumeIsolated { availableVersion = handleShowingUpdate ? nil : update.displayVersionString }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { availableVersion = nil }
    }
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunchIfNeeded(installHandler)
    }

    func postponeRelaunchIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard journal.isBusy else { return false }
        // Active intervals are persisted already. Only an in-flight journal write needs a short delay.
        pendingInstall = journal.$isBusy.receive(on: RunLoop.main).sink { [weak self] busy in
            guard let self, !busy, !self.journal.isBusy else { return }
            self.pendingInstall?.cancel()
            self.pendingInstall = nil
            installHandler()
        }
        return true
    }
}
