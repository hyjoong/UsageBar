import AppKit
import SwiftUI
import UsageBarCore

struct PreferencesView: View {
    @ObservedObject var store: AppStore
    @StateObject private var launchAtLogin: LaunchAtLoginStore

    init(store: AppStore) {
        self.store = store
        _launchAtLogin = StateObject(wrappedValue: LaunchAtLoginStore(demo: store.isDemo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    UsageBrandMark().frame(width: 15, height: 15)
                    Text("UsageBar").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(UsageTheme.secondaryInk)
                Text("설정").font(.system(size: 24, weight: .semibold))
                Text("메뉴 막대 표시와 연결을 관리하세요.")
                    .font(.system(size: 12)).foregroundStyle(UsageTheme.secondaryInk)
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)

            Rectangle().fill(UsageTheme.separator).frame(height: 1).padding(.horizontal, 28)

            Form {
                Section {
                    Picker("화면 모드", selection: $store.appearanceMode) {
                        ForEach(UsageAppearanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    detail("기본은 어둡게 표시해요. 이 앱에만 적용돼요.")
                } header: {
                    sectionTitle("화면", symbol: "circle.lefthalf.filled")
                }

                Section {
                    Picker("메뉴 막대 표시", selection: $store.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("기본으로 보는 서비스", selection: $store.selectedProvider) {
                        ForEach(store.activeProviders) { Text($0.title).tag($0) }
                    }
                    Toggle("메뉴 막대에 잔여율 표시", isOn: $store.showPercentage)
                    Toggle("리셋까지 남은 시간도 표시", isOn: $store.showResetCountdown)
                        .disabled(!store.showPercentage)
                    if store.showPercentage && store.showResetCountdown {
                        detail("표시 예: 62% · 2h 10m · 선택한 한도의 리셋 시각을 사용해요.")
                    }
                    ForEach(store.menuProviders) { provider in
                        windowPicker(for: provider)
                    }
                    detail("한도는 서비스별로 기억해요. 두 서비스를 함께 표시할 때도 각 서비스에서 선택한 한도를 사용해요.")
                } header: {
                    sectionTitle("메뉴 막대", symbol: "menubar.rectangle")
                }

                Section {
                    Toggle("로그인 시 UsageBar 실행", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    detail(launchAtLogin.statusMessage,
                           color: launchAtLogin.requiresApproval ? UsageTheme.warning : UsageTheme.secondaryInk)
                    if let message = launchAtLogin.errorMessage {
                        detail(message, color: UsageTheme.warning)
                    }
                    if launchAtLogin.requiresApproval {
                        Button("로그인 항목 설정 열기") { launchAtLogin.openSystemSettings() }
                    }
                } header: {
                    sectionTitle("시작", symbol: "power")
                }

                Section {
                    Toggle("남은 한도가 20% 아래로 내려가면 알림", isOn: Binding(
                        get: { store.notificationsEnabled },
                        set: { value in Task { await store.setNotificationsEnabled(value) } }
                    ))
                    detail("같은 한도에서 반복해서 알리지 않아요. 알림을 켤 때 macOS 권한을 요청해요.")
                    if let message = store.notificationMessage {
                        detail(message, color: UsageTheme.warning)
                    }
                } header: {
                    sectionTitle("알림", symbol: "bell")
                }

                Section {
                    ForEach(ProviderID.allCases) { provider in
                        Toggle("\(provider.title) 사용량 조회", isOn: Binding(
                            get: { store.enabledProviders.contains(provider) },
                            set: { store.setProviderEnabled($0, for: provider) }
                        ))
                        .disabled(store.enabledProviders.contains(provider) && store.enabledProviders.count == 1)
                        connectionRow(for: provider)
                    }
                    detail("켜 둔 서비스만 조회해요. 최소 한 서비스는 켜 두며, 끈 서비스의 기존 기록은 보관해요. Claude Code와 Codex의 로그인 상태를 이용해요. 사용량은 5분마다 확인하며, 인증이나 초기 설정은 해당 도구에서 먼저 완료해 주세요.")
                } header: {
                    sectionTitle("연결", symbol: "link")
                }

                Section {
                    LabeledContent("버전", value: "0.6.0")
                    detail("사용량 기록은 이 Mac에 저장돼요. 대화 내용은 수집하지 않아요.")
                } header: {
                    sectionTitle("앱 정보", symbol: "info.circle")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .font(.system(size: 13))
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        .background(UsageTheme.canvas)
        .frame(width: 520)
        .frame(minHeight: 520, idealHeight: 740, maxHeight: 800)
        .onAppear { launchAtLogin.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Label(provider.title, systemImage: provider.symbol)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if state?.isRefreshing == true {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("\(provider.title) 연결 확인 중")
                }
                Text(store.connectionStatus(for: provider))
                    .font(.system(size: 12))
                    .foregroundStyle(connectionColor(for: provider))
                Button("확인") { Task { await store.refresh(provider, force: true) } }
                    .disabled(store.isDemo || !store.canRefresh(provider))
                    .accessibilityLabel("\(provider.title) 연결 확인")
            }
            if store.enabledProviders.contains(provider), let error = state?.errorMessage {
                detail(error, color: UsageTheme.warning)
            }
            if let message = store.retryMessage(for: provider) {
                detail(message)
            }
            if let snapshot = state?.snapshot {
                if let plan = snapshot.plan, !plan.isEmpty {
                    detail(plan)
                }
                detail("마지막 성공: \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                detail(snapshot.source)
            } else if let attemptedAt = state?.lastAttempt {
                detail("마지막 확인: \(attemptedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .padding(.vertical, 5)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(UsageTheme.ink)
    }

    private func detail(_ text: String, color: Color = UsageTheme.secondaryInk) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func connectionColor(for provider: ProviderID) -> Color {
        if !store.enabledProviders.contains(provider) { return UsageTheme.secondaryInk }
        if store.states[provider]?.isRefreshing == true { return UsageTheme.secondaryInk }
        if store.states[provider]?.errorMessage != nil || store.isStale(for: provider) { return UsageTheme.warning }
        return UsageTheme.secondaryInk
    }
}
