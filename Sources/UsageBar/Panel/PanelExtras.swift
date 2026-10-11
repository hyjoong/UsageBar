import SwiftUI
import UsageBarCore

/// Earliest expiring reset credit, shown as a single line above the credit list.
struct CreditExpiryRow: View {
    let snapshot: ProviderSnapshot
    let now: Date

    var body: some View {
        let credit = snapshot.resetCredits?.filter {
            $0.status.lowercased() == "available" && ($0.expiresAt.map { $0 > now } ?? false)
        }.min { $0.expiresAt! < $1.expiresAt! }
        if let date = credit?.expiresAt {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "ticket").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: UsageSpacing.tight) {
                    Text("첫 초기화권 만료 · \(UsageFormat.relativeDate(date, now: now, expiry: true))")
                    Text(date.formatted(UsageFormat.koreanDateTime))
                }
            }
            .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Reset credit count with an expandable per-credit list.
struct CreditsSection: View {
    let snapshot: ProviderSnapshot
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: UsageSpacing.group) { list }.padding(.top, UsageSpacing.group)
        } label: {
            HStack {
                Label("초기화권", systemImage: "ticket")
                Spacer()
                Text("\(count)장").monospacedDigit()
            }.font(UsageType.secondary)
        }
    }

    @ViewBuilder private var list: some View {
        if let credits = snapshot.resetCredits {
            if credits.isEmpty {
                Text("표시할 초기화권 상세가 없어요").font(.caption).foregroundStyle(UsageTheme.secondaryInk)
            }
            ForEach(credits) { credit in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(credit.title.isEmpty ? "초기화권" : credit.title)
                        Text(UsageFormat.creditStatus(credit.status)).foregroundStyle(UsageTheme.secondaryInk)
                    }
                    Spacer()
                    Text(credit.expiresAt.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "만료 없음")
                        .foregroundStyle(UsageTheme.secondaryInk)
                }.font(.caption)
            }
        } else {
            Text("초기화권 상세가 제공되지 않았어요").font(.caption).foregroundStyle(UsageTheme.secondaryInk)
        }
    }
}

/// Latest daily token count, linking to the history window.
struct DailyTokensRow: View {
    let daily: [DailyUsage]
    let openHistory: () -> Void

    var body: some View {
        Button(action: openHistory) {
            HStack {
                Label("최근 일별 토큰", systemImage: "chart.bar")
                Spacer()
                Text(UsageFormat.tokenLabel(daily.last?.tokens ?? 0)).monospacedDigit()
                Image(systemName: "arrow.up.right").foregroundStyle(UsageTheme.secondaryInk)
            }.font(UsageType.secondary).frame(minHeight: UsageSpacing.control)
        }.buttonStyle(.plain)
    }
}
