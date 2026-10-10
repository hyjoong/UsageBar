import AppKit
import SwiftUI
import UsageBarCore

struct WorkJournalView: View {
    @ObservedObject private var store: AppStore
    @ObservedObject private var journal: WorkJournalController
    @State private var kind: WorkKind = WorkKind.allCases[0]
    @State private var provider: ProviderID
    @State private var copiedReceiptID: String?
    @State private var receiptToDelete: WorkReceipt?

    init(store: AppStore) {
        _store = ObservedObject(wrappedValue: store)
        _journal = ObservedObject(wrappedValue: store.workJournal)
        _provider = State(initialValue: store.activeProviders.contains(store.selectedProvider)
                          ? store.selectedProvider : (store.activeProviders.first ?? .claude))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !journal.isLoaded {
                        if let message = journal.message {
                            VStack(alignment: .leading, spacing: 14) {
                                Label(message, systemImage: "exclamationmark.circle")
                                    .font(.callout)
                                    .foregroundStyle(UsageTheme.secondaryInk)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                HStack {
                                    Button("다시 읽기") { Task { await journal.load() } }
                                        .disabled(journal.isBusy)
                                    if journal.isBusy {
                                        ProgressView().controlSize(.small)
                                            .accessibilityLabel("작업 기록 다시 읽는 중")
                                    }
                                }
                            }
                        } else {
                            ProgressView("작업 기록 불러오는 중")
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    } else {
                        if let active = journal.state.active {
                            activeCard(active)
                        } else {
                            startCard
                        }
                        if let message = journal.message {
                            Label(message, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(UsageTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        receipts
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 660)
        .background(UsageTheme.canvas)
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        .task { await journal.load() }
        .alert("영수증을 삭제할까요?", isPresented: Binding(
            get: { receiptToDelete != nil },
            set: { if !$0 { receiptToDelete = nil } }
        ), presenting: receiptToDelete) { receipt in
            Button("삭제", role: .destructive) {
                Task { await journal.deleteReceipt(receipt.id) }
            }
            Button("취소", role: .cancel) { receiptToDelete = nil }
        } message: { receipt in
            Text("\(receipt.kind.title) 작업 영수증을 삭제합니다. 삭제한 영수증은 복구할 수 없어요.")
        }
        .onChange(of: store.activeProviders) { _, providers in
            if !providers.contains(provider), let first = providers.first {
                provider = first
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                UsageBrandMark()
                    .foregroundStyle(UsageTheme.accent)
                    .frame(width: 23, height: 23)
                Text("작업 영수증")
                    .font(.system(size: 21, weight: .semibold))
            }
            Text("작업을 시작하고 마칠 때, 걸린 시간과 한도 변화를 남겨요.")
                .font(.callout)
            Text("계정 전체의 변화로, 같은 계정의 다른 창·기기에서 사용한 양도 포함됩니다.")
                .font(.caption)
                .foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("이번에는 어떤 작업인가요?")
                .font(.system(size: 15, weight: .semibold))
            Picker("작업 유형", selection: $kind) {
                ForEach(WorkKind.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(journal.isBusy)
            HStack {
                if store.activeProviders.count > 1 {
                    Picker("사용 서비스", selection: $provider) {
                        ForEach(store.activeProviders) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .frame(maxWidth: 220)
                    .disabled(journal.isBusy)
                } else if let selected = store.activeProviders.first {
                    Label(selected.title, systemImage: selected.symbol)
                        .foregroundStyle(UsageTheme.secondaryInk)
                } else {
                    Text("설정에서 조회할 서비스를 켜주세요.")
                        .font(.callout)
                        .foregroundStyle(UsageTheme.secondaryInk)
                }
                Spacer(minLength: 16)
                if journal.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("시작 한도 확인 중")
                }
                Button("작업 시작") {
                    Task {
                        await journal.start(kind: kind, provider: provider) { id in
                            try await store.workSnapshot(for: id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(journal.isBusy || !store.activeProviders.contains(provider))
                .help("현재 한도를 확인하고 작업 기록을 시작합니다")
            }
        }
        .padding(20)
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func activeCard(_ active: WorkSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(active.kind.title)
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("\(active.provider.title) · 기록 중")
                    .font(.callout)
                    .foregroundStyle(UsageTheme.accent)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.durationLabel(context.date.timeIntervalSince(active.startedAt)))
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("기록 경과 시간 \(Self.durationLabel(context.date.timeIntervalSince(active.startedAt)))")
            }
            Text("\(active.startedAt.formatted(date: .abbreviated, time: .shortened)) 시작")
                .font(.caption)
                .foregroundStyle(UsageTheme.secondaryInk)
            HStack {
                Button("기록 취소") { Task { await journal.discard() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(UsageTheme.secondaryInk)
                    .disabled(journal.isBusy)
                    .help("진행 중인 작업 기록을 저장하지 않고 취소합니다")
                Spacer()
                if journal.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("종료 한도 확인 중")
                }
                Button("작업 종료") {
                    Task {
                        await journal.finish { id in
                            try await store.workSnapshot(for: id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(journal.isBusy)
                .help("한도를 다시 확인하고 이번 작업 영수증을 저장합니다")
            }
            if journal.message != nil {
                Button("한도 비교 없이 종료") {
                    Task { await journal.finishWithoutSnapshot() }
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(journal.isBusy)
                .help("종료 한도는 확인하지 않고 작업 시간만 저장합니다")
            }
        }
        .padding(20)
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var receipts: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("최근 영수증").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(journal.state.receipts.count)개")
                    .font(.caption)
                    .foregroundStyle(UsageTheme.secondaryInk)
            }
            if journal.state.receipts.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("작업 하나를 마치면 여기에 남아요.")
                        .font(.callout)
                    Text("대화 내용이나 프로젝트 파일은 수집하지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(UsageTheme.secondaryInk)
                }
                .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(journal.state.receipts) { receipt in
                        receiptView(receipt)
                    }
                }
            }
        }
    }

    private func receiptView(_ receipt: WorkReceipt) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(receipt.kind.title)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 12)
                    Text(receipt.provider.title)
                        .font(.caption)
                        .foregroundStyle(UsageTheme.secondaryInk)
                    Menu {
                        Button("영수증 삭제…", role: .destructive) { receiptToDelete = receipt }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(journal.isBusy)
                    .accessibilityLabel("\(receipt.kind.title) 작업 영수증 추가 메뉴")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(Self.durationLabel(receipt.duration))
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("기록한 시간 \(Self.durationLabel(receipt.duration))")
                    Text(receipt.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(UsageTheme.secondaryInk)
                }
            }
            .padding(20)

            receiptPerforation

            VStack(alignment: .leading, spacing: 12) {
                Text("관측된 한도 변화")
                    .font(.caption)
                    .foregroundStyle(UsageTheme.secondaryInk)
                ForEach(receipt.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).font(.callout)
                            Spacer(minLength: 12)
                            Text(Self.deltaLabel(row.percentagePoints))
                                .font(row.percentagePoints.map { $0 > 0 } == true
                                      ? .system(size: 17, weight: .medium, design: .monospaced)
                                      : .system(size: 12, weight: .regular))
                                .foregroundStyle(row.percentagePoints == nil ? UsageTheme.secondaryInk : UsageTheme.ink)
                        }
                        if let note = row.note, !note.isEmpty, note != Self.deltaLabel(row.percentagePoints) {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(UsageTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(receipt.copyText, forType: .string) {
                            copiedReceiptID = String(describing: receipt.id)
                        }
                    } label: {
                        Label(copiedReceiptID == String(describing: receipt.id) ? "복사됨" : "요약 복사",
                              systemImage: copiedReceiptID == String(describing: receipt.id) ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("\(receipt.kind.title) 작업 영수증 요약 복사")
                    .accessibilityValue(copiedReceiptID == String(describing: receipt.id) ? "복사 완료" : "")
                }
                .padding(.top, 2)
            }
            .padding(20)
        }
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var receiptPerforation: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(UsageTheme.canvas)
                .frame(width: 12, height: 12)
                .offset(x: -6)
            ReceiptPerforationLine()
                .stroke(UsageTheme.secondaryInk.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(height: 1)
            Circle()
                .fill(UsageTheme.canvas)
                .frame(width: 12, height: 12)
                .offset(x: 6)
        }
        .accessibilityHidden(true)
    }

    private static func durationLabel(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "시간 확인 불가" }
        let minutes = Int(min(max(0, interval / 60), Double(Int.max / 2)))
        if minutes == 0 { return "1분 미만" }
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)시간" : "\(hours)시간 \(remainder)분"
    }

    private static func deltaLabel(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "비교 불가" }
        if value == 0 { return "표시상 변화 없음" }
        return "+\(value.formatted(.number.precision(.fractionLength(0...2))))%p"
    }
}

private struct ReceiptPerforationLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
