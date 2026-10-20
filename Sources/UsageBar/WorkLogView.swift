import AppKit
import SwiftUI
import UsageBarCore
import WorkLogCore

/// The work log window: today's journal, the last seven days, and the receipts. Window id "work-journal".
struct WorkLogView: View {
    @ObservedObject private var store: AppStore
    @ObservedObject private var workLog: WorkLogController

    init(store: AppStore) {
        _store = ObservedObject(wrappedValue: store)
        _workLog = ObservedObject(wrappedValue: store.workLog)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("작업 기록 보기", selection: $workLog.tab) {
                ForEach(WorkLogTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(maxWidth: 300)
            .padding(.top, UsageSpacing.group).padding(.bottom, UsageSpacing.tight)
            switch workLog.tab {
            case .today: WorkLogTodayView(store: store, workLog: workLog)
            case .week: WorkLogWeekView(store: store, workLog: workLog)
            case .receipts: WorkReceiptsView(store: store)
            }
        }
        .font(UsageType.body)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 440, idealHeight: 640)
        .background(UsageTheme.canvas)
        .foregroundStyle(UsageTheme.ink)
        .tint(UsageTheme.accent)
        // Keyed on the switch only: the other settings refresh from their own setters, and restarting this
        // loop on each of them would read the logs (and git) a second time.
        .task(id: workLog.settings.isEnabled) { await workLog.runWhileVisible() }
    }
}

// MARK: - Today

