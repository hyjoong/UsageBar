import AppKit
import SwiftUI
import UsageBarCore

struct PreferencesView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var updates: AppUpdateController
    @StateObject private var launchAtLogin: LaunchAtLoginStore

    init(store: AppStore, updates: AppUpdateController) {
        self.store = store
        self.updates = updates
        _launchAtLogin = StateObject(wrappedValue: LaunchAtLoginStore(demo: store.isDemo))
    }

    var body: some View {
        ScrollViewReader { proxy in form.onAppear { scrollForCheck(proxy) } }
    }

    /// Demo screen checks: `--ui-settings-statusline` opens settings scrolled to the status line section.
    private func scrollForCheck(_ proxy: ScrollViewProxy) {
        #if DEBUG
        guard store.isDemo, CommandLine.arguments.contains("--ui-settings-statusline") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("statusline", anchor: .top) }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Picker("화면 모드", selection: $store.appearanceMode) {
                    ForEach(UsageAppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("언어", selection: $store.language) {
                    ForEach(UsageLanguage.allCases) { Text($0.title).tag($0) }
                }
                if store.needsRelaunchForLanguage {
                    HStack {
                        detail("언어는 다시 실행한 뒤 적용돼요.", color: UsageTheme.warning)
                        Spacer()
                        Button("지금 다시 실행") { store.relaunch() }
                    }
                }
                Toggle("로그인 시 UsageBar 실행", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                note(launchAtLogin.statusMessage,
                     color: launchAtLogin.requiresApproval ? UsageTheme.warning : UsageTheme.secondaryInk)
                if let message = launchAtLogin.errorMessage {
                    note(message, color: UsageTheme.warning)
                }
                if launchAtLogin.requiresApproval {
                    Button("로그인 항목 설정 열기") { launchAtLogin.openSystemSettings() }
                }
            } header: {
                sectionTitle("일반", symbol: "gearshape")
            }

            Section {
                Picker("표시할 서비스", selection: $store.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("잔여율 표시", isOn: $store.showPercentage)
                Toggle("리셋까지 남은 시간도 표시", isOn: $store.showResetCountdown)
                    .disabled(!store.showPercentage)
                if store.showPercentage && store.showResetCountdown {
                    detail("표시 예: 62% · 2h 10m")
                }
                ForEach(store.menuProviders) { provider in
                    windowPicker(for: provider)
                }
            } header: {
                sectionTitle("메뉴 막대", symbol: "menubar.rectangle")
            }

            Section {
                Toggle("남은 한도가 20% 아래로 내려가면 알림", isOn: Binding(
                    get: { store.notificationsEnabled },
                    set: { value in Task { await store.setNotificationsEnabled(value) } }
                ))
                Toggle("20% 아래였던 한도가 리셋되면 알림", isOn: Binding(
                    get: { store.recoveryNotificationsEnabled },
                    set: { value in Task { await store.setRecoveryNotificationsEnabled(value) } }
                ))
                Toggle("리셋 전에 소진될 것 같으면 알림", isOn: Binding(
                    get: { store.runOutNotificationsEnabled },
                    set: { value in Task { await store.setRunOutNotificationsEnabled(value) } }
                ))
                detail("각 한도마다 기간당 한 번씩만 알려요. 켤 때 macOS 알림 권한을 요청해요.")
                if let message = store.notificationMessage {
                    note(message, color: UsageTheme.warning)
                }
            } header: {
                sectionTitle("알림", symbol: "bell")
            }

            Section {
                Toggle("작업 기록 중 알림", isOn: $store.workRemindersEnabled)
                detail("시작 2시간 뒤와 리셋 10분 전에 알려요. 알림에서 바로 종료할 수 있어요.")
                Toggle("영수증에 모델·토큰 상세 포함", isOn: $store.sessionDetailsEnabled)
                detail("이 Mac의 Claude Code·Codex 세션 기록(~/.claude, ~/.codex)에서 작업 구간의 모델, 호출 수, 토큰 수, 프로젝트 폴더 이름만 집계해요. 대화 내용은 읽어 저장하지 않아요.")
            } header: {
                sectionTitle("작업 기록", symbol: "receipt")
            }

            Section {
                statusLineRows
            } header: {
                sectionTitle("Claude Code 상태줄", symbol: "terminal")
            }
            .id("statusline")

            Section {
                ForEach(ProviderID.allCases) { provider in
                    Toggle("\(provider.title) 사용량 조회", isOn: Binding(
                        get: { store.enabledProviders.contains(provider) },
                        set: { store.setProviderEnabled($0, for: provider) }
                    ))
                    .disabled(store.enabledProviders.contains(provider) && store.enabledProviders.count == 1)
                    connectionRow(for: provider)
                }
                detail("켜 둔 서비스만 5분마다 조회해요. 각 CLI의 로그인 상태를 사용하며, 끈 서비스의 기록은 보관돼요.")
            } header: {
                sectionTitle("연결", symbol: "link")
            }

            Section {
                LabeledContent("버전", value: updates.version)
                if let version = updates.availableVersion {
                    note(String(localized: "\(version) 버전으로 업데이트할 수 있어요."), color: UsageTheme.accent)
                }
                Button("업데이트 확인…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                if updates.configuration.isReady {
                    Toggle("새 버전 자동 확인", isOn: Binding(
                        get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) }
                    ))
                    if let checked = updates.lastCheckedAt {
                        note(String(localized: "마지막 확인: \(checked.formatted(date: .abbreviated, time: .shortened))"))
                    }
                }
                note(updates.message)
                detail("사용량 기록은 이 Mac에만 저장되고, 대화 내용은 수집하지 않아요.")
            } header: {
                sectionTitle("앱 정보", symbol: "info.circle")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(UsageType.body)
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        .background(UsageTheme.canvas)
        .frame(width: 500)
        .frame(minHeight: 480, idealHeight: 620, maxHeight: 800)
        .onAppear { launchAtLogin.refreshStatus(); store.refreshStatusLineState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
    }

    @ViewBuilder private var statusLineRows: some View {
        let preview = ClaudeStatusLine.render(store.statusLineSegments(), ansi: false)
        detail("Claude Code 화면 아래에 작업 기록 중 표시, 서비스별 5시간 잔여율, 소진 예상을 보여 줘요. UsageBar가 꺼져 있으면 10분 뒤 사라져요.")
        if !preview.isEmpty {
            Text(verbatim: preview).font(UsageType.secondary).monospacedDigit().foregroundStyle(UsageTheme.secondaryInk)
                .textSelection(.enabled)
        }
        switch store.statusLineState {
        case .notConfigured:
            HStack {
                Button("상태줄에 표시") { store.installStatusLine() }
                Spacer()
            }
            detail("~/.claude/settings.json을 백업(settings.json.usagebar-backup)한 뒤 statusLine 항목만 추가해요.")
        case .installed:
            HStack {
                Label("설정됨", systemImage: "checkmark.circle").foregroundStyle(UsageTheme.secondaryInk)
                Spacer()
                Button("상태줄에서 빼기") { store.removeStatusLine() }
            }
            detail("새로 여는 Claude Code 화면부터 보여요.")
        case .otherStatusLine:
            detail("이미 다른 상태줄을 쓰고 있어서 설정을 바꾸지 않아요. 그 스크립트 끝에 아래 명령을 추가하면 함께 보여요.")
            Text(verbatim: store.statusLineCommand).font(UsageType.captionMono).textSelection(.enabled)
            HStack {
                Button("명령 복사") { store.copyStatusLineCommand() }
                Spacer()
            }
        }
        if let message = store.statusLineMessage {
            note(message, color: UsageTheme.warning)
        }
    }

    @ViewBuilder private func windowPicker(for provider: ProviderID) -> some View {
        let windows = store.sortedWindows(for: provider)
        if !windows.isEmpty {
            Picker("\(provider.title) 메뉴 막대 한도", selection: Binding(
                get: { store.trackedWindow(for: provider)?.id ?? "" },
                set: { store.selectWindow($0, for: provider) }
            )) {
                ForEach(windows) { Text($0.label).tag($0.id) }
            }
        }
    }

    private func connectionRow(for provider: ProviderID) -> some View {
        let state = store.states[provider]
        return VStack(alignment: .leading, spacing: UsageSpacing.compact) {
            HStack(alignment: .center, spacing: UsageSpacing.item) {
                Label(provider.title, systemImage: provider.symbol)
                    .font(UsageType.headline)
                Spacer()
                if state?.isRefreshing == true {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("\(provider.title) 연결 확인 중")
                }
                Text(store.connectionStatus(for: provider))
                    .font(UsageType.secondary)
                    .foregroundStyle(connectionColor(for: provider))
                Button("확인") { Task { await store.refresh(provider, force: true) } }
                    .disabled(store.isDemo || !store.canRefresh(provider))
                    .accessibilityLabel("\(provider.title) 연결 확인")
            }
            if store.enabledProviders.contains(provider), let error = state?.errorMessage {
                note(error, color: UsageTheme.warning)
            }
            if let message = store.retryMessage(for: provider) {
                note(message)
            }
            if let snapshot = state?.snapshot {
                note([snapshot.plan.flatMap { $0.isEmpty ? nil : $0 },
                        String(localized: "마지막 성공 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")]
                    .compactMap { $0 }.joined(separator: " · "))
            } else if let attemptedAt = state?.lastAttempt {
                note(String(localized: "마지막 확인 \(attemptedAt.formatted(date: .abbreviated, time: .shortened))"))
            }
        }
        .padding(.vertical, UsageSpacing.tight)
    }

    private func sectionTitle(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(UsageType.sectionHeading)
            .foregroundStyle(UsageTheme.ink)
    }

    private func detail(_ key: LocalizedStringKey, color: Color = UsageTheme.secondaryInk) -> some View {
        Text(key).font(UsageType.secondary).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String, color: Color = UsageTheme.secondaryInk) -> some View {
        Text(text).font(UsageType.secondary).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func connectionColor(for provider: ProviderID) -> Color {
        if !store.enabledProviders.contains(provider) { return UsageTheme.secondaryInk }
        if store.states[provider]?.isRefreshing == true { return UsageTheme.secondaryInk }
        if store.states[provider]?.errorMessage != nil || store.isStale(for: provider) { return UsageTheme.warning }
        return UsageTheme.secondaryInk
    }
}
