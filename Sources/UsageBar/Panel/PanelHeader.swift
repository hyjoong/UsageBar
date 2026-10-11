import SwiftUI
import UsageBarCore

/// Brand row plus the provider switch and plan label.
struct PanelHeader: View {
    @ObservedObject var store: AppStore
    private var provider: ProviderID { store.selectedProvider }
    private var planLabel: String {
        guard let snapshot = store.selectedState.snapshot else {
            let needsConnectionSetup = store.selectedState.requiresConnection || store.selectedState.errorMessage == nil
            return needsConnectionSetup ? "연결 확인" : "조회 대기"
        }
        let plan = snapshot.plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plan.isEmpty ? "계정 사용량" : plan
    }

    var body: some View {
        VStack(spacing: UsageSpacing.group) {
            HStack(spacing: UsageSpacing.item) {
                UsageBrandMark().frame(width: 28, height: 28)
                Text("UsageBar").font(UsageType.title)
                Spacer()
                Text(store.isDemo ? "예시 데이터" : "계정 전체")
                    .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            }
            HStack(spacing: 14) {
                if store.activeProviders.count > 1 {
                    Picker("서비스", selection: $store.selectedProvider) {
                        ForEach(store.activeProviders) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 185)
                } else {
                    Label(provider.title, systemImage: provider.symbol)
                        .font(UsageType.headline)
                }
                Spacer(minLength: 0)
                Text(planLabel)
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                    .lineLimit(2).multilineTextAlignment(.trailing)
            }
        }.padding(.horizontal, UsageSpacing.panelInset).padding(.vertical, 14)
    }
}