private struct WorkLogTodayView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var workLog: WorkLogController
    @ObservedObject private var journal: WorkJournalController
    @State private var showsGitNotice = false
    @State private var copied: String?

    init(store: AppStore, workLog: WorkLogController) {
        self.store = store
        self.workLog = workLog
        _journal = ObservedObject(wrappedValue: store.workJournal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UsageSpacing.section) {
                if workLog.settings.isEnabled {
                    header
                    content
                } else {
                    WorkLogIntroCard(workLog: workLog)
                }
            }
            .padding(UsageSpacing.windowInset)
        }
        .workLogGitNotice(isPresented: $showsGitNotice, workLog: workLog)
    }

    private var header: some View {
        HStack(spacing: UsageSpacing.item) {
            Button { workLog.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).disabled(!workLog.canGoBack)
                .help("이전 날").accessibilityLabel("이전 날")
            Text(workLog.selectedDay.formatted(.dateTime.month(.wide).day().weekday(.abbreviated)))
                .font(UsageType.title).monospacedDigit()
            Button { workLog.step(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).disabled(!workLog.canGoForward)
                .help("다음 날").accessibilityLabel("다음 날")
            if workLog.isRefreshing {
                ProgressView().controlSize(.small).accessibilityLabel("기록을 읽는 중")
            }
            Spacer(minLength: UsageSpacing.item)
            if let log = workLog.selectedLog, !log.isEmpty {
                Menu {
                    Button("스크럼 3줄") { copy(workLog.formatter().standUp(log), as: "standup") }
                    Button("마크다운") { copy(workLog.formatter().markdown(log), as: "markdown") }
                } label: {
                    Label(copied == nil ? String(localized: "복사") : String(localized: "복사됨"),
                          systemImage: copied == nil ? "doc.on.doc" : "checkmark")
                }
                .fixedSize()
                .help("이 날의 일지를 복사해요")
            }
        }
        .onChange(of: workLog.selectedDay) { _, _ in copied = nil }
    }

    @ViewBuilder private var content: some View {
        if let message = workLog.message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(UsageType.secondary).foregroundStyle(UsageTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let log = workLog.selectedLog {
            HStack(alignment: .firstTextBaseline, spacing: UsageSpacing.item) {
                Text(verbatim: workLog.formatter().headline(log)).font(UsageType.headline).monospacedDigit()
                    .help("여러 프로젝트를 동시에 진행한 시간은 한 번만 세요")
                Spacer(minLength: 0)
                if log.isPartial {
                    Label("일부만 집계됨", systemImage: "info.circle")
                        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                        .help("세션 기록이 커서 아직 다 읽지 못했어요. 잠시 후 이어서 읽어요.")
                }
            }
            if !workLog.settings.includesGit {
                HStack(spacing: UsageSpacing.tight) {
                    Text("커밋은 보이지 않아요.").foregroundStyle(UsageTheme.secondaryInk)
                    Button("커밋도 함께 보기…") { showsGitNotice = true }.buttonStyle(.link)
                        .help("커밋과 미커밋 파일을 보여주고, 워크트리를 원래 저장소로 묶어요")
                }
                .font(UsageType.secondary)
            }
            if log.isEmpty {
                emptyState(log)
            } else {
                let main = log.projects.filter { $0.duration >= 60 || !$0.commits.isEmpty }
                let minor = log.projects.filter { $0.duration < 60 && $0.commits.isEmpty }
                ForEach(main) { project in
                    WorkLogProjectCard(project: project, workLog: workLog,
                                       receipts: WorkLogController.receipts(journal.state.receipts, overlapping: project))
                }
                if !minor.isEmpty {
                    DisclosureGroup {
                        ForEach(minor) { project in
                            WorkLogProjectCard(project: project, workLog: workLog,
                                               receipts: WorkLogController.receipts(journal.state.receipts, overlapping: project))
                        }
                    } label: {
                        Text("기타 \(minor.count)").font(UsageType.headline).foregroundStyle(UsageTheme.secondaryInk)
                    }
                }
            }
        } else if workLog.isRefreshing || workLog.lastRefreshed == nil {
            ProgressView("기록을 읽는 중…").frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func emptyState(_ log: DailyWorkLog) -> some View {
        let isToday = Calendar.current.isDateInToday(log.day.start)
        return VStack(spacing: UsageSpacing.item) {
            Image(systemName: "text.book.closed").font(.system(size: 28)).foregroundStyle(UsageTheme.secondaryInk)
                .accessibilityHidden(true)
            Text(isToday ? String(localized: "오늘 기록된 세션이 없어요") : String(localized: "이 날 기록된 세션이 없어요"))
                .font(UsageType.headline)
            Text("Claude Code나 Codex로 작업하면 여기에 프로젝트별로 모여요.")
                .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { copied = kind }
    }
}

/// Asked once, on the first visit to the today tab, before any log is read (decision Q1).
private struct WorkLogIntroCard: View {
    @ObservedObject var workLog: WorkLogController

    var body: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.group) {
            Label("작업 일지를 켤까요?", systemImage: "text.book.closed").font(UsageType.title)
            Text("이 Mac의 Claude Code·Codex 세션 기록을 모아 하루 동안 어떤 프로젝트에서 얼마나 일했는지, 어떤 요청을 했는지 보여줘요. 스크럼 3줄이나 마크다운으로 복사할 수 있어요.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: UsageSpacing.tight) {
                Label("모든 처리는 이 Mac 안에서만 해요. 네트워크로 보내지 않아요.", systemImage: "lock")
                Label("요청 문장은 저장하지 않고, 화면에 그릴 때 원본 기록에서 첫 줄만 읽어요.", systemImage: "eye.slash")
                Label("커밋은 따로 켜야 읽어요. 켜면 하위 폴더와 워크트리도 저장소 단위로 묶여요.", systemImage: "arrow.triangle.branch")
            }
            .labelStyle(AlignedIconLabelStyle())
            .font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("작업 일지 켜기") { Task { await workLog.setEnabled(true) } }
                    .buttonStyle(.borderedProminent)
                Text("설정 → 작업 기록에서 언제든 끌 수 있어요.")
                    .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: UsageRadius.card))
    }
}

/// Icons in one column, so the lines of a list start at the same place whatever the symbol's width.
private struct AlignedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UsageSpacing.item) {
            configuration.icon.frame(width: 18)
            configuration.title
        }
    }
}

// MARK: - Project card

