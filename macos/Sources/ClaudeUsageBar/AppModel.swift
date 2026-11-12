import AppKit
import Foundation
import UsageCore

@MainActor final class AppModel: ObservableObject {
    enum Status: Equatable { case loggedOut, loading, ok, error(String), sessionExpired }

    let config: AppConfig
    let settings = SettingsStore()
    let log = DebugLog.shared
    let web: WebSession
    let notifier: Notifier
    private var transport: HybridTransport!

    @Published private(set) var status: Status = .loading
    @Published private(set) var account: AccountInfo?
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var chats: [ConversationStats] = []
    @Published private(set) var chatsNote: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var paused = false
    @Published private(set) var refreshing = false
    @Published private(set) var desktopNote: String?
    @Published private(set) var hasAPIKey = Keychain.get(.anthropicAPIKey) != nil
    @Published private(set) var usingWebTransport = false
    @Published private(set) var history = UsageHistory()
    @Published private(set) var codeSession: [CodeProjectUsage] = []
    @Published private(set) var codeWeek: [CodeProjectUsage] = []
    @Published private(set) var codeDay: [CodeProjectUsage] = []
    @Published var detailsTab = "history"
    /// Long-term work-per-1 % per 5-hour window (efficiency.jsonl), newest last.
    @Published private(set) var efficiency: [EfficiencySample] = []
    let scheduler = Scheduler()
    private let codeScanner = CodeLogScanner()
    private var codeScanning = false

    private var sessionKey: String?
    private var orgId: String? = UserDefaults.standard.string(forKey: "orgId")
    private var nextDue = Date()
    private var failures = 0
    private var loop: Task<Void, Never>?
    private var bootstrapAt = Date.distantPast
    private var prefs: (tokens: TokenCount, at: Date)?
    private var projects: [String: (info: ProjectInfo, at: Date)] = [:]
    private var chatCache: [String: (updatedAt: Date?, stats: ConversationStats)] = [:]
    private(set) var lastUsageRaw: JSON?

    init() {
        let loaded = ConfigLoader.load(overrideURL: AppPaths.configOverride)
        config = loaded.config
        web = WebSession(config: loaded.config, log: DebugLog.shared)
        notifier = Notifier(log: DebugLog.shared)
        transport = HybridTransport(web: web) { [weak self] in
            Task { @MainActor in
                self?.usingWebTransport = true
                self?.log.add("claude.ai returned an HTML page to URLSession (likely a Cloudflare check); switched to the WebKit transport")
            }
        }
        if let problem = loaded.problem { log.add(problem) }
        writeDefaultConfigCopy()
        loadHistory()
        efficiency = EfficiencyAnalyzer.parse((try? String(contentsOf: efficiencyFile, encoding: .utf8)) ?? "")
        scheduler.model = self
        PowerManager.shared.model = self
        scheduler.settingsChanged()
        observeSystem()
        AppDelegate.model = self
        LoginItem.shared.enableOnFirstLaunch()
        GlobalHotkey.shared.setEnabled(settings.globalShortcut)
        Task { await start() }
    }

    // MARK: Lifecycle

