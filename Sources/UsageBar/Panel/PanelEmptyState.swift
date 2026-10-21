import AppKit
import SwiftUI
import UsageBarCore

/// Shown when no snapshot exists yet: loading, guided connection setup, or a failed first fetch.
struct PanelEmptyState: View {
    @ObservedObject var store: AppStore
    private var provider: ProviderID { store.selectedProvider }
    private var needsConnectionSetup: Bool {
        store.selectedState.requiresConnection || store.selectedState.errorMessage == nil
    }

    var body: some View {
        if store.selectedState.isRefreshing {
            loading
        } else if RecoveryCard.applies(to: store.selectedState, provider: provider) {
            RecoveryCard(store: store)
        } else if needsConnectionSetup {
            ConnectionSetupCard(store: store)
        } else {
            failure
        }
    }

    private var loading: some View {
        VStack(spacing: UsageSpacing.group) {
            ProgressView().controlSize(.small)
            Text("\(provider.title) 한도 확인 중").font(UsageType.headline)
            Text(provider == .claude ? "Claude Code의 사용량 화면을 확인하고 있어요." : "로그인된 Codex 계정의 한도를 확인하고 있어요.")
                .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity, minHeight: 160).multilineTextAlignment(.center)
    }

    private var failure: some View {
        VStack(spacing: UsageSpacing.group) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28)).foregroundStyle(UsageTheme.warning)
            Text("한도를 불러오지 못했어요").font(UsageType.title)
            Text(store.selectedState.errorMessage ?? String(localized: "잠시 후 다시 시도해 주세요."))
                .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("다시 확인") { Task { await store.refresh(provider, force: true) } }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canRefresh(provider))
            if let retry = store.retryMessage(for: provider) {
                Text(retry).font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            }
            Button("서비스 장애 현황 확인") { NSWorkspace.shared.open(provider.statusURL) }
                .buttonStyle(.link).font(UsageType.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 200).multilineTextAlignment(.center)
        .padding(.vertical, UsageSpacing.item)
    }
}

/// Recovery for a known connection problem: an expired login, or a Codex CLI that would not launch.
/// The same card sits above cached usage and in place of the empty state, so both offer the same actions.
/// Claude reaches this card only for a lost login, which it can fix from here with the login controls.
struct RecoveryCard: View {
    @ObservedObject var store: AppStore
    private var provider: ProviderID { store.selectedProvider }
    private var state: ProviderState { store.selectedState }
    private var isLogin: Bool { state.connectionIssue == .authentication }

