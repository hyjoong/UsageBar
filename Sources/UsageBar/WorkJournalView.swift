import AppKit
import SwiftUI
import UsageBarCore

/// The full receipt list with a start card at the top. Mirrors the panel row at a larger size.
struct WorkJournalView: View {
    @ObservedObject private var store: AppStore
    @ObservedObject private var journal: WorkJournalController
    @State private var kind: WorkKind = WorkKind.allCases[0]
    @State private var provider: ProviderID
    @State private var copiedReceiptID: UUID?
    @State private var receiptToDelete: WorkReceipt?

    init(store: AppStore) {
        _store = ObservedObject(wrappedValue: store)
        _journal = ObservedObject(wrappedValue: store.workJournal)
        _provider = State(initialValue: store.activeProviders.contains(store.selectedProvider)
                          ? store.selectedProvider : (store.activeProviders.first ?? .claude))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UsageSpacing.section) {
                if !journal.isLoaded {
                    loading
                } else {
                    if let active = journal.state.active { activeCard(active) } else { startCard }
                    if let message = journal.message {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(UsageType.secondary).foregroundStyle(UsageTheme.warning)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    receipts
                }
            }
            .padding(UsageSpacing.windowInset)
        }
        .font(UsageType.body)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 600)
        .background(UsageTheme.canvas)
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        .task { await journal.load() }
        .alert("영수증을 삭제할까요?", isPresented: Binding(
            get: { receiptToDelete != nil },
            set: { if !$0 { receiptToDelete = nil } }
        ), presenting: receiptToDelete) { receipt in
            Button("삭제", role: .destructive) { Task { await journal.deleteReceipt(receipt.id) } }
            Button("취소", role: .cancel) { receiptToDelete = nil }
        } message: { receipt in
            Text("\(receipt.kind.title) 작업 영수증을 삭제합니다. 삭제한 영수증은 복구할 수 없어요.")
        }
        .onChange(of: store.activeProviders) { _, providers in
            if !providers.contains(provider), let first = providers.first { provider = first }
        }
    }

    // MARK: Start / active

    private var startCard: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.group) {
            Picker("작업 유형", selection: $kind) {
                ForEach(WorkKind.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(journal.isBusy)
            HStack(spacing: UsageSpacing.item) {
                if store.activeProviders.count > 1 {
                    Picker("기록할 서비스", selection: $provider) {
                        ForEach(store.activeProviders) { item in Text(item.title).tag(item) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(journal.isBusy)
                } else if let selected = store.activeProviders.first {
                    Label(selected.title, systemImage: selected.symbol).foregroundStyle(UsageTheme.secondaryInk)
                } else {
                    Text("설정에서 조회할 서비스를 켜주세요.").foregroundStyle(UsageTheme.secondaryInk)
                }
                Text("한도 기준으로 기록").font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: UsageSpacing.item)
                if journal.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("시작 한도 확인 중")
                }
                Button("작업 시작") {
                    Task { await journal.start(kind: kind, provider: provider) { id in try await store.workSnapshot(for: id) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(journal.isBusy || !store.activeProviders.contains(provider)
                          || store.states[provider]?.snapshot == nil)
                .help("현재 한도를 확인하고 작업 기록을 시작해요. 끝낼 때 한도 변화를 영수증으로 남겨요.")
            }
        }
        .padding(16)
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: UsageRadius.card))
    }

    private func activeCard(_ active: WorkSession) -> some View {
        VStack(alignment: .leading, spacing: UsageSpacing.group) {
            HStack(spacing: UsageSpacing.group) {
                Image(systemName: "record.circle").font(.system(size: 20)).foregroundStyle(UsageTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let label = UsageFormat.durationLabel(context.date.timeIntervalSince(active.startedAt))
                        Text(label).font(UsageType.metric).monospacedDigit()
                            .accessibilityLabel("기록 경과 시간 \(label)")
                    }
                    Text("\(active.kind.title) · \(active.provider.title) · \(active.startedAt.formatted(date: .omitted, time: .shortened)) 시작")
                        .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                }
                Spacer(minLength: UsageSpacing.item)
                if journal.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("종료 한도 확인 중")
                }
                Menu {
                    Button("기록 취소", role: .destructive) { Task { await journal.discard() } }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(journal.isBusy)
                .accessibilityLabel("진행 중인 작업 추가 메뉴")
                Button("작업 종료") {
                    Task { await journal.finish { id in try await store.workSnapshot(for: id) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(journal.isBusy)
                .help("한도를 다시 확인하고 이번 작업 영수증을 저장해요")
            }
            if journal.message != nil {
                Button("한도 비교 없이 종료") { Task { await journal.finishWithoutSnapshot() } }
                    .buttonStyle(.link).disabled(journal.isBusy)
                    .help("종료 한도는 확인하지 않고 작업 시간만 저장해요")
            }
        }
        .padding(16)
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: UsageRadius.card))
    }

    // MARK: Receipts

    private var receipts: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.item) {
            HStack {
                Text("영수증").font(UsageType.title)
                Spacer()
                Text("\(journal.state.receipts.count)개").font(UsageType.secondary).monospacedDigit()
                    .foregroundStyle(UsageTheme.secondaryInk)
            }
            if journal.state.receipts.isEmpty {
                Text("작업 하나를 마치면 여기에 남아요. 대화 내용이나 프로젝트 파일은 수집하지 않아요.")
                    .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, UsageSpacing.group)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(journal.state.receipts) { receipt in
                        receiptRow(receipt)
                        Divider()
                    }
                }
            }
        }
    }

    private func receiptRow(_ receipt: WorkReceipt) -> some View {
        let copied = copiedReceiptID == receipt.id
        let notes = receipt.rows.compactMap { row in row.note.map { "\(row.label): \($0)" } }
        return VStack(alignment: .leading, spacing: UsageSpacing.tight) {
            HStack(spacing: UsageSpacing.item) {
                Text(UsageFormat.durationLabel(receipt.duration))
                    .font(UsageType.durationCompact).monospacedDigit()
                    .accessibilityLabel("기록한 시간 \(UsageFormat.durationLabel(receipt.duration))")
                Text("\(receipt.kind.title) · \(receipt.provider.title)")
                    .foregroundStyle(UsageTheme.secondaryInk)
                Spacer(minLength: UsageSpacing.item)
                Text(receipt.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(receipt.copyText, forType: .string) { copiedReceiptID = receipt.id }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(copied ? UsageTheme.accent : UsageTheme.secondaryInk)
                .help(copied ? "복사됨" : "요약 복사")
                .accessibilityLabel("\(receipt.kind.title) 작업 영수증 요약 복사")
                .accessibilityValue(copied ? "복사 완료" : "")
                Menu {
                    Button("영수증 삭제…", role: .destructive) { receiptToDelete = receipt }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(journal.isBusy)
                .accessibilityLabel("\(receipt.kind.title) 작업 영수증 추가 메뉴")
            }
            Text(UsageFormat.receiptSummary(receipt.rows))
                .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .help("관측 구간의 계정 전체 사용률 변화예요. 다른 창·기기의 사용도 포함되며, 이 작업만의 사용량은 아니에요.")
            ForEach(notes, id: \.self) { note in
                Text(note).font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, UsageSpacing.group)
        .accessibilityElement(children: .contain)
    }

    private var loading: some View {
        Group {
            if let message = journal.message {
                VStack(alignment: .leading, spacing: UsageSpacing.group) {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(UsageType.secondary).foregroundStyle(UsageTheme.warning)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack {
                        Button("다시 읽기") { Task { await journal.load() } }.disabled(journal.isBusy)
                        if journal.isBusy {
                            ProgressView().controlSize(.small).accessibilityLabel("작업 기록 다시 읽는 중")
                        }
                    }
                }
            } else {
                ProgressView("작업 기록 불러오는 중").frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }
}
