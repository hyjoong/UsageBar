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
            Text(store.selectedState.errorMessage ?? "잠시 후 다시 시도해 주세요.")
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
                    Button("\(other.title)만 사용할게요 · \(provider.title) 조회 끄기") {
                        store.setProviderEnabled(false, for: provider)
                    }
                    .buttonStyle(.link).font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                    .help("설정 → 연결에서 언제든 다시 켤 수 있어요")
                }
            }
        }
        .padding(.vertical, UsageSpacing.tight)
    }

    @ViewBuilder private var claudeSteps: some View {
        step(1, "Claude Code 설치") {
            Button("설치 안내") { NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/quickstart")!) }
                .buttonStyle(.link)
        }
        step(2, "터미널에서 로그인", detail: "연결 설정을 열면 터미널에서 초기 설정과 로그인을 진행해요.") {
            Button("연결 설정 열기") { setupMessage = ClaudeSetupLauncher.open() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        step(3, "돌아와서 확인") { recheck }
    }

    @ViewBuilder private var codexSteps: some View {
        step(1, "Codex CLI 설치") {
            Button("설치 안내") { NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex")!) }
                .buttonStyle(.link)
        }
        step(2, "터미널에서 로그인", detail: "codex login 으로 ChatGPT 계정에 로그인해요.") { EmptyView() }
        step(3, "돌아와서 확인") { recheck }
    }

    private var recheck: some View {
        Button("다시 확인") { Task { await store.refresh(provider, force: true) } }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!store.canRefresh(provider))
    }

    private func step<Trailing: View>(_ number: Int, _ title: String, detail: String? = nil,
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
        .accessibilityLabel("\(number)단계, \(title)")
    }
}