    static func applies(to state: ProviderState, provider: ProviderID) -> Bool {
        state.connectionIssue == .authentication || (provider == .codex && state.connectionIssue == .setup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.item) {
            title.font(UsageType.headline).foregroundStyle(UsageTheme.warning)
            if provider == .claude {
                Text("Claude Code 로그인이 풀렸어요. 브라우저에서 다시 로그인하면 바로 이어서 보여 드려요.")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                ClaudeLoginControls(store: store)
            } else {
                codexDetails
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var codexDetails: some View {
        if let message = state.errorMessage {
            Text(message).font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(isLogin ? "터미널에서 codex login을 실행하고 돌아와 다시 확인을 눌러 주세요." : "설치된 Codex를 다시 찾아 연결해요. 연결되지 않으면 Codex 앱이나 CLI를 설치·업데이트해 주세요.")
            .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: UsageSpacing.item) {
            if isLogin {
                CopyCommandButton(command: "codex login", help: "터미널에서 로그인하는 명령어를 복사해요")
                recheck("다시 확인").buttonStyle(.bordered)
            } else {
                recheck("Codex 다시 연결").buttonStyle(.borderedProminent)
                Button("설치·업데이트 안내") { NSWorkspace.shared.open(provider.installURL) }.buttonStyle(.link)
            }
            if state.isRefreshing { ProgressView().controlSize(.small) }
        }
        if let retry = store.retryMessage(for: provider) {
            Text(retry).font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var title: some View {
        if provider == .claude {
            Label("Claude 로그인이 필요해요", systemImage: "person.crop.circle.badge.exclamationmark")
        } else if isLogin {
            Label("\(provider.title) 로그인 확인이 필요해요", systemImage: "person.crop.circle.badge.exclamationmark")
        } else {
            Label("Codex 연결을 확인해 주세요", systemImage: "exclamationmark.circle")
        }
    }

    private func recheck(_ title: LocalizedStringKey) -> some View {
        Button(title) { Task { await store.refresh(provider, force: true) } }
            .disabled(!store.canRefresh(provider))
    }
}

/// Copies a terminal command and says so for two seconds, so a second copy gets feedback too.
struct CopyCommandButton: View {
    let command: String
    let help: LocalizedStringKey
    var onCopy: () -> Void = {}
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button(copied ? LocalizedStringKey("복사했어요") : LocalizedStringKey("명령어 복사")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            onCopy()
            reset?.cancel()
            reset = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { copied = false }
            }
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

/// Signs Claude in again without a Terminal: the CLI's own `auth login` opens the browser and
/// UsageBar rechecks when it finishes. Copying the command covers a Mac where that cannot run.
struct ClaudeLoginControls: View {
    @ObservedObject var store: AppStore
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.compact) {
            if case .waiting(let url) = store.claudeLogin {
                HStack(spacing: UsageSpacing.item) {
                    ProgressView().controlSize(.small)
                    Text("브라우저에서 로그인을 마쳐 주세요").font(UsageType.secondary)
                    Spacer(minLength: 0)
                    Button("취소") { store.cancelClaudeLogin() }.buttonStyle(.link)
                }
                if let url {
                    Button("브라우저가 열리지 않았나요? 로그인 페이지 열기") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link).font(UsageType.caption)
                }
            } else {
                HStack(spacing: UsageSpacing.item) {
                    Button("브라우저에서 로그인") { copied = false; store.startClaudeLogin() }
                        .buttonStyle(.borderedProminent)
                    CopyCommandButton(command: ClaudeLogin.manualCommand(), help: "터미널에서 직접 로그인하는 명령어를 복사해요") {
                        copied = true
                        store.watchClaudeConnection()
                    }
                    if store.selectedState.isRefreshing { ProgressView().controlSize(.small) }
                }
                if case .failed(let message) = store.claudeLogin {
                    Text(message).font(UsageType.caption).foregroundStyle(UsageTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if copied {
                    Text("터미널에 붙여넣어 실행하고 로그인하면 자동으로 다시 확인해요.")
                        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

}

/// Three numbered steps that take a new user from an installed CLI to a working connection.
struct ConnectionSetupCard: View {
    @ObservedObject var store: AppStore
    @State private var setupMessage: String?
    private var provider: ProviderID { store.selectedProvider }
    private var other: ProviderID? { store.activeProviders.first { $0 != provider } }

    var body: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.section) {
            VStack(alignment: .leading, spacing: UsageSpacing.compact) {
                HStack(spacing: UsageSpacing.item) {
                    Image(systemName: "link.circle.fill").font(.system(size: 22)).foregroundStyle(UsageTheme.accent)
                        .accessibilityHidden(true)
                    Text("\(provider.title) 연결하기").font(UsageType.title)
                }
                Text(provider == .claude
                     ? "이 Mac에 설치된 Claude Code의 로그인 상태를 사용해요. 비밀번호나 API 키는 입력하지 않아요."
                     : "설치된 Codex CLI와 ChatGPT 구독 로그인을 사용해요. API 키 계정의 요금은 지원하지 않아요.")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: UsageSpacing.group) {
                if provider == .claude { claudeSteps } else { codexSteps }
            }

            VStack(alignment: .leading, spacing: UsageSpacing.compact) {
                if let message = store.selectedState.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(UsageType.caption).foregroundStyle(UsageTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let setupMessage {
                    Label(setupMessage, systemImage: "exclamationmark.circle")
                        .font(UsageType.caption).foregroundStyle(UsageTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let other {
                    Button("\(other.title)만 쓸게요") { store.setProviderEnabled(false, for: provider) }
                        .buttonStyle(.link).font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                    Text("\(provider.title) 조회를 꺼요. 설정 → 연결에서 언제든 다시 켤 수 있어요.")
                        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, UsageSpacing.tight)
    }

    @ViewBuilder private var claudeSteps: some View {
        step(1, "Claude Code 설치") {
            Button("설치 안내") { NSWorkspace.shared.open(provider.installURL) }
                .buttonStyle(.link)
        }
        step(2, "터미널에서 로그인", detail: "연결 설정을 열면 터미널에서 초기 설정과 로그인을 진행해요.") {
            Button("연결 설정 열기") {
                Task { setupMessage = await ClaudeSetupLauncher.open(watching: store) }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
        step(3, "돌아와서 확인") { recheck }
    }

    @ViewBuilder private var codexSteps: some View {
        step(1, "Codex CLI 설치") {
            Button("설치 안내") { NSWorkspace.shared.open(provider.installURL) }
                .buttonStyle(.link)
        }
        step(2, "터미널에서 로그인", detail: "codex login 으로 ChatGPT 계정에 로그인해요.") {
            CopyCommandButton(command: "codex login", help: "터미널에서 로그인하는 명령어를 복사해요").controlSize(.small)
        }
        step(3, "돌아와서 확인") { recheck }
    }

    private var recheck: some View {
        Button("다시 확인") { Task { await store.refresh(provider, force: true) } }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!store.canRefresh(provider))
    }

    private func step<Trailing: View>(_ number: Int, _ title: LocalizedStringKey, detail: LocalizedStringKey? = nil,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: UsageSpacing.item) {
            Text("\(number)")
                .font(UsageType.captionMedium).monospacedDigit()
                .frame(width: 20, height: 20)
                .background(UsageTheme.mutedSurface, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(UsageType.headline).frame(minHeight: 20)
                if let detail {
                    Text(detail).font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: UsageSpacing.item)
            trailing().frame(minHeight: 20)
        }
        .font(UsageType.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(number)단계, ") + Text(title))
    }
}
