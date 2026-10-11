import AppKit
import SwiftUI
import UsageBarCore

/// Shown when no snapshot exists yet: loading, connection setup, or a failed first fetch.
struct PanelEmptyState: View {
    @ObservedObject var store: AppStore
    @State private var setupMessage: String?
    private var provider: ProviderID { store.selectedProvider }
    private var needsConnectionSetup: Bool {
        store.selectedState.requiresConnection || store.selectedState.errorMessage == nil
    }

    var body: some View {
        VStack(spacing: 13) {
            if store.selectedState.isRefreshing {
                ProgressView().controlSize(.small)
                Text("\(provider.title) 한도 확인 중").font(.headline)
                Text(provider == .claude ? "Claude Code의 사용량 화면을 확인하고 있어요." : "로그인된 Codex 계정의 한도를 확인하고 있어요.")
                    .foregroundStyle(UsageTheme.secondaryInk).font(.caption)
            } else {
                Image(systemName: needsConnectionSetup ? "link.circle" : "exclamationmark.circle")
                    .font(.system(size: 30)).foregroundStyle(provider.tint)
                Text(needsConnectionSetup ? "\(provider.title) 연결 확인" : "한도를 불러오지 못했어요").font(.headline)
                Text(store.selectedState.errorMessage ?? (provider == .claude ? "로그인된 Claude Code의 한도와 리셋 시각을 확인해요." : "로그인된 Codex의 한도와 토큰 기록을 확인해요."))
                    .font(.callout).foregroundStyle(UsageTheme.secondaryInk).fixedSize(horizontal: false, vertical: true)
                Button("다시 확인") { Task { await store.refresh(provider, force: true) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canRefresh(provider))
                if let retry = store.retryMessage(for: provider) {
                    Text(retry).font(.caption).foregroundStyle(UsageTheme.secondaryInk)
                }
                if provider == .claude && needsConnectionSetup {
                    Button("Claude 연결 설정") { setupMessage = ClaudeSetupLauncher.open() }
                        .buttonStyle(.bordered)
                    Button("Claude Code 설치 안내") {
                        NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/quickstart")!)
                    }.font(.caption).buttonStyle(.link)
                    Text("터미널에서 처음 한 번 연결을 확인해 주세요.")
                        .font(.caption).foregroundStyle(UsageTheme.secondaryInk)
                    if let setupMessage {
                        Text(setupMessage).font(.caption).foregroundStyle(UsageTheme.warning)
                    }
                }
                Button("공식 사용량 화면 열기") { NSWorkspace.shared.open(provider.dashboardURL) }
                    .font(.caption).buttonStyle(.link)
                Button("서비스 장애 현황 확인") { NSWorkspace.shared.open(provider.statusURL) }
                    .font(.caption).buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity, minHeight: 240).multilineTextAlignment(.center).padding(.vertical, UsageSpacing.group)
    }
}
