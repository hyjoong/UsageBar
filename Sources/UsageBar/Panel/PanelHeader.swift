import SwiftUI
import UsageBarCore

/// Provider switch on the left, plan on the right. The brand lives in the menu bar icon, not here.
struct PanelHeader: View {
    @ObservedObject var store: AppStore
    private var provider: ProviderID { store.selectedProvider }
    private var planLabel: String {
        guard let snapshot = store.selectedState.snapshot else {
            if store.selectedState.connectionIssue == .authentication {
                return String(localized: "로그인 확인 필요")
            }
            let needsConnectionSetup = store.selectedState.requiresConnection || store.selectedState.errorMessage == nil
            return needsConnectionSetup ? String(localized: "연결 확인") : String(localized: "조회 대기")
        }
        let plan = snapshot.plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plan.isEmpty ? String(localized: "계정 사용량") : plan
    }

    var body: some View {
        HStack(spacing: 14) {
            if store.activeProviders.count > 1 {
                Picker("서비스", selection: $store.selectedProvider) {
                    ForEach(store.activeProviders) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            } else {
                Label(provider.title, systemImage: provider.symbol)
                    .font(UsageType.headline)
            }
            Spacer(minLength: 0)
            Text(planLabel)
                .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                .lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, UsageSpacing.panelInset).padding(.vertical, UsageSpacing.group)
    }
}