private struct WorkLogProjectCard: View {
    let project: ProjectDay
    @ObservedObject var workLog: WorkLogController
    let receipts: [WorkReceipt]
    @State private var requests: [String] = []
    @State private var showsAllRequests = false
    @State private var copiedSHA: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.item) {
            HStack(alignment: .firstTextBaseline, spacing: UsageSpacing.item) {
                Text(verbatim: project.name).font(UsageType.title).lineLimit(1)
                Spacer(minLength: UsageSpacing.item)
                Text(verbatim: WorkLogFormatter.duration(project.duration)).font(UsageType.headline).monospacedDigit()
                if !project.sources.isEmpty {
                    Text(verbatim: project.sources.map(\.title).joined(separator: " · "))
                        .font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                }
            }
            WorkLogTimeline(intervals: project.intervals, day: workLog.selectedLog?.day)
            requestSection
            commitSection
            if let files = workLog.formatter().fileLine(project) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(project.changedFiles.sorted(), id: \.self) { file in
                            Text(verbatim: file).font(UsageType.captionMono).foregroundStyle(UsageTheme.secondaryInk)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(verbatim: files).font(UsageType.secondary)
                }
            }
            if !project.pullRequests.isEmpty {
                Text("PR \(project.pullRequests.count)").font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                    .help(project.pullRequests.joined(separator: "\n"))
            }
            if !receipts.isEmpty {
                Text(verbatim: receiptLine).font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
                    .help("이 시간대에 기록한 작업 영수증이에요")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UsageTheme.surface, in: RoundedRectangle(cornerRadius: UsageRadius.card))
        .accessibilityElement(children: .contain)
        .task(id: RequestKey(prompts: project.prompts.map(\.location), shows: workLog.settings.showsPrompts)) {
            requests = await workLog.excerpts(project.prompts.map(\.location))
        }
    }

    private struct RequestKey: Hashable { let prompts: [PromptLocation]; let shows: Bool }

    @ViewBuilder private var requestSection: some View {
        let titles = Array(Set(project.sessions.compactMap(\.title))).sorted()
        let shown = showsAllRequests ? requests : Array(requests.prefix(3))
        if !titles.isEmpty || !shown.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("요청").font(UsageType.captionMedium).foregroundStyle(UsageTheme.secondaryInk)
                ForEach(titles.prefix(3), id: \.self) { title in
                    Text(verbatim: title).font(UsageType.headline).lineLimit(1)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, request in
                    Text(verbatim: "· " + request).font(UsageType.secondary).lineLimit(1).textSelection(.enabled)
                }
                if requests.count > 3 {
                    Button(showsAllRequests ? String(localized: "접기") : String(localized: "더 보기 (\(requests.count))")) {
                        showsAllRequests.toggle()
                    }
                    .buttonStyle(.link).font(UsageType.caption)
                }
            }
        }
    }

    @ViewBuilder private var commitSection: some View {
        switch project.git.state {
        case .ok where !project.commits.isEmpty:
            VStack(alignment: .leading, spacing: 3) {
                Text("커밋 \(project.commits.count)").font(UsageType.captionMedium).foregroundStyle(UsageTheme.secondaryInk)
                ForEach(project.commits, id: \.sha) { commit in
                    Button {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(commit.sha, forType: .string) { copiedSHA = commit.sha }
                    } label: {
                        HStack(spacing: UsageSpacing.item) {
                            Text(verbatim: "· " + commit.subject).lineLimit(1)
                            Spacer(minLength: UsageSpacing.item)
                            Text(verbatim: copiedSHA == commit.sha ? String(localized: "복사됨") : commit.time.formatted(date: .omitted, time: .shortened))
                                .font(UsageType.caption).monospacedDigit().foregroundStyle(UsageTheme.secondaryInk)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).font(UsageType.secondary)
                    .help("눌러서 커밋 해시 \(commit.shortSHA) 복사")
                    .accessibilityLabel(Text(verbatim: "\(commit.subject), \(commit.time.formatted(date: .omitted, time: .shortened))"))
                    .accessibilityHint("커밋 해시를 복사해요")
                }
            }
        case .unavailable:
            gitNote(String(localized: "git을 찾지 못해 커밋을 읽지 않았어요."))
        case .failed:
            gitNote(String(localized: "커밋을 읽지 못했어요. 폴더 접근을 거부했다면 시스템 설정 → 개인정보 보호 및 보안 → 파일 및 폴더에서 UsageBar를 허용해 주세요."))
        default:
            EmptyView()
        }
    }

    private func gitNote(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var receiptLine: String {
        let parts = receipts.prefix(3).map { "\($0.kind.title) \(UsageFormat.durationLabel($0.duration))" }
        return String(localized: "영수증 \(receipts.count) · \(parts.joined(separator: ", "))")
    }
}

/// When in the day the project was worked on, as marks on a 24-hour bar.
private struct WorkLogTimeline: View {
    let intervals: [WorkInterval]
    let day: DateInterval?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(UsageTheme.mutedSurface)
                if let day, day.duration > 0 {
                    ForEach(Array(intervals.enumerated()), id: \.offset) { _, interval in
                        let start = interval.start.timeIntervalSince(day.start) / day.duration
                        let width = max(interval.duration / day.duration, 0.004)
                        Capsule().fill(UsageTheme.accent)
                            .frame(width: max(3, geometry.size.width * width))
                            .offset(x: geometry.size.width * start)
                    }
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Week

private struct WorkLogWeekView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var workLog: WorkLogController
    @ObservedObject private var journal: WorkJournalController
    @State private var copied = false

    init(store: AppStore, workLog: WorkLogController) {
        self.store = store
        self.workLog = workLog
        _journal = ObservedObject(wrappedValue: store.workJournal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UsageSpacing.section) {
                if let summary = WorkSummaryCard.make(receipts: journal.state.receipts, now: store.clockNow) {
                    WorkSummaryCard(summary: summary, receipts: journal.state.receipts)
                }
                if workLog.settings.isEnabled {
                    days
                } else {
                    VStack(alignment: .leading, spacing: UsageSpacing.item) {
                        Text("작업 일지를 켜면 날짜별 프로젝트와 작업 시간이 여기에 보여요.")
                            .foregroundStyle(UsageTheme.secondaryInk).fixedSize(horizontal: false, vertical: true)
                        Button("오늘 탭에서 켜기") { workLog.tab = .today }
                    }
                }
            }
            .padding(UsageSpacing.windowInset)
        }
    }

    private var days: some View {
        VStack(alignment: .leading, spacing: UsageSpacing.item) {
            HStack {
                Text("날짜별").font(UsageType.title)
                Spacer()
                if workLog.logs.contains(where: { !$0.isEmpty }) {
                    Button {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(workLog.weekMarkdown(), forType: .string)
                    } label: {
                        Label(copied ? String(localized: "복사됨") : String(localized: "주간 마크다운 복사"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            if workLog.logs.isEmpty {
                ProgressView("기록을 읽는 중…").frame(maxWidth: .infinity, minHeight: 80)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(workLog.logs, id: \.day.start) { log in
                    Button { workLog.show(log.day.start) } label: { row(log) }
                        .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func row(_ log: DailyWorkLog) -> some View {
        HStack(spacing: UsageSpacing.item) {
            Text(log.day.start.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated)))
                .font(UsageType.headline).monospacedDigit().frame(width: 96, alignment: .leading)
            if log.isEmpty {
                Text("기록 없음").foregroundStyle(UsageTheme.secondaryInk)
            } else {
                Text(verbatim: WorkLogFormatter.duration(log.duration)).monospacedDigit().frame(width: 92, alignment: .leading)
                Text(verbatim: log.projects.prefix(3).map(\.name).joined(separator: ", "))
                    .foregroundStyle(UsageTheme.secondaryInk).lineLimit(1)
            }
            Spacer(minLength: UsageSpacing.item)
            if log.commitCount > 0 {
                Text("커밋 \(log.commitCount)").font(UsageType.secondary).foregroundStyle(UsageTheme.secondaryInk)
            }
            Image(systemName: "chevron.right").font(UsageType.caption).foregroundStyle(UsageTheme.secondaryInk)
                .accessibilityHidden(true)
        }
        .padding(.vertical, UsageSpacing.group)
        .contentShape(Rectangle())
    }
}

// MARK: - Git notice

extension WorkLogSource {
    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .git: "git"
        }
    }
}

extension View {
    /// The folder access notice shown before git reading turns on (decision Q2, plan §7.4).
    func workLogGitNotice(isPresented: Binding<Bool>, workLog: WorkLogController) -> some View {
        alert("프로젝트 폴더를 읽어도 될까요?", isPresented: isPresented) {
            Button("계속") { Task { await workLog.setIncludesGit(true) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("커밋을 보여주려면 각 프로젝트의 git 기록을 읽어야 해요. 켜면 하위 폴더와 에이전트 워크트리도 원래 저장소로 묶어 보여줘요. 프로젝트가 데스크탑이나 문서 폴더에 있으면 macOS가 UsageBar의 폴더 접근을 허용할지 물어볼 수 있어요. 거부해도 커밋만 빠지고 나머지 일지는 그대로 보여요.")
        }
    }
}
