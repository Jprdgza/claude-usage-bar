import Charts
import SwiftUI
import UsageCore

/// The "Claude Usage" window: History, Claude Code by project, Scheduled messages.
struct DetailsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.detailsTab) {
            HistoryTab().tabItem { Text("History") }.tag("history")
            EfficiencyTab().tabItem { Text("Efficiency") }.tag("efficiency")
            CodeTab().tabItem { Text("Claude Code") }.tag("code")
            ScheduleTab().tabItem { Text("Scheduled messages") }.tag("schedule")
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 520)
    }
}

// MARK: History

struct HistoryTab: View {
    @EnvironmentObject var model: AppModel
    @State private var range: Double = 7 * 86400
    @State private var selected: Date?

    private struct Sample: Identifiable { let id = UUID(); let t: Date; let window: String; let v: Double }

    var body: some View {
        let since = Date().addingTimeInterval(-range)
        let points = model.history.points(since: since)
        let ids = model.history.windowIds
        let samples = points.flatMap { p in ids.compactMap { id in p.v[id].map { Sample(t: p.t, window: model.windowLabel(id), v: $0) } } }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $range) {
                    Text("24 hours").tag(86400.0)
                    Text("7 days").tag(7 * 86400.0)
                    Text("30 days").tag(30 * 86400.0)
                    Text("1 year").tag(365 * 86400.0)
                }
                .pickerStyle(.segmented).frame(width: 360)
                Spacer()
                Text("\(points.count) readings").font(.caption).foregroundStyle(.secondary)
            }
            if samples.isEmpty {
                Text("No history yet. A reading is saved whenever a percentage changes (and every 30 minutes otherwise), so the chart fills in as the app runs.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(EfficiencyAnalyzer.peakIntervals(from: since, to: Date(), config: model.config), id: \.0) { a, b in
                        RectangleMark(xStart: .value("From", a), xEnd: .value("To", b)).foregroundStyle(.gray.opacity(0.10))
                    }
                    ForEach(tighter(since: since), id: \.resetsAt) { s in
                        RectangleMark(xStart: .value("From", s.resetsAt.addingTimeInterval(-5 * 3600)), xEnd: .value("To", s.resetsAt))
                            .foregroundStyle(.red.opacity(0.12))
                    }
                    if let sel = selected {
                        RuleMark(x: .value("Selected", sel)).foregroundStyle(.secondary)
                    }
                    ForEach(samples) { s in
                        LineMark(x: .value("Time", s.t), y: .value("Used %", s.v))
                            .foregroundStyle(by: .value("Limit", s.window))
                            .interpolationMethod(.stepEnd)
                    }
                    RuleMark(y: .value("Limit", 100)).foregroundStyle(.red.opacity(0.5)).lineStyle(StrokeStyle(dash: [4, 4]))
                }
                .chartYScale(domain: 0...105)
                .chartXSelection(value: $selected)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
                .frame(maxHeight: .infinity)
                if let sel = selected { readout(at: sel, points: points) } else {
                    Text("Click the chart for details. Grey bands: peak hours (\(EfficiencyAnalyzer.peakHoursLocal(model.config)) your time). Red bands: 5-hour windows where limits looked tighter than your normal.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                busiest(points: points)
            }
            Text("Kept for about 13 months in ~/Library/Application Support/ClaudeUsageBar/history.jsonl. Only percentages, reset times and the product split; nothing leaves your Mac.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func tighter(since: Date) -> [EfficiencySample] {
        model.efficiency.filter { $0.resetsAt >= since && EfficiencyAnalyzer.verdict(for: $0, among: model.efficiency)?.kind == .tighter }
    }

    /// What was going on at the clicked time: readings, peak hours, and any "decreased limits" flag.
    @ViewBuilder private func readout(at t: Date, points: [HistoryPoint]) -> some View {
        let p = points.last { $0.t <= t } ?? points.first
        let window = model.efficiency.first { t <= $0.resetsAt && t > $0.resetsAt.addingTimeInterval(-5 * 3600) }
        let verdict = window.flatMap { EfficiencyAnalyzer.verdict(for: $0, among: model.efficiency) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Fmt.clock(t)).bold()
                if UsageMath.isPeak(t, config: model.config) {
                    Text("peak hours").font(.caption2).padding(.horizontal, 5).background(.orange.opacity(0.2), in: Capsule())
                }
                if verdict?.kind == .tighter {
                    Text("decreased limits?").font(.caption2).padding(.horizontal, 5).background(.red.opacity(0.2), in: Capsule())
                }
                Spacer()
                if let p {
                    Text(p.v.keys.sorted().map { "\(model.windowLabel($0)) \(Fmt.percent(p.v[$0]!))" }.joined(separator: " · "))
                        .font(.caption).monospacedDigit()
                }
            }
            if let window {
                Text(EfficiencyAnalyzer.explain(window, verdict: verdict, config: model.config))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if UsageMath.isPeak(t, config: model.config) {
                Text("Peak hours: the 5-hour limit is tighter (roughly 1.5×), so the same work uses more of it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Which hours of the day the 5-hour usage climbs most: a hint for when you burn through it.
    @ViewBuilder private func busiest(points: [HistoryPoint]) -> some View {
        let key = "session"
        var byHour: [Int: Double] = [:]
        let _ = zip(points, points.dropFirst()).forEach { a, b in
            if let x = a.v[key], let y = b.v[key], y > x {
                byHour[Calendar.current.component(.hour, from: b.t), default: 0] += y - x
            }
        }
        if let top = byHour.sorted(by: { $0.value > $1.value }).prefix(3).map(\.key) as [Int]?, !top.isEmpty {
            Text("Your 5-hour usage climbs fastest around " + top.map { String(format: "%02d:00", $0) }.joined(separator: ", ") + ".")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Claude Code

struct CodeTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @State private var period = "session"

    var body: some View {
        let rows: [CodeProjectUsage] = period == "session" ? model.codeSession : period == "day" ? model.codeDay : model.codeWeek
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $period) {
                    Text("This 5-hour window").tag("session")
                    Text("Last 24 hours").tag("day")
                    Text("This week").tag("week")
                }
                .pickerStyle(.segmented).frame(width: 420)
                Spacer()
                Button { model.scanClaudeCode() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            if !settings.showClaudeCode {
                Text("Turned off in Settings.").foregroundStyle(.secondary)
            } else if !model.claudeCodeAvailable {
                Text("No Claude Code logs found at ~/.claude/projects.").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No Claude Code activity in this period.").foregroundStyle(.secondary)
            } else {
                Table(rows) {
                    TableColumn("Project") { r in Text(r.name).help(r.path) }
                    TableColumn("Share") { r in
                        HStack { UsageBar(percent: r.share, level: .low).frame(width: 70); Text(Fmt.percent(r.share)).monospacedDigit() }
                    }
                    .width(130)
                    TableColumn("Tokens") { r in Text(Fmt.compact(r.tokens)).monospacedDigit().help("\(Fmt.tokens(r.tokens)) tokens, \(Fmt.tokens(r.output)) of them output") }
                        .width(70)
                    TableColumn("Sessions") { r in Text("\(r.sessions)").monospacedDigit() }.width(60)
                    TableColumn("Mostly") { r in Text(r.topModel.map(shortModel) ?? "–") }.width(90)
                    TableColumn("Last active") { r in Text(Fmt.relative(r.lastActive, now: Date())) }.width(90)
                }
            }
            if let b = model.usage?.breakdowns.first, let code = b.rows.first(where: { $0.name.localizedCaseInsensitiveContains("code") }) {
                Text("claude.ai says Claude Code is \(Fmt.percent(code.percent)) of your weekly usage. The shares above split that part between projects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Read from Claude Code's own logs on this Mac (exact token counts per API call). \"Share\" weighs tokens by API price ratios (output 5×, cache reads 0.1×) and model, since claude.ai doesn't publish how it charges plan limits. Cowork runs in the cloud and keeps no local logs, so it can't be split this way.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.scanClaudeCode() }
    }

    private func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}

// MARK: Scheduled messages

struct ScheduleTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var scheduler: Scheduler
    @EnvironmentObject var settings: SettingsStore

    @State private var chats: [ConversationSummary] = []
    @State private var loadingChats = false
    @State private var chatId = "__new__"
    @State private var text = ""
    @State private var when = "session"
    @State private var at = Date().addingTimeInterval(3600)
    /// "code", or "chat" where sending into claude.ai chats is available.
    @AppStorage("scheduleDestination") private var destination = "code"

    static let canSendToChats = false
    @State private var projects: [CodeProject] = []
    @State private var projectPath = ""
    @State private var sessionId = "__new__"

    private var project: CodeProject? { projects.first { $0.path == projectPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composer
            Divider()
            queue
        }
        .task {
            if !Self.canSendToChats { destination = "code" }
            if !resettable.contains(where: { $0.id == when }) { when = resettable.first?.id ?? "time" }
            if Self.canSendToChats { await loadChats() }
            await loadProjects()
        }
    }

    @ViewBuilder private var composer: some View {
        HStack {
            Text("Queue a message").font(.headline)
            Spacer()
            if Self.canSendToChats {
                Picker("", selection: $destination) {
                    Text("claude.ai chat").tag("chat")
                    Text("Claude Code").tag("code")
                }
                .pickerStyle(.segmented).frame(width: 240)
            }
        }
        if destination == "chat" {
            HStack {
                Picker("Chat", selection: $chatId) {
                    Text("New chat").tag("__new__")
                    ForEach(chats) { c in Text(c.name.isEmpty ? "Untitled" : c.name).tag(c.id) }
                }
                .frame(maxWidth: 420)
                if loadingChats { ProgressView().controlSize(.small) }
                Button { Task { await loadChats() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload recent chats")
            }
        } else {
            codePickers
        }
        TextEditor(text: $text)
            .font(.body).frame(height: 90)
            .scrollContentBackground(.hidden).padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text("Message to send…").foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false) }
            }
        whenPicker
        HStack(alignment: .firstTextBaseline) {
            Text(sendSummary).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Schedule") { schedule() }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (destination == "chat" ? model.status == .loggedOut : project == nil))
        }
        if destination == "code" {
            Label("When it's done, click the chat in the Claude app and press ⌘R to see it. Don't type in that chat while the scheduled message is running.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Text("The Mac stays awake until it's sent and finished (the screen can still turn off). To close the lid, turn on \"Keep running with the lid closed\" in Settings.")
            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    /// The 5-hour and weekly limits only (model-specific weekly limits reset with the weekly one anyway).
    private var resettable: [UsageWindow] {
        (model.usage?.windows ?? []).filter { ($0.id == "session" || $0.id == "weekly_all") && $0.resetsAt != nil }
    }

    private func resetLabel(_ w: UsageWindow) -> String { w.id == "session" ? "5-hour reset" : "Weekly reset" }

    @ViewBuilder private var whenPicker: some View {
        Picker("Send", selection: $when) {
            ForEach(resettable) { w in Text(resetLabel(w)).tag(w.id) }
            Text("At a time").tag("time")
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        if when == "time" {
            HStack(spacing: 8) {
                DatePicker("", selection: $at, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().datePickerStyle(.field)
                ForEach(presets, id: \.0) { p in
                    Button(p.0) { at = p.1 }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    /// Quick picks: in an hour, tonight, tomorrow morning.
    private var presets: [(String, Date)] {
        let cal = Calendar.current, now = Date()
        var out: [(String, Date)] = [("In 1 hour", now.addingTimeInterval(3600))]
        if let tonight = cal.date(bySettingHour: 23, minute: 0, second: 0, of: now), tonight > now.addingTimeInterval(1800) {
            out.append(("Tonight \(Fmt.time(tonight))", tonight))
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) {
            out.append(("Tomorrow \(Fmt.time(morning))", morning))
        }
        return out
    }

    private var sendSummary: String {
        if let w = resettable.first(where: { $0.id == when }), let r = w.resetsAt {
            let t = r.addingTimeInterval(model.config.schedule.delayAfterResetSeconds)
            return "Sends \(Fmt.dayAndClock(t)), right after the \(w.id == "session" ? "5-hour" : "weekly") limit resets"
        }
        return "Sends \(Fmt.dayAndClock(at))"
    }

    @ViewBuilder private var queue: some View {
        HStack {
            Text("Queue").font(.headline)
            if scheduler.keepingAwake {
                Label("Keeping the Mac awake", systemImage: "cup.and.saucer").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            if scheduler.jobs.contains(where: { !$0.state.isActive }) {
                Button("Clear finished") { scheduler.clearFinished() }.buttonStyle(.borderless).font(.caption)
            }
        }
        if scheduler.jobs.isEmpty {
            Text("Nothing queued.").foregroundStyle(.secondary)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(scheduler.jobs.reversed()) { j in JobRow(job: j) }   // newest first
            }
        }
    }

    @ViewBuilder private var codePickers: some View {
        if projects.isEmpty {
            Text("No Claude Code projects with sessions in the last 30 days were found in ~/.claude/projects.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Project", selection: $projectPath) {
                ForEach(projects) { p in Text(p.name).tag(p.path) }
            }
            .frame(maxWidth: 420)
            .onChange(of: projectPath) { _, _ in sessionId = project?.sessions.first?.id ?? "__new__" }
            .help(projectPath)
            Picker("Chat", selection: $sessionId) {
                ForEach(project?.sessions ?? []) { s in Text("\(s.title) · \(Fmt.relative(s.lastActive, now: Date()))").tag(s.id) }
                Text("New chat in this project").tag("__new__")
            }
            .frame(maxWidth: 420)
            .help("Permissions: the same mode as this chat (\(CodeCommand.permissionMode(for: selectedSession, in: project))).")
        }
    }

    private var selectedSession: CodeSession? { project?.sessions.first { $0.id == sessionId } }

    private func loadProjects() async {
        let list = await Task.detached(priority: .userInitiated) { CodeSessionCatalog.list() }.value
        projects = list
        if project == nil { projectPath = list.first?.path ?? "" }
        if sessionId == "__new__" || selectedSession == nil { sessionId = project?.sessions.first?.id ?? "__new__" }
    }

    private func loadChats() async {
        loadingChats = true
        chats = await model.recentConversations(limit: 30)
        loadingChats = false
    }

    private func schedule() {
        let trigger: ScheduledMessage.Trigger
        if let w = resettable.first(where: { $0.id == when }) {
            trigger = .afterReset(windowId: w.id, label: w.label)
        } else {
            trigger = .at(at)
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if destination == "code", let p = project {
            let session = p.sessions.first { $0.id == sessionId }
            let target = ScheduledMessage.CodeTarget(projectPath: p.path, projectName: p.name, sessionId: session?.id,
                                                     sessionTitle: session?.title,
                                                     permissionMode: CodeCommand.permissionMode(for: session, in: p),
                                                     model: session?.model)
            scheduler.add(ScheduledMessage(conversationId: nil, conversationName: "\(p.name) · \(session?.title ?? "new session")",
                                           text: message, trigger: trigger, code: target))
        } else {
            let chat = chats.first { $0.id == chatId }
            scheduler.add(ScheduledMessage(conversationId: chat?.id, conversationName: chat.map { $0.name.isEmpty ? "Untitled" : $0.name } ?? "New chat",
                                           text: message, trigger: trigger))
        }
        text = ""
    }
}

struct JobRow: View {
    @EnvironmentObject var scheduler: Scheduler
    let job: ScheduledMessage
    @State private var watching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.isClaudeCode ? "Claude Code" : "Chat").font(.caption2).padding(.horizontal, 5)
                    .background((job.isClaudeCode ? Color.purple : Color.blue).opacity(0.18), in: Capsule())
                Text(job.conversationName).bold().lineLimit(1)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(color)
            }
            Text(job.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            if let d = job.detail { Text(d).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if job.state == .waiting {
                    Button("Send now") { scheduler.sendNow(job.id) }
                    Button("Cancel") { scheduler.cancel(job.id) }
                }
                if job.state == .failed {
                    Button(job.sentAt != nil ? "Send again" : "Retry now") { scheduler.sendNow(job.id) }
                        .help(job.sentAt != nil ? "Check the chat first: part of it may already have gone through." : "")
                }
                if job.isClaudeCode, scheduler.live[job.id] != nil { Button(job.state.isActive ? "Watch" : "Show what happened") { watching = true } }
                if job.isClaudeCode, job.code?.sessionId != nil, !job.state.isActive {
                    Button("Open in Claude") { scheduler.openInClaudeApp(job.id) }
                        .help("Opens this session in the Claude desktop app. If it's already open there, press ⌘R in the Claude app (View → Reload) to see the new messages.")
                }
                if !job.state.isActive { Button("Remove") { scheduler.remove(job.id) } }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .sheet(isPresented: $watching) { CodeLiveView(jobId: job.id, title: job.conversationName).environmentObject(scheduler) }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusText: String {
        switch job.state {
        case .waiting: return scheduler.describe(job)
        case .sending: return "Sending…"
        case .waitingForReply: return job.isClaudeCode ? "Running in Claude Code…" : "Waiting for the reply…"
        case .done: return "Done \(job.finishedAt.map(Fmt.clock) ?? "")"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var icon: String {
        switch job.state {
        case .waiting: return "clock"
        case .sending, .waitingForReply: return "paperplane"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    private var color: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .orange
        }
    }
}

// MARK: Efficiency

/// Long-term "work per 1 % of the 5-hour limit" per window, compared with your own normal.
struct EfficiencyTab: View {
    @EnvironmentObject var model: AppModel
    @State private var range: Double = 30 * 86400
    @State private var selected: Date?

    init(selected: Date? = nil) { _selected = State(initialValue: selected) }

    struct Bar: Identifiable {
        var id: Date { sample.resetsAt }
        let sample: EfficiencySample
        let verdict: EfficiencyVerdict?
        let percentOfNormal: Double
    }

    private func bars(since: Date) -> [Bar] {
        let all = model.efficiency
        let overall = EfficiencyAnalyzer.medianPublic(all.filter(\.finished).compactMap(\.costPerPercent))
        return all.filter { $0.resetsAt >= since }.compactMap { s in
            guard let v = s.costPerPercent else { return nil }
            let verdict = EfficiencyAnalyzer.verdict(for: s, among: all)
            let pct = verdict.map { $0.ratio * 100 } ?? overall.map { v / $0 * 100 } ?? 100
            return Bar(sample: s, verdict: verdict, percentOfNormal: pct)
        }
    }

    var body: some View {
        let since = Date().addingTimeInterval(-range)
        let data = bars(since: since)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $range) {
                    Text("30 days").tag(30 * 86400.0)
                    Text("90 days").tag(90 * 86400.0)
                    Text("1 year").tag(365 * 86400.0)
                }
                .pickerStyle(.segmented).frame(width: 280)
                Spacer()
                Text("\(data.count) measured windows").font(.caption).foregroundStyle(.secondary)
            }
            Text("How much Claude Code work 1% of your 5-hour limit bought, per 5-hour window. 100% = your normal. A red bar means the same work used noticeably more of the limit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if data.isEmpty {
                Text("Nothing measured yet. A window is measured once Claude Code moves the 5-hour limit by at least 3 points while the app is running. Your normal is known after \(EfficiencyAnalyzer.minBaseline) measured windows, so give it a few days.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(EfficiencyAnalyzer.peakIntervals(from: since, to: Date(), config: model.config), id: \.0) { a, b in
                        RectangleMark(xStart: .value("From", a), xEnd: .value("To", b))
                            .foregroundStyle(.gray.opacity(0.10))
                    }
                    RuleMark(y: .value("Normal", 100)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) { Text("your normal").font(.caption2).foregroundStyle(.secondary) }
                    ForEach(data) { bar in
                        BarMark(x: .value("Window", bar.sample.resetsAt), y: .value("Work per 1%", bar.percentOfNormal),
                                width: .fixed(range <= 31 * 86400 ? 7 : range <= 91 * 86400 ? 3 : 1.5))
                            .foregroundStyle(color(bar.verdict))
                            .opacity(selected.map { abs($0.timeIntervalSince(bar.sample.resetsAt)) < 3 * 3600 ? 1 : 0.55 } ?? 1)
                    }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
                .chartXSelection(value: $selected)
                .frame(maxHeight: .infinity)
                if let bar = nearest(data) { detail(bar) } else {
                    Text("Click a bar for details. Grey bands are peak hours (\(EfficiencyAnalyzer.peakHoursLocal(model.config)) your time).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                flaggedList(data)
            }
            Text("Estimate. Only Claude Code work can be measured (it's the only product with local token logs); its part of each window comes from claude.ai's weekly product split. Switching models changes the weighting, and percentages are whole numbers, so small windows are skipped. Kept for about a year in efficiency.jsonl.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nearest(_ data: [Bar]) -> Bar? {
        guard let sel = selected else { return nil }
        return data.min { abs($0.sample.resetsAt.timeIntervalSince(sel)) < abs($1.sample.resetsAt.timeIntervalSince(sel)) }
    }

    private func color(_ v: EfficiencyVerdict?) -> Color {
        switch v?.kind {
        case .tighter: return .red
        case .looser: return .blue
        case .normal: return .green
        case nil: return .gray
        }
    }

    @ViewBuilder private func detail(_ bar: Bar) -> some View {
        let s = bar.sample
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(Fmt.clock(s.resetsAt.addingTimeInterval(-5 * 3600)))–\(Fmt.clock(s.resetsAt))").bold()
                if s.mostlyPeak { Text("peak hours").font(.caption2).padding(.horizontal, 5).background(.orange.opacity(0.2), in: Capsule()) }
                if bar.verdict?.kind == .tighter { Text("decreased limits?").font(.caption2).padding(.horizontal, 5).background(.red.opacity(0.2), in: Capsule()) }
                Spacer()
                Text("\(Int(bar.percentOfNormal.rounded()))% of normal").monospacedDigit()
            }
            Text(EfficiencyAnalyzer.explain(s, verdict: bar.verdict, config: model.config)).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("Claude Code: \(Fmt.compact(s.codeTokens)) tokens for \(Fmt.percent(s.attributedDelta)) of the 5-hour limit (\(Fmt.compact(Int(s.tokensPerPercent ?? 0))) tokens per 1%). \(Int((s.codeFraction * 100).rounded()))% of this window's usage was Claude Code; \(Int((s.peakFraction * 100).rounded()))% happened in peak hours.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func flaggedList(_ data: [Bar]) -> some View {
        let flagged = data.filter { $0.verdict?.kind == .tighter }
        if !flagged.isEmpty {
            Text("Windows that looked tighter: \(flagged.count) of \(data.filter { $0.verdict != nil }.count) (\(flagged.filter { $0.sample.mostlyPeak }.count) mostly in peak hours)")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

/// What a scheduled Claude Code run is doing, as it happens: Claude's messages, tool calls and errors.
struct CodeLiveView: View {
    @EnvironmentObject var scheduler: Scheduler
    @Environment(\.dismiss) private var dismiss
    let jobId: UUID
    let title: String

    var body: some View {
        let lines = scheduler.live[jobId] ?? []
        let running = scheduler.job(jobId)?.state.isActive ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Fmt.clock(l.time)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Image(systemName: icon(l.kind)).font(.caption).foregroundStyle(color(l.kind))
                                Text(l.text).font(l.kind == .text ? .callout : .caption.monospaced())
                                    .foregroundStyle(l.kind == .text ? .primary : color(l.kind))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            .id(l.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: lines.count) { _, _ in if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            Text("Shows Claude's messages and actions only. The full conversation is in the session (Open in Claude) or the Terminal window.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
    }

    private func icon(_ k: CodeLiveLine.Kind) -> String {
        switch k { case .text: return "text.bubble"; case .tool: return "hammer"; case .error: return "exclamationmark.triangle"; case .info: return "info.circle" }
    }
    private func color(_ k: CodeLiveLine.Kind) -> Color {
        switch k { case .text: return .primary; case .tool: return .secondary; case .error: return .orange; case .info: return .blue }
    }
}
