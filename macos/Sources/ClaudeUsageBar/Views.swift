import AppKit
import SwiftUI
import ServiceManagement
import UsageCore

// MARK: Menu bar

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let w = model.sessionWindow
        HStack(spacing: 3) {
            Image(nsImage: Self.dot(w.map { $0.level.nsColor } ?? .tertiaryLabelColor))
            if settings.showPercentInMenuBar { Text(text(w)) }
        }
    }

    private func text(_ w: UsageWindow?) -> String {
        switch model.status {
        case .loggedOut: return "Log in"
        case .sessionExpired: return "Log in"
        default: return w.map { Fmt.percent($0.percent) } ?? "–"
        }
    }

    /// A non-template image, so the color survives the menu bar's monochrome rendering.
    static func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: Popover

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var scheduler: Scheduler

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            VStack(alignment: .leading, spacing: 10) {
                header(now: tl.date)
                Divider()
                switch model.status {
                case .loggedOut:
                    notice("Not logged in.", action: "Log in…") { WindowManager.shared.showLogin(model: model) }
                case .sessionExpired:
                    notice("claude.ai rejected the saved session (expired or logged out elsewhere).", action: "Log in again…") {
                        WindowManager.shared.showLogin(model: model)
                    }
                default:
                    paceHeadline(now: tl.date)
                    usageSection(now: tl.date)
                    scheduledLine
                    powerLine
                    if settings.showClaudeCode, !model.codeSession.isEmpty || !model.codeWeek.isEmpty {
                        Divider()
                        claudeCodeSection
                    }
                    if settings.recentChats > 0 {
                        Divider()
                        chatsSection(now: tl.date)
                    }
                }
                if let note = model.desktopNote {
                    Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                footer
            }
            .padding(12)
            .frame(width: 380)
        }
        .onAppear { model.popoverOpened() }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude usage").font(.headline)
            if let a = model.account {
                Text(a.tier.displayName).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("Plan detected from claude.ai's account data\(a.orgName.map { " (\($0))" } ?? "").")
            }
            Spacer()
            if model.paused { Text("paused").font(.caption).foregroundStyle(.secondary).help("Polling pauses while the Mac sleeps or the screen is locked.") }
            if let t = model.lastUpdated {
                Text(Fmt.relative(t, now: now)).font(.caption).foregroundStyle(.secondary)
                    .help("Last successful refresh: \(Fmt.clock(t)). Refreshes every \(settings.refreshSeconds)s at most.")
            }
            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").rotationEffect(.degrees(model.refreshing ? 180 : 0))
            }
            .buttonStyle(.borderless).help("Refresh now")
        }
    }

    @ViewBuilder private func usageSection(now: Date) -> some View {
        if case .error(let e) = model.status {
            Text("Last refresh failed: \(e)").font(.caption).foregroundStyle(.red).lineLimit(3)
                .help("Retrying with backoff (up to 15 minutes). Details are in Settings → Debug log.")
        }
        if let u = model.usage {
            if u.isEmpty {
                Text(model.tier == .free
                     ? "claude.ai doesn't report usage limits on the free plan, so there's nothing to show here."
                     : "Usage data unavailable: claude.ai answered, but with no limits this app recognizes. The endpoint may have changed; check the debug log.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(u.windows) { w in WindowRow(window: w, tier: model.tier, config: model.config, now: now) }
            if let x = u.extra { ExtraRow(extra: x) }
            ForEach(u.breakdowns) { b in
                let shown = b.rows.filter { $0.percent > 0 }
                if !shown.isEmpty {
                    (Text(b.label + ": ").foregroundStyle(.secondary) +
                     Text(shown.map { "\($0.name) \(Fmt.percent($0.percent))" }.joined(separator: " · ")))
                        .font(.caption)
                        .help("Where this window's usage went, as reported by claude.ai. Products at 0% are hidden (\(b.rows.filter { $0.percent == 0 }.map(\.name).joined(separator: ", "))). The per-chat stats below only cover claude.ai chats, not Claude Code or Cowork.")
                }
            }
        } else if model.status == .loading {
            HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func chatsSection(now: Date) -> some View {
        HStack {
            Text("Recent chats").font(.subheadline.bold())
            Spacer()
            Text(model.hasAPIKey ? "counted via API" : "approx")
                .font(.caption2).foregroundStyle(.secondary)
                .help(model.hasAPIKey
                      ? "Token counts come from Anthropic's /v1/messages/count_tokens using your API key."
                      : "No API key set: counts use a local approximation of Claude's tokenizer. Add a key in Settings for exact counts.")
        }
        if let note = model.chatsNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.chats) { c in
                    ChatRow(stats: c, now: now, sessionCap: UsageMath.sessionCap(tier: model.tier, now: now, config: model.config),
                            usage: model.usage, tier: model.tier, config: model.config)
                }
                if !model.chats.isEmpty {
                    Text("Never counted: " + ConversationAnalyzer.neverCounted.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func notice(_ text: String, action: String, _ run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).foregroundStyle(.secondary)
            Button(action, action: run)
        }
    }

    /// "Safe to start a big task?" in one line: where the current rate lands before each reset.
    @ViewBuilder private func paceHeadline(now: Date) -> some View {
        let lines: [(String, Color)] = (model.usage?.windows ?? []).filter { $0.id == "session" || $0.id == "weekly_all" }.compactMap { w in
            guard let p = w.pace(now: now), let reset = w.resetsAt else { return nil }
            let name = w.id == "session" ? "5-hour" : "weekly"
            if w.percent >= 100 { return ("\(name.capitalized) limit reached. Resets \(Fmt.clock(reset)).", .red) }
            if let hit = p.hitsLimitAt, hit < reset {
                return ("At this pace you'll hit the \(name) limit around \(Fmt.clock(hit)), \(Fmt.countdown(to: reset, now: hit)) before it resets.", .orange)
            }
            return ("At this pace you'll end the \(name) window around \(Fmt.percent(min(100, p.projectedPercent))). Room for a big task.", .green)
        }
        ForEach(lines, id: \.0) { l in
            Label(l.0, systemImage: l.1 == .green ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(l.1).fixedSize(horizontal: false, vertical: true)
                .help("Linear projection of your rate so far in this window. It assumes you keep going at the same rate.")
        }
        if UsageMath.isPeak(now, config: model.config) {
            Label("Peak hours now (\(EfficiencyAnalyzer.peakHoursLocal(model.config))): the 5-hour limit is tighter, so the same work uses more of it.",
                  systemImage: "sun.max").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .help("Peak hours as observed by the Claude Usage Extension's author: weekdays \(model.config.peakHours.startHourUTC):00–\(model.config.peakHours.endHourUTC):00 UTC, with roughly a 1.5× tighter 5-hour limit. Not officially published.")
        }
        if let (s, v) = model.currentEfficiency, let v, v.kind == .tighter {
            Button { model.detailsTab = "efficiency"; WindowManager.shared.showDetails(model: model) } label: {
                Label("Decreased limits? This window you're getting about \(Int(((1 - v.ratio) * 100).rounded()))% less work per 1% than your normal\(s.mostlyPeak && !v.comparedWithPeak ? " (mostly peak hours)" : "").",
                      systemImage: "chart.line.downtrend.xyaxis")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .help(EfficiencyAnalyzer.explain(s, verdict: v, config: model.config))
        }
    }

    @ViewBuilder private var powerLine: some View {
        if PowerManager.shared.claudeWorking, settings.awakeWhileClaudeWorks || settings.lidClosedWhileClaudeWorks {
            Label(PowerManager.shared.lidModeActive ? "Claude Code is working: Mac stays on, even with the lid closed"
                                                    : "Claude Code is working: Mac won't idle-sleep",
                  systemImage: PowerManager.shared.lidModeActive ? "laptopcomputer" : "cup.and.saucer")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var scheduledLine: some View {
        if let next = scheduler.active.min(by: { ($0.fireAt ?? .distantFuture) < ($1.fireAt ?? .distantFuture) }) {
            Button { model.detailsTab = "schedule"; WindowManager.shared.showDetails(model: model) } label: {
                Label("\(scheduler.active.count == 1 ? "Message" : "\(scheduler.active.count) messages") for \(next.conversationName): \(scheduler.describe(next))" +
                      (scheduler.keepingAwake ? " · keeping Mac awake" : ""), systemImage: "clock")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var claudeCodeSection: some View {
        HStack {
            Text("Claude Code this 5-hour window").font(.subheadline.bold())
            Spacer()
            Button("Details…") { model.detailsTab = "code"; WindowManager.shared.showDetails(model: model) }
                .buttonStyle(.borderless).font(.caption)
        }
        if model.codeSession.isEmpty {
            Text("No Claude Code activity in this window.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(model.codeSession.prefix(3)) { p in
            HStack {
                Text(p.name).font(.caption).lineLimit(1).frame(width: 130, alignment: .leading).help(p.path)
                UsageBar(percent: p.share, level: .low)
                Text(Fmt.percent(p.share)).font(.caption).monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            .help("\(Fmt.tokens(p.tokens)) tokens in \(p.sessions) session(s). Share = this project's part of your Claude Code usage in this window, weighted by API price ratios.")
        }
        if !model.codeWeek.isEmpty {
            Text("This week: " + model.codeWeek.prefix(3).map { "\($0.name) \(Fmt.percent($0.share))" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { WindowManager.shared.showSettings(model: model) }
            Button("History") { model.detailsTab = "history"; WindowManager.shared.showDetails(model: model) }
            Button("Efficiency") { model.detailsTab = "efficiency"; WindowManager.shared.showDetails(model: model) }
            Button("Schedule…") { model.detailsTab = "schedule"; WindowManager.shared.showDetails(model: model) }
                .help("Queue a message to send to a chat after a limit resets.")
            Spacer()
            Button("Open claude.ai") { NSWorkspace.shared.open(URL(string: model.config.baseURL)!) }
                .help("Opens claude.ai in your default browser.")
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

struct UsageBar: View {
    var percent: Double
    var level: UsageLevel
    var marker: Double? = nil

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level.color).frame(width: g.size.width * min(1, max(0, percent / 100)))
                if let m = marker, m > percent {
                    Rectangle().fill(level.color.opacity(0.5))
                        .frame(width: 2).offset(x: g.size.width * min(1, m / 100) - 1)
                }
            }
        }
        .frame(height: 6)
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let tier: Tier
    let config: AppConfig
    let now: Date

    var body: some View {
        let pace = window.pace(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.callout)
                Spacer()
                Text(Fmt.percent(window.percent)).font(.callout.monospacedDigit().bold())
                    .foregroundStyle(window.level.color)
                    .help(percentHelp)
            }
            UsageBar(percent: window.percent, level: window.level, marker: pace.map { min($0.projectedPercent, 100) })
                .help(percentHelp)
            HStack(spacing: 10) {
                if window.resetsAt != nil {
                    Label(Fmt.countdown(to: window.resetsAt, now: now), systemImage: "timer")
                        .help("Resets at \(window.resetsAt.map(Fmt.clock) ?? "–") (time left until this window starts over).")
                }
                if let p = pace {
                    Text("Pace \(Fmt.percent(p.projectedPercent))")
                        .foregroundStyle(UsageLevel.of(p.projectedPercent).color)
                        .help(paceHelp(p))
                    if let hit = p.hitsLimitAt {
                        Text("hits 100% ~\(Fmt.clock(hit))").foregroundStyle(.red)
                            .help("At the current rate this window runs out before it resets.")
                    }
                } else if window.windowLength == nil {
                    Text("no pace").foregroundStyle(.tertiary)
                        .help("This window's length isn't known, so there's no projection.")
                }
                if window.exceeded { Text("limit reached").foregroundStyle(.red) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var percentHelp: String {
        var s = "\(Fmt.percent(window.percent)) of this limit used, as reported by claude.ai."
        if let cap = UsageMath.cap(for: window, tier: tier, now: now, config: config) {
            let used = Int(window.percent / 100 * cap)
            s += "\nRough estimate: \(Fmt.compact(used)) of ~\(Fmt.compact(Int(cap))) input-token equivalents. The cap is a community guess, not an official figure."
            if window.capKey == "session", UsageMath.isPeak(now, config: config) { s += "\nPeak hours: the session cap is assumed to be lower right now." }
        }
        return s
    }

    private func paceHelp(_ p: Pace) -> String {
        "Linear projection: if you keep using Claude at the same rate as so far in this window (\(Int(p.elapsedFraction * 100))% elapsed), you'll be at \(Fmt.percent(p.projectedPercent)) when it resets. Above 100% means you'd run out first."
    }
}

struct ExtraRow: View {
    let extra: ExtraUsage
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Extra usage").font(.callout)
                Spacer()
                Text(String(format: "$%.2f / $%.2f", Double(extra.usedCents) / 100, Double(extra.effectiveTotalCents) / 100))
                    .font(.callout.monospacedDigit())
                    .help("Extra usage spent this month, against what can still be spent (the lower of your monthly limit and your prepaid credit balance).")
            }
            UsageBar(percent: extra.percent, level: UsageLevel.of(extra.percent))
        }
    }
}

struct ChatRow: View {
    let stats: ConversationStats
    let now: Date
    let sessionCap: Double?
    let usage: UsageSnapshot?
    let tier: Tier
    let config: AppConfig
    @State private var expanded = false

    var body: some View {
        let cost = stats.weightedNextCost(now: now)
        let cached = stats.isCached(now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(stats.name).font(.callout).lineLimit(1)
                Spacer()
                if let m = stats.modelVersion {
                    Text(shortModel(m)).font(.caption2).foregroundStyle(.secondary)
                        .help("Model this conversation uses (\(m)); costs are weighted ×\(String(format: "%g", stats.weight)) for it.")
                }
            }
            HStack(spacing: 10) {
                Text("\(Fmt.compact(stats.length))\(stats.lengthIsApprox ? "*" : "") tok")
                    .foregroundStyle(lengthColor)
                    .help(lengthHelp)
                Text("next ≈ \(Fmt.compact(cost))")
                    .foregroundStyle(cached ? .green : .primary)
                    .help(costHelp(cost: cost, cached: cached))
                if let cap = sessionCap, cap > 0 {
                    Text("\(Fmt.percent(Double(cost) / cap * 100)) of 5h")
                        .help("Estimated share of your 5-hour budget one more message here would use, against a guessed cap of ~\(Fmt.compact(Int(cap))) for the \(tier.displayName) plan. Treat it as a rough guide.")
                }
                if cached, let until = stats.cachedUntil {
                    Text("cached \(Fmt.countdown(to: until, now: now))").foregroundStyle(.green)
                        .help("The conversation prefix is assumed to stay in claude.ai's prompt cache for an hour after the last reply. Follow-ups until then are much cheaper.")
                }
            }
            .font(.caption.monospacedDigit())
            if let left = usage.flatMap({ UsageMath.messagesLeft($0, tier: tier, messageCost: Double(cost), now: now, config: config) }) {
                Text("≈ \(left.messages >= 1000 ? "1000+" : String(Int(left.messages))) more messages like this before \(windowName(left.windowId)) runs out")
                    .font(.caption2).foregroundStyle(left.messages < 15 ? .red : .secondary)
                    .help("Remaining estimated budget of the tightest limit, divided by this chat's next-message cost. Uses guessed caps, so it's an estimate.")
            }
            DisclosureGroup(isExpanded: $expanded) { breakdown } label: {
                Text("Breakdown").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(stats.breakdown.items.filter { $0.tokens > 0 }, id: \.label) { item in
                HStack {
                    Text(item.label)
                    Spacer()
                    Text(Fmt.tokens(item.tokens)).monospacedDigit()
                }
                .help(item.help)
            }
            if stats.outputSurcharge > 0 {
                HStack {
                    Text("Reply output (cost only)")
                    Spacer()
                    Text(Fmt.tokens(stats.outputSurcharge)).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .help("The last reply priced again at ×\(String(format: "%g", config.tokens.outputMultiplier)) (output costs more than input). It's part of the cost estimate, not the context length.")
            }
            if let w = stats.contextWindow {
                Text("Context window: \(Fmt.compact(w))\(stats.compactAt.map { ", compacts at ~\(Fmt.compact($0))" } ?? "")")
                    .foregroundStyle(.secondary)
                    .help(stats.workspaceUpgraded ? "This chat runs in a workspace, where the window can differ from a regular chat's." : "The model's context window in a regular chat.")
            }
            ForEach(stats.estimateReasons, id: \.self) { r in
                Text("* " + r).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !stats.countsExact {
                Text(stats.estimateReasons.isEmpty ? "* Approximate token counts (local estimate)." : "* Token counts are local estimates.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    private var lengthColor: Color {
        guard let w = stats.contextWindow else { return .primary }
        return Double(stats.length) >= Double(w) * 0.75 ? .red : .primary
    }

    private var lengthHelp: String {
        var s = "Context length: \(Fmt.tokens(stats.length)) tokens, everything sent with the next message (open Breakdown for the sources)."
        if stats.lengthIsApprox { s += "\n* Approximate: " + (stats.estimateReasons.first ?? "local token estimate.") }
        if let w = stats.contextWindow { s += "\nTurns red at 75% of the \(Fmt.compact(w)) context window." }
        return s
    }

    private func costHelp(cost: Int, cached: Bool) -> String {
        "Estimated cost of the next message, in input-token equivalents weighted by model price (×\(String(format: "%g", stats.weight))). Includes the reply's output at ×\(String(format: "%g", config.tokens.outputMultiplier)).\n" +
        (cached ? "Green: the cache is warm, so the cached prefix is treated as free." : "The cache is cold, so the whole context is priced.") +
        "\nUncached this would be ≈ \(Fmt.compact(Int(Double(stats.nextCostUncached) * stats.weight)))."
    }

    private func windowName(_ id: String) -> String {
        usage?.windows.first { $0.id == id }?.label ?? id
    }

    private func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var log: DebugLog
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var desktopStatus = ""

    var body: some View {
        Form {
            Section("Refresh") {
                Stepper(value: $settings.refreshSeconds, in: 60...3600, step: 30) {
                    Text("Every \(settings.refreshSeconds) seconds")
                }
                .help("claude.ai is polled at most once a minute. Errors back off exponentially (up to 15 minutes). Polling pauses while the Mac sleeps or the screen is locked.")
                Stepper(value: $settings.recentChats, in: 0...20) {
                    Text(settings.recentChats == 0 ? "Per-chat stats off" : "Analyze the \(settings.recentChats) most recent chats")
                }
                .help("Each chat's message tree is fetched again only when it changes.")
            }
            Section("Menu bar") {
                Toggle("Show percentage next to the dot", isOn: $settings.showPercentInMenuBar)
                StartAtLoginRow(item: LoginItem.shared)
                Toggle("Open with \(GlobalHotkey.display) from anywhere", isOn: $settings.globalShortcut)
                    .onChange(of: settings.globalShortcut) { _, on in GlobalHotkey.shared.setEnabled(on) }
                Toggle("Show Claude Code usage by project (reads ~/.claude/projects locally)", isOn: $settings.showClaudeCode)
                    .onChange(of: settings.showClaudeCode) { _, on in if on { model.scanClaudeCode() } }
                Toggle("Keep the Mac awake while a scheduled message is waiting", isOn: $settings.keepAwakeForScheduled)
                    .onChange(of: settings.keepAwakeForScheduled) { _, _ in model.scheduler.settingsChanged() }
            }
            PowerSection(power: PowerManager.shared)
            BackupSection(backup: BackupManager.shared)
            Section("Notifications") {
                TextField("Warning thresholds (%)", text: $settings.thresholdsText)
                    .help("Comma-separated, e.g. 80, 95. One notification per threshold per window per reset period.")
                Toggle("Warn at those thresholds", isOn: $settings.thresholdNotifications)
                Toggle("Notify when the 5-hour limit resets", isOn: $settings.notifyReset)
                Toggle("…only if I reached a warning threshold in that window", isOn: $settings.resetOnlyAfterWarning)
                    .disabled(!settings.notifyReset)
                NotificationPermissionRow(notifier: model.notifier)
            }
            Section("Anthropic API key (optional, for exact counts)") {
                Text(model.hasAPIKey ? "A key is stored in the Keychain." : "No key: token counts are local estimates, marked approx.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("sk-ant-…", text: $apiKey)
                HStack {
                    Button("Test") { Task { keyStatus = await model.testAPIKey(apiKey) } }.disabled(apiKey.isEmpty)
                    Button("Save") {
                        guard apiKey.hasPrefix("sk-ant") else { keyStatus = "That doesn't look like an Anthropic key (sk-ant-…)."; return }
                        model.setAPIKey(apiKey); apiKey = ""; keyStatus = "Saved."
                    }
                    .disabled(apiKey.isEmpty)
                    Button("Remove", role: .destructive) { model.setAPIKey(nil); keyStatus = "Removed." }.disabled(!model.hasAPIKey)
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption) }
                Text("The key is only sent to api.anthropic.com (count_tokens, which is free). Message text from your recent chats is sent there to be counted.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Account") {
                HStack {
                    Text(model.status == .loggedOut ? "Not logged in" : "Logged in\(model.account?.orgName.map { " – \($0)" } ?? "")")
                    Spacer()
                    if model.status == .loggedOut || model.status == .sessionExpired {
                        Button("Log in…") { WindowManager.shared.showLogin(model: model) }
                    } else {
                        Button("Log out", role: .destructive) { model.logout() }
                    }
                }
                if model.usingWebTransport {
                    Text("claude.ai served a browser check to plain requests, so the app is fetching through WebKit.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Claude Desktop") {
                Toggle("After a Claude Desktop update, check whether debugging is still blocked", isOn: $settings.checkDesktopUpdates)
                    .help("Runs Claude once with --remote-debugging-port on a throwaway profile and checks that it refuses to start (see FEASIBILITY.md). Your running Claude isn't touched.")
                HStack {
                    Button("Check now") {
                        desktopStatus = "Checking…"
                        Task { desktopStatus = await model.checkDesktop(force: true) }
                    }
                    if !desktopStatus.isEmpty { Text(desktopStatus).font(.caption) }
                }
            }
            Section("Debug") {
                HStack {
                    Button("Copy log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.lines.joined(separator: "\n"), forType: .string)
                    }
                    Button("Clear") { log.clear() }
                    Button("Save last /usage response") {
                        if let url = model.saveUsageSample() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .help("Writes the raw /usage JSON (percentages and reset times only) to a file, to use as a test fixture.")
                    Button("Open config folder") { NSWorkspace.shared.open(AppPaths.support) }
                        .help("endpoints.default.json is the built-in config. Copy it to endpoints.json and edit it to override paths or constants; restart the app.")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).id(i)
                            }
                        }
                    }
                    .frame(height: 180)
                    .onChange(of: log.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

struct NotificationPermissionRow: View {
    @ObservedObject var notifier: Notifier

    var body: some View {
        Group {
            if !notifier.available {
                Text("Notifications only work from the bundled .app (not `swift run`).").font(.caption).foregroundStyle(.orange)
            } else if notifier.allowed == false {
                HStack {
                    Text("macOS is blocking notifications for Claude Usage.").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Notification Settings") { NSWorkspace.shared.open(Notifier.systemSettingsURL) }
                }
            }
        }
        .onAppear { notifier.refreshPermission() }
    }
}

struct StartAtLoginRow: View {
    @ObservedObject var item: LoginItem

    var body: some View {
        Toggle("Start Claude Usage when I log in", isOn: Binding(get: { item.enabled || item.needsApproval },
                                                               set: { item.set($0) }))
            .help("Listed under System Settings → General → Login Items.")
            .onAppear { item.refresh() }
        if item.needsApproval {
            HStack {
                Text("macOS needs you to allow it in Login Items.").foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let err = item.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }
}

struct PowerSection: View {
    @ObservedObject var power: PowerManager
    @EnvironmentObject var settings: SettingsStore
    @State private var helperStatus = ""

    var body: some View {
        Section("While Claude Code is working") {
            Toggle("Keep the Mac awake (no idle sleep; the display can still turn off)", isOn: $settings.awakeWhileClaudeWorks)
            Toggle("Keep running with the lid closed", isOn: $settings.lidClosedWhileClaudeWorks)
                .help("macOS always sleeps on lid close unless sleep is disabled system-wide (pmset disablesleep). The app does that only while Claude Code is working and undoes it when it stops.")
            if settings.lidClosedWhileClaudeWorks {
                if !power.helperInstalled {
                    HStack {
                        Text("Needs a one-time setup with your admin password.").foregroundStyle(.orange)
                        Spacer()
                        Button("Set up…") { helperStatus = power.installHelper() }
                    }
                    Text("Installs \(PowerManager.sudoersPath): one line that lets this Mac user run only `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password. Nothing else.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("Only on the power adapter", isOn: $settings.lidOnlyOnPower)
                    Stepper("On battery, stop below \(settings.lidBatteryFloor)%", value: $settings.lidBatteryFloor, in: 5...80, step: 5)
                    Stepper("Stop after \(settings.lidMaxHours) hours at most", value: $settings.lidMaxHours, in: 1...24)
                    HStack {
                        Text(power.lidModeActive ? "On now: closing the lid won't sleep the Mac." : "Ready: turns on when Claude Code starts working.")
                            .foregroundStyle(power.lidModeActive ? .orange : .secondary)
                        Spacer()
                        Button("Remove setup…") { helperStatus = power.removeHelper(); settings.lidClosedWhileClaudeWorks = false }
                    }
                    Text("A closed laptop gets warmer: don't run it in a bag. Sleep is turned back on when Claude Code has been idle for 3 minutes, when this app quits or restarts, at the battery floor, or at the time limit.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !helperStatus.isEmpty { Text(helperStatus).font(.caption) }
            if let n = power.lastNote { Text(n).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct BackupSection: View {
    @ObservedObject var backup: BackupManager

    var body: some View {
        Section("Backup") {
            Picker("Back up to", selection: Binding(get: { backup.path ?? "" }, set: { backup.path = $0.isEmpty ? nil : $0 })) {
                Text("Not set").tag("")
                ForEach(backup.destinations) { d in Text(d.name).tag(d.path) }
                if let p = backup.path, !backup.destinations.contains(where: { $0.path == p }) {
                    Text((p as NSString).abbreviatingWithTildeInPath).tag(p)
                }
            }
            .help("Google Drive, Dropbox, OneDrive, Box and iCloud Drive appear here when their Mac app is installed. Their app uploads the backup; this app never connects to them.")
            HStack {
                Button("Other folder…") { backup.chooseFolder() }
                Spacer()
                Button("Back up now") { Task { await backup.backupNow() } }.disabled(backup.path == nil || backup.working)
                Button("Restore…") { backup.restore() }
            }
            Toggle("Back up automatically once a day", isOn: $backup.automatic)
            Toggle("Include queued messages (their text)", isOn: $backup.includeQueue)
            Text("Backs up usage history, efficiency, settings\(backup.includeQueue ? ", the message queue" : "") and any endpoints.json. Never your claude.ai login or API key (those stay in the Keychain). Keeps the last \(Backup.keepSnapshots) days. Restoring merges with what's here and never re-sends queued messages.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let s = backup.status { Text(s).font(.caption) }
            else if let last = backup.lastBackup { Text("Last backup: \(Fmt.clock(last))").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { backup.refreshDestinations() }
    }
}