    private func start() async {
        log.add("Config v\(config.configVersion) loaded\(FileManager.default.fileExists(atPath: AppPaths.configOverride.path) ? " (user override)" : "")")
        if let key = Keychain.get(.sessionKey) {
            sessionKey = key
            await web.setSessionCookie(key)
            status = .loading
        } else {
            status = .loggedOut
            WindowManager.shared.showLogin(model: self)
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused, self.sessionKey != nil, self.status != .sessionExpired, Date() >= self.nextDue {
                    await self.refresh()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        Task { await checkDesktop() }
    }

    func refreshNow() { nextDue = Date() ; if status == .sessionExpired, sessionKey != nil { status = .loading } }

    /// Opening the popover counts as "looking": refresh if the data is older than the interval.
    func popoverOpened() {
        scanClaudeCode()
        if let last = lastUpdated, Date().timeIntervalSince(last) < settings.refreshInterval { return }
        if !refreshing { nextDue = Date() }
    }

    func loginCompleted(sessionKey: String, orgId: String?) {
        Keychain.set(sessionKey, for: .sessionKey)
        self.sessionKey = sessionKey
        if let orgId { self.orgId = orgId; UserDefaults.standard.set(orgId, forKey: "orgId") }
        log.add("Logged in\(orgId != nil ? " (org from cookie)" : "")")
        account = nil; bootstrapAt = .distantPast; prefs = nil; chatCache = [:]
        status = .loading
        nextDue = Date()
    }

    func logout() {
        Keychain.delete(.sessionKey)
        sessionKey = nil; orgId = nil
        UserDefaults.standard.removeObject(forKey: "orgId")
        account = nil; usage = nil; chats = []; lastUpdated = nil; chatCache = [:]
        notifier.cancelAll()
        status = .loggedOut
        Task { await web.clearAll() }
        log.add("Logged out; session removed from Keychain")
    }

    func setAPIKey(_ key: String?) {
        if let key, !key.isEmpty { Keychain.set(key, for: .anthropicAPIKey) } else { Keychain.delete(.anthropicAPIKey) }
        hasAPIKey = Keychain.get(.anthropicAPIKey) != nil
        chatCache = [:]; prefs = nil
        log.add(hasAPIKey ? "API key saved to Keychain; recounting with count_tokens" : "API key removed; using the local estimate")
        nextDue = Date()
    }

    func testAPIKey(_ key: String) async -> String {
        let c = AnthropicTokenCounter(apiKey: key, transport: URLSessionTransport(), config: config)
        switch await c.test() {
        case .success(let n): return "Key works (count_tokens answered \(n))."
        case .failure(let e): return "Key failed: \(e)"
        }
    }

    // MARK: Refresh

    private func makeClient() -> ClaudeClient? {
        guard let key = sessionKey else { return nil }
        return ClaudeClient(config: config, transport: transport, sessionKey: key)
    }

    private func refresh() async {
        guard let client = makeClient() else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            if orgId == nil {
                orgId = AccountDecoder.pickOrg(try await client.organizations())
                if let orgId { UserDefaults.standard.set(orgId, forKey: "orgId") }
            }
            guard let org = orgId else { throw ClaudeAPIError.http(status: 0, snippet: "No organization found for this account") }

            if account == nil || Date().timeIntervalSince(bootstrapAt) > 30 * 60 {
                do {
                    account = AccountDecoder.decodeBootstrap(try await client.bootstrap(org: org), orgId: org, config: config)
                    bootstrapAt = Date()
                    log.add("Account: \(account!.tier.displayName), flags \(account!.flags)")
                } catch let e as ClaudeAPIError where e.isAuthFailure {
                    throw e
                } catch {
                    log.add("Bootstrap failed (\(error)); assuming default flags")
                    if account == nil { account = AccountInfo(orgId: org, orgName: nil, tier: .free, flags: FeatureFlags()) }
                }
            }

            let raw = try await client.usage(org: org)
            lastUsageRaw = raw
            var credits: JSON? = nil
            if raw["spend"]["enabled"].bool == true || raw["extra_usage"]["is_enabled"].bool == true {
                credits = try? await client.credits(org: org)
            }
            let snap = UsageDecoder.decode(raw, credits: credits, config: config)
            if snap.isEmpty, account?.tier != .free {
                log.add("Usage response had no windows on a paid plan (format: \(snap.format.rawValue)); the endpoint may have changed")
            }
            if !snap.ignoredKeys.isEmpty { log.add("Usage keys not understood: \(snap.ignoredKeys.joined(separator: ", "))") }
            if usage == nil || usage?.windows.map(\.id) != snap.windows.map(\.id) {
                // Shape summary (keys and window ids only), logged when it changes.
                log.add("Usage: format \(snap.format.rawValue), keys [\((raw.object?.keys.sorted() ?? []).joined(separator: ", "))], windows " +
                        snap.windows.map { "\($0.id)=\(Fmt.percent($0.percent))" }.joined(separator: " ") +
                        (snap.extra != nil ? ", extra usage on" : "") + (transport.useWeb ? " [via WebKit]" : " [via URLSession]"))
            }
            saveLatestUsageSample(raw)
            usage = snap
            lastUpdated = Date()
            status = .ok
            failures = 0
            notifier.evaluate(snap, settings: settings)
            recordHistory(snap)
            scheduler.usageUpdated(snap.windows)
            scanClaudeCode()
            nextDue = Date().addingTimeInterval(settings.refreshInterval)

            await refreshChats(client: client, org: org)
        } catch let e as ClaudeAPIError where e.isAuthFailure {
            status = .sessionExpired
            log.add("Session rejected (\(e)); log in again")
            notifier.cancelAll()
        } catch {
            failures += 1
            let backoff = min(settings.refreshInterval * pow(2, Double(failures)), 15 * 60)
            nextDue = Date().addingTimeInterval(backoff)
            status = .error("\(error)")
            log.add("Refresh failed (\(failures)×): \(error). Next try in \(Int(backoff))s")
        }
    }

    private func counters(client: ClaudeClient) -> (TokenCounting, FileTokenCounting) {
        if let key = Keychain.get(.anthropicAPIKey) {
            let log = self.log
            let counter = AnthropicTokenCounter(apiKey: key, transport: URLSessionTransport(), config: config) { msg in
                Task { @MainActor in log.add(msg) }
            }
            let cache = UserDefaults.standard.dictionary(forKey: "fileTokenCache") as? [String: Int] ?? [:]
            let files = APIFileCounter(client: client, counter: counter, config: config, cache: cache) { c in
                UserDefaults.standard.set(c, forKey: "fileTokenCache")
            }
            return (counter, files)
        }
        return (LocalTokenEstimator(multiplier: config.tokens.localEstimatorMultiplier), EstimatedFileCounter(config: config))
    }

    private func refreshChats(client: ClaudeClient, org: String) async {
        let n = settings.recentChats
        guard n > 0, let account else { chats = []; chatsNote = n > 0 ? nil : "Per-chat stats are turned off in Settings."; return }
        let list: [ConversationSummary]
        do {
            list = ConversationListDecoder.decode(try await client.conversations(org: org, limit: n))
        } catch {
            chatsNote = "Couldn't list recent chats: \(error)"
            log.add(chatsNote!)
            return
        }
        let (counter, files) = counters(client: client)
        let prefsTokens = await preferencesTokens(client: client, counter: counter)
        var result: [ConversationStats] = []
        var failed = 0
        for summary in list.prefix(n) {
            if let hit = chatCache[summary.id], hit.updatedAt == summary.updatedAt, summary.updatedAt != nil {
                result.append(hit.stats); continue
            }
            do {
                let tree = try await client.tree(org: org, conversation: summary.id)
                var project: ProjectInfo? = nil
                if let pid = tree["project_uuid"].string ?? summary.projectId {
                    project = await projectInfo(client: client, org: org, project: pid)
                }
                let ctx = AnalysisContext(config: config, accountFlags: account.flags, preferencesTokens: prefsTokens,
                                          project: project, name: summary.name)
                let stats = await ConversationAnalyzer.analyze(tree: tree, context: ctx, counter: counter, fileCounter: files)
                chatCache[summary.id] = (summary.updatedAt, stats)
                result.append(stats)
            } catch {
                failed += 1
                log.add("Chat \(summary.id.prefix(8)) failed: \(error)")
            }
        }
        if result.map(\.id) != chats.map(\.id) || result != chats {
            log.add("Chats: \(result.count) of \(list.count) analyzed\(failed > 0 ? ", \(failed) failed" : "")" +
                    (result.first.map { ", newest \(Fmt.compact($0.length)) tok\($0.lengthIsApprox ? "*" : "")" } ?? ""))
        }
        chats = result
        chatsNote = failed > 0 ? "\(failed) chat(s) couldn't be loaded; see the debug log." : (list.isEmpty ? "No conversations yet." : nil)
    }

    private func preferencesTokens(client: ClaudeClient, counter: TokenCounting) async -> TokenCount {
        if let p = prefs, Date().timeIntervalSince(p.at) < 5 * 60 { return p.tokens }
        var tokens = TokenCount(0, exact: true)
        if let profile = try? await client.accountProfile(),
           let text = profile["conversation_preferences"].string, !text.isEmpty {
            let c = await counter.countText(text)
            tokens = TokenCount(c.value + config.tokens.preferencesSection, exact: c.exact)
        }
        prefs = (tokens, Date())
        return tokens
    }

    private func projectInfo(client: ClaudeClient, org: String, project: String) async -> ProjectInfo? {
        if let p = projects[project], Date().timeIntervalSince(p.at) < 5 * 60 { return p.info }
        guard let json = try? await client.projectStats(org: org, project: project) else { return projects[project]?.info }
        let info = ProjectInfo.decode(json)
        projects[project] = (info, Date())
        return info
    }

    // MARK: System events

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPaused(true, reason: "Mac going to sleep") }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPaused(false, reason: "Mac woke up") }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPaused(true, reason: "screen locked") }
        }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPaused(false, reason: "screen unlocked") }
        }
    }

    private func setPaused(_ p: Bool, reason: String) {
        guard paused != p else { return }
        paused = p
        log.add("Polling \(p ? "paused" : "resumed"): \(reason)")
        if !p {
            // Give the network a moment after wake, then refresh if due.
            nextDue = max(nextDue, Date().addingTimeInterval(5))
            if let last = lastUpdated, Date().timeIntervalSince(last) > settings.refreshInterval { nextDue = Date().addingTimeInterval(5) }
            Task { await checkDesktop() }
        }
    }

    // MARK: Claude Desktop update check

    @discardableResult
    func checkDesktop(force: Bool = false) async -> String {
        guard settings.checkDesktopUpdates || force else { return "Check is turned off." }
        guard let version = DesktopWatcher.installedVersion() else { return "Claude Desktop isn't installed in /Applications." }
        let d = UserDefaults.standard
        if !force, d.string(forKey: "desktopCheckedVersion") == version {
            desktopNote = d.string(forKey: "desktopNote"); return desktopNote ?? "Still blocked (checked for \(version))."
        }
        log.add("Claude Desktop \(version): re-running the CDP feasibility check on an isolated profile")
        let result = await DesktopWatcher.probe()
        let note: String?
        let summary: String
        switch result {
        case .stillBlocked:
            note = nil
            summary = "Claude Desktop \(version): still blocked (as expected)."
            log.add("Claude Desktop \(version): debugging switches still refused (CDP BLOCKED)")
        case .mayBeOpen(let why):
            note = "Claude Desktop \(version) may accept debugging now: \(why) The in-app overlay could be possible again."
            summary = note!
            notifier.post(id: "cdp-\(version)", title: "Claude Desktop changed", body: note!)
        case .couldNotRun(let why):
            note = nil
            summary = "Couldn't run the check: \(why)"
            log.add("Couldn't run the CDP check: \(why)")
            return summary // don't record the version, so it's retried
        }
        d.set(version, forKey: "desktopCheckedVersion")
        d.set(note, forKey: "desktopNote")
        desktopNote = note
        return summary
    }

    func saveUsageSample() -> URL? {
        guard let raw = lastUsageRaw else { return nil }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(raw) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = AppPaths.samples.appendingPathComponent("usage-\(f.string(from: Date())).json")
        try? data.write(to: url)
        log.add("Saved /usage sample to \(url.path)")
        return url
    }

    /// Always keeps the latest raw /usage response at samples/usage-latest.json (percentages, reset
    /// times and field names only; no account identifiers), so a real fixture is one copy away.
    private func saveLatestUsageSample(_ raw: JSON) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(raw) else { return }
        try? data.write(to: AppPaths.samples.appendingPathComponent("usage-latest.json"))
    }

    private func writeDefaultConfigCopy() {
        try? Data(DefaultConfigExport.json.utf8).write(to: AppPaths.configDefaultCopy)
    }

    // MARK: History

    private var historyFile: URL { AppPaths.support.appendingPathComponent("history.jsonl") }

    private func loadHistory() {
        let text = (try? String(contentsOf: historyFile, encoding: .utf8)) ?? ""
        var h = UsageHistory(points: UsageHistory.parse(text))
        if h.prune(now: Date()) { try? h.serialized().write(to: historyFile, atomically: true, encoding: .utf8) }
        history = h
    }

    private func recordHistory(_ snap: UsageSnapshot) {
        var values: [String: Double] = [:]
        var resets: [String: Date] = [:]
        for w in snap.windows {
            values[w.id] = w.percent
            if let r = w.resetsAt { resets[w.id] = r }
        }
        // Weekly split by product (used to tell Claude Code's part of the usage from Cowork/chats).
        let weeklyBreakdown = snap.breakdowns.first { $0.label.lowercased().hasPrefix("weekly") } ?? snap.breakdowns.first
        let b = weeklyBreakdown.map { Dictionary($0.rows.map { ($0.name, $0.percent) }, uniquingKeysWith: { a, _ in a }) }
        var h = history
        guard h.record(values, resets: resets.isEmpty ? nil : resets, breakdown: b, at: Date()), let p = h.points.last else { return }
        history = h
        let line = UsageHistory.line(p) + "\n"
        if let handle = try? FileHandle(forWritingTo: historyFile) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: historyFile, atomically: true, encoding: .utf8)
        }
    }

    func windowLabel(_ id: String) -> String {
        usage?.windows.first { $0.id == id }?.label ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: Claude Code logs

    var claudeCodeAvailable: Bool { codeScanner.rootExists }

    /// Reads new lines from ~/.claude/projects off the main thread, then groups by project for the
    /// current 5-hour and weekly windows (aligned with claude.ai's own reset times when known).
    func scanClaudeCode() {
        guard settings.showClaudeCode, !codeScanning, codeScanner.rootExists else { return }
        codeScanning = true
        let scanner = codeScanner, config = self.config
        let now = Date()
        let sessionStart = usage?.session.flatMap { w in w.resetsAt.map { $0.addingTimeInterval(-(w.windowLength ?? 5 * 3600)) } }
            ?? now.addingTimeInterval(-5 * 3600)
        let weekly = usage?.windows.first { $0.id == "weekly_all" }
        let weekStart = weekly.flatMap { w in w.resetsAt.map { $0.addingTimeInterval(-(w.windowLength ?? 7 * 86400)) } }
            ?? now.addingTimeInterval(-7 * 86400)
        Task.detached(priority: .utility) {
            let started = Date()
            scanner.scan(now: now)
            let s = scanner.projects(since: sessionStart, config: config)
            let w = scanner.projects(since: weekStart, config: config)
            let d = scanner.projects(since: now.addingTimeInterval(-86400), config: config)
            let took = Date().timeIntervalSince(started)
            let entries = scanner.entries(since: now.addingTimeInterval(-8 * 86400))
            await MainActor.run {
                self.updateEfficiency(entries: entries, now: now)
                if self.codeWeek.isEmpty, !w.isEmpty { self.log.add("Claude Code logs: \(w.count) project(s) this week (scan \(String(format: "%.1f", took))s)") }
                self.codeSession = s; self.codeWeek = w; self.codeDay = d
                self.codeScanning = false
            }
        }
    }

    // MARK: Efficiency

    private var efficiencyFile: URL { AppPaths.support.appendingPathComponent("efficiency.jsonl") }

    private func updateEfficiency(entries: [CodeUsageEntry], now: Date) {
        // Only windows whose whole span is still covered by the scanned logs.
        let cover = now.addingTimeInterval(-8 * 86400)
        let fresh = EfficiencyAnalyzer.samples(points: history.points(since: cover), entries: entries, config: config, now: now)
            .filter { $0.start >= cover }
        let merged = EfficiencyAnalyzer.merge(stored: efficiency, fresh: fresh)
        guard merged != efficiency else { return }
        let newlyFlagged = merged.filter { s in
            s.finished && !efficiency.contains { $0.id == s.id && $0.finished } &&
            EfficiencyAnalyzer.verdict(for: s, among: merged)?.kind == .tighter
        }
        efficiency = merged
        try? EfficiencyAnalyzer.serialize(merged).write(to: efficiencyFile, atomically: true, encoding: .utf8)
        for s in newlyFlagged {
            let v = EfficiencyAnalyzer.verdict(for: s, among: merged)
            log.add("Efficiency: window ending \(Fmt.clock(s.resetsAt)) looked tighter (ratio \(String(format: "%.2f", v?.ratio ?? 0)), peak \(Int(s.peakFraction * 100))%)")
        }
    }

    /// The current 5-hour window's sample and verdict, if it's measurable yet.
    var currentEfficiency: (EfficiencySample, EfficiencyVerdict?)? {
        guard let s = efficiency.last(where: { !$0.finished }), s.costPerPercent != nil else { return nil }
        return (s, EfficiencyAnalyzer.verdict(for: s, among: efficiency))
    }

    // MARK: Sending (used by Scheduler)

    func sendingContext() -> (ClaudeClient, String)? {
        guard let client = makeClient(), let org = orgId else { return nil }
        return (client, org)
    }

    func recentConversations(limit: Int = 30) async -> [ConversationSummary] {
        guard let (client, org) = sendingContext() else { return [] }
        do { return ConversationListDecoder.decode(try await client.conversations(org: org, limit: limit)) }
        catch { log.add("Couldn't list chats for scheduling: \(error)"); return [] }
    }

    // MARK: Derived

    var sessionWindow: UsageWindow? { usage?.session ?? usage?.windows.first }

    var tier: Tier { account?.tier ?? .free }
}
