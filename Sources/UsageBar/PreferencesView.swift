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
        Form {
            Section("표시") {
                Picker("메뉴바 표시", selection: $store.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("기본으로 보는 서비스", selection: $store.selectedProvider) {
                    ForEach(ProviderID.allCases) { Text($0.title).tag($0) }
                }
                Toggle("메뉴바에 잔여율 표시", isOn: $store.showPercentage)
                let windows = store.sortedWindows(for: store.selectedProvider)
                if !windows.isEmpty {
                    Picker("\(store.selectedProvider.title) 메뉴바 한도", selection: Binding(
                        get: { store.trackedWindow(for: store.selectedProvider)?.id ?? "" },
                        set: { store.selectWindow($0, for: store.selectedProvider) }
                    )) {
                        ForEach(windows) { Text($0.label).tag($0.id) }
                    }
                }
                Text("한도는 서비스별로 기억해요. 두 서비스를 함께 표시할 때도 각 서비스에서 선택한 한도를 사용해요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("시작") {
                Toggle("로그인 시 UsageBar 실행", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                Text(launchAtLogin.statusMessage)
                    .font(.caption)
                    .foregroundStyle(launchAtLogin.requiresApproval ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = launchAtLogin.errorMessage {
                    Text(message)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if launchAtLogin.requiresApproval {
                    Button("로그인 항목 설정 열기") { launchAtLogin.openSystemSettings() }
                }
            }
            Section("알림") {
                Toggle("남은 한도가 20% 아래로 내려가면 알림", isOn: Binding(
                    get: { store.notificationsEnabled },
                    set: { value in Task { await store.setNotificationsEnabled(value) } }
                ))
                Text("같은 한도에서 반복해서 알리지 않아요. 알림을 켤 때 macOS 권한을 요청해요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = store.notificationMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("연결") {
                ForEach(ProviderID.allCases) { provider in
                    connectionRow(for: provider)
                }
                Text("Claude Code와 Codex의 로그인 상태를 이용해요. 사용량은 5분마다 확인하며, 인증이나 초기 설정이 필요하면 해당 도구에서 먼저 완료해 주세요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("UsageBar", value: "0.2.0")
                Text("사용량 기록은 이 Mac에 저장돼요. 대화 내용은 수집하지 않아요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 500)
        .frame(minHeight: 420, idealHeight: 650, maxHeight: 720)
        .onAppear { launchAtLogin.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
    }

    private func connectionRow(for provider: ProviderID) -> some View {
        let state = store.states[provider]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Label(provider.title, systemImage: provider.symbol)
                Spacer()
                if state?.isRefreshing == true {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("\(provider.title) 연결 확인 중")
                }
                Text(store.connectionStatus(for: provider))
                    .font(.caption)
                    .foregroundStyle(connectionColor(for: provider))
                Button("확인") { Task { await store.refresh(provider, force: true) } }
                    .disabled(store.isDemo || state?.isRefreshing == true)
                    .accessibilityLabel("\(provider.title) 연결 확인")
            }
            if let error = state?.errorMessage {
                Text(error)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = state?.snapshot {
                if let plan = snapshot.plan, !plan.isEmpty {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
                Text("마지막 성공: \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(snapshot.source)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let attemptedAt = state?.lastAttempt {
                Text("마지막 확인: \(attemptedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func connectionColor(for provider: ProviderID) -> Color {
        if store.states[provider]?.isRefreshing == true { return .secondary }
        if store.states[provider]?.errorMessage != nil || store.isStale(for: provider) { return .orange }
        return .secondary
    }
}
