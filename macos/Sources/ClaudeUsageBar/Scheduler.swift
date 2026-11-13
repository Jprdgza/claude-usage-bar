import AppKit
import Foundation
import IOKit.pwr_mgt
import UsageCore

/// Queued messages: keeps the Mac awake while one is waiting, sends it when its time comes (usually
/// just after a limit resets) into Claude Code (`claude -p`), waits for the reply to finish, then lets go so the Mac can sleep on its normal idle timer.
@MainActor final class Scheduler: ObservableObject {
    @Published private(set) var jobs: [ScheduledMessage] = []
    @Published private(set) var keepingAwake = false
    /// What scheduled Claude Code runs are doing right now (and did last), per job. In memory only.
    @Published private(set) var live: [UUID: [CodeLiveLine]] = [:]

    weak var model: AppModel?
    let log = DebugLog.shared
    private var assertion: IOPMAssertionID = 0
    private var loop: Task<Void, Never>?
    private var running: Set<UUID> = []
    private let file = AppPaths.support.appendingPathComponent("scheduled.json")

    init(demo: Bool = false) {
        if demo { return }   // demo mode: no file, no loop
        load()
        // Anything interrupted mid-send by a quit/crash: the message may or may not have gone out.
        for i in jobs.indices where jobs[i].state == .sending || jobs[i].state == .waitingForReply {
            jobs[i].state = .failed
            jobs[i].detail = "The app quit while this was sending. Check the chat before re-queuing it."
        }
        save()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        updateAwake()
    }

    var active: [ScheduledMessage] { jobs.filter { $0.state.isActive } }

    func loadDemo(_ jobs: [ScheduledMessage]) { self.jobs = jobs }

    /// Adds jobs from a backup (as cancelled, so nothing is re-sent).
    func restore(_ backup: [ScheduledMessage]) {
        jobs = Backup.mergeQueue(local: jobs, backup: backup)
        save()
    }

    // MARK: Queue management

    func add(_ job: ScheduledMessage) {
        var j = job
        if let w = model?.usage?.windows { j.resolve(windows: w, delay: delay) }
        jobs.append(j)
        log.add("Scheduled a message for \(j.conversationName) – \(describe(j))")
        save(); updateAwake()
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .waiting else { return }
        jobs[i].state = .cancelled; jobs[i].finishedAt = Date()
        log.add("Cancelled scheduled message for \(jobs[i].conversationName)")
        save(); updateAwake()
    }

    func remove(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id }), !j.state.isActive || j.state == .waiting else { return }
        jobs.removeAll { $0.id == id }
        save(); updateAwake()
    }

    func clearFinished() { jobs.removeAll { !$0.state.isActive }; save() }

    /// Sends a waiting job right away (also how to test the whole flow).
    func sendNow(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .waiting || jobs[i].state == .failed else { return }
        jobs[i].state = .waiting; jobs[i].fireAt = Date(); jobs[i].detail = nil
        jobs[i].attempts = 0   // a manual send gets a fresh retry budget
        save(); tick()
    }

    /// Called after every /usage refresh: reset-based jobs follow the latest reset time.
    func usageUpdated(_ windows: [UsageWindow]) {
        var changed = false
        for i in jobs.indices {
            let before = jobs[i].fireAt
            jobs[i].resolve(windows: windows, delay: delay)
            if jobs[i].fireAt != before { changed = true }
        }
        if changed { save() }
    }

    private var delay: TimeInterval { model?.config.schedule.delayAfterResetSeconds ?? 60 }

    func describe(_ j: ScheduledMessage) -> String {
        switch j.trigger {
        case .afterReset(_, let label):
            return j.fireAt.map { "after the \(label) limit resets (\(Fmt.clock($0)))" } ?? "after the \(label) limit resets (time not known yet)"
        case .at(let d): return "at \(Fmt.clock(d))"
        }
    }

    // MARK: Keep awake

    /// While anything is waiting or sending, idle system sleep is blocked (the display can still
    /// sleep). Closing the lid on battery still sleeps the Mac; a job that was due then is sent on wake.
    func updateAwake() {
        // Only jobs with a known time (or already running): a reset time that's never known must not hold the Mac awake forever.
        let want = active.contains { $0.fireAt != nil || $0.state != .waiting } && (model?.settings.keepAwakeForScheduled ?? true)
        if want, assertion == 0 {
            let reason = "Claude Usage is waiting to send a scheduled message" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess {
                keepingAwake = true
                log.add("Keeping the Mac awake until the scheduled message is sent and answered")
            } else {
                assertion = 0
                log.add("Couldn't create the keep-awake assertion")
            }
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            keepingAwake = false
            log.add("Stopped keeping the Mac awake; it will sleep on its normal schedule")
        }
    }

    func settingsChanged() { updateAwake() }

    // MARK: Running

    private func tick() {
        let now = Date()
        for j in jobs where j.isDue(now: now) && !running.contains(j.id) {
            running.insert(j.id)
            Task { await run(j.id); running.remove(j.id) }
        }
    }

    func update(_ id: UUID, _ change: (inout ScheduledMessage) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i]); save()
    }

    func job(_ id: UUID) -> ScheduledMessage? { jobs.first { $0.id == id } }

    private func run(_ id: UUID) async {
        guard let j = job(id), model != nil else { return }
        let late = j.fireAt.map { Date().timeIntervalSince($0) > 5 * 60 } ?? false
        update(id) { $0.state = .sending; $0.attempts += 1; $0.detail = late ? "Sending late: the Mac was asleep at the scheduled time." : "Sending…" }
        if let code = j.code {
            await runCode(id, code)
            updateAwake()
            return
        }
        fail(id, "This build only sends to Claude Code.")
        updateAwake()
    }

    // MARK: Claude Code

    /// Runs `claude -p <message> [--resume <session>]` in the project folder and waits for it to
    /// finish (the whole task, including any tool use), then reports the result.
    private func runCode(_ id: UUID, _ target: ScheduledMessage.CodeTarget) async {
        guard let j = job(id), let model else { return }
        guard let exe = await Self.findClaude() else {
            return fail(id, "Couldn't find the claude command (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin and your shell's PATH).")
        }
        guard FileManager.default.fileExists(atPath: target.projectPath) else {
            return fail(id, "The project folder \(target.projectPath) doesn't exist any more.")
        }
        // Same limit check as for chats, when logged in to claude.ai (Claude Code shares the plan's limits).
        if case .afterReset(let wid, let label) = j.trigger, let (client, org) = model.sendingContext(),
           let raw = try? await client.usage(org: org),
           let w = UsageDecoder.decode(raw, credits: nil, config: model.config).windows.first(where: { $0.id == wid }), w.percent >= 100 {
            return retryOrFail(id, "The \(label) limit is still at \(Fmt.percent(w.percent)).", nextTry: nil)
        }
        let display = model.settings.codeRunDisplay
        let inTerminal = display == "terminal"
        await stopTerminalRun(id)   // a Terminal window left from an earlier try of this job
        // Always the chat you picked (resume only one that really exists; a new one gets an ID up front
        // so retries continue it). If the Claude app has it open, the app keeps showing what it loaded
        // until it's restarted, so the result says that.
        let exists = target.sessionId.map { SessionTurn.logFile(sessionId: $0) != nil } ?? false
        let session: CodeCommand.SessionMode = exists ? .resume(target.sessionId!) : .new(target.sessionId ?? UUID().uuidString.lowercased())
        let sessionId = session.id
        let openInApp = exists ? await Self.desktopHolds(sessionId) : false
        let continuing = exists && j.continueOnRetry == true
        let prompt = continuing ? CodeCommand.continuePrompt : j.text
        live[id] = [CodeLiveLine(.info, continuing ? "Limit reset: asking Claude Code to continue" : "Sending your message")]
        if openInApp {
            live[id, default: []].append(CodeLiveLine(.info, "This chat is open in the Claude app: press ⌘R there (View → Reload) to see the new messages"))
        }
        update(id) {
            $0.state = .waitingForReply; $0.sentAt = Date(); $0.code?.sessionId = sessionId
            $0.detail = inTerminal ? "Running in a Terminal window (\(target.projectName))…" : "Running in Claude Code (\(target.projectName))…"
        }
        let how: String
        switch session { case .new: how = "new session"; default: how = openInApp ? "resuming a session that's open in the Claude app" : "resuming a session" }
        log.add("Scheduled message: running Claude Code in \(target.projectName) (\(how))\(inTerminal ? " in Terminal" : "")")

        let timeout: TimeInterval = 4 * 3600
        if inTerminal {
            return await runInTerminal(id, target, exe: exe, session: session, prompt: prompt, timeout: timeout)
        }
        let args = CodeCommand.streamArguments(target: target, session: session)
        let (status, out, err) = await Self.runProcess(exe, args: args, stdin: prompt, cwd: target.projectPath, timeout: timeout) { [weak self] line in
            Task { @MainActor in self?.appendLive(id, line) }
        }
        let result = CodeRunResult.parse(stdout: out)

        if let r = result, r.limitHit {
            return limitReached(id, resetsAt: r.limitResetsAt)
        }
        if let r = result, r.success {
            let preview = String(r.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
            update(id) {
                $0.state = .done; $0.finishedAt = Date(); $0.continueOnRetry = nil
                if $0.code?.sessionId == nil, let sid = r.sessionId { $0.code?.sessionId = sid }   // so "Retry" continues it
                $0.detail = "Finished." + (r.permissionDenials > 0 ? " \(r.permissionDenials) action(s) needed permission and were skipped; open the session to approve them." : "")
            }
            log.add("Scheduled message: Claude Code finished in \(target.projectName)")
            if await Self.desktopHolds(sessionId) {
                update(id) { $0.detail = ($0.detail ?? "Finished.") + " " + Self.reopenHint }
            } else if display == "desktop" {
                let opened = await openSession(sessionId, in: target.projectPath)
                update(id) { $0.detail = ($0.detail ?? "Finished.") + (opened ? " Opened in the Claude app." : " Couldn't open it in the Claude app; use Open in Claude.") }
            }
            model.notifier.post(id: "sched-\(id)", title: "Claude Code finished in \(target.projectName)",
                                body: preview.isEmpty ? "Your scheduled message was run." : preview)
            model.refreshNow()
            return
        }
        let why = result?.text.prefix(300).description
            ?? (status == -1 ? "Timed out after \(Int(timeout / 3600)) hours." : "claude exited with code \(status). \(err.suffix(300))")
        fail(id, "Claude Code: \(why)")
    }

    /// The usual install locations first; otherwise ask the user's login shell (npm/nvm installs live
    /// on a PATH that apps started at login don't inherit).
    nonisolated static func findClaude() async -> String? {
        if let p = CodeCommand.candidatePaths().first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let (status, out, _) = await runProcess(shell, args: ["-lc", "command -v claude"], stdin: "", cwd: NSHomeDirectory(), timeout: 15)
        let path = out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return status == 0 && path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs a process off the main thread, collecting stdout/stderr. Returns -1 on timeout.
    nonisolated static func runProcess(_ exe: String, args: [String], stdin: String, cwd: String, timeout: TimeInterval,
                                       onLine: (@Sendable (String) -> Void)? = nil) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = CodeCommand.cleanEnvironment(ProcessInfo.processInfo.environment)
                let home = NSHomeDirectory()
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" + (env["PATH"].map { ":" + $0 } ?? "")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                let input = Pipe()
                p.standardInput = input
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async {
                    // Read as it arrives so each complete line can be shown live.
                    var pending = Data()
                    while true {
                        let d = out.fileHandleForReading.availableData
                        if d.isEmpty { break }
                        outData.append(d)
                        guard let onLine else { continue }
                        pending.append(d)
                        while let nl = pending.firstIndex(of: 10) {
                            onLine(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                            pending.removeSubrange(pending.startIndex...nl)
                        }
                    }
                    group.leave()
                }
                group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try p.run() } catch {
                    cont.resume(returning: (-2, "", "Couldn't start claude: \(error)")); return
                }
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
                var timedOut = false
                let timer = DispatchWorkItem { timedOut = true; p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                p.waitUntilExit()
                timer.cancel()
                group.wait()
                cont.resume(returning: (timedOut ? -1 : p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    func retryOrFail(_ id: UUID, _ why: String, nextTry: Date?) {
        guard let j = job(id), let cfg = model?.config.schedule else { return }
        let maxAttempts = Int(cfg.limitRetryMinutes * 60 / max(30, cfg.limitRetrySeconds)) + 1
        var next = Date().addingTimeInterval(cfg.limitRetrySeconds)
        // No reset time from Claude Code: use the reset of whichever of the plan's limits is full.
        let target = nextTry ?? model?.usage?.windows.filter { $0.percent >= 100 }.compactMap(\.resetsAt)
            .filter { $0 > Date() }.min()?.addingTimeInterval(cfg.delayAfterResetSeconds)
        if let t = target, t > next { next = t }
        // With a known reset time the try count doesn't matter (each try can be hours of work).
        // A reset more than 6 hours out is a weekly limit: don't hold the Mac awake for days.
        // (A reset time already in the past doesn't count, and 50 tries is the hard stop either way.)
        let knownReset = target.map { $0 > Date() } ?? false
        if j.attempts < maxAttempts || (knownReset && j.attempts < 50), next.timeIntervalSinceNow < 6 * 3600 {
            update(id) { $0.state = .waiting; $0.fireAt = next; $0.detail = "\(why) Trying again at \(Fmt.clock(next))." }
            log.add("Scheduled message: \(why) Retrying at \(Fmt.clock(next))")
        } else {
            fail(id, "\(why) Gave up after \(j.attempts) tries.")
        }
        updateAwake()
    }

    /// Claude Code stopped at the usage limit: wait for the reset, then ask it to continue.
    private func limitReached(_ id: UUID, resetsAt: Date?) {
        update(id) { $0.continueOnRetry = true }
        let delay = model?.config.schedule.delayAfterResetSeconds ?? 60
        retryOrFail(id, "Claude Code hit the usage limit\(resetsAt.map { " (resets \(Fmt.clock($0)))" } ?? "").",
                    nextTry: resetsAt?.addingTimeInterval(delay))
    }

    // MARK: Live view

    func appendLive(_ id: UUID, _ line: String) {
        guard let e = CodeStreamEvent.parse(line: line), !e.lines.isEmpty else { return }
        var l = live[id] ?? []
        l.append(contentsOf: e.lines)
        if l.count > 600 { l.removeFirst(l.count - 600) }
        live[id] = l
    }

    // MARK: Terminal runs

    private var runsDir: URL { AppPaths.support.appendingPathComponent("runs", isDirectory: true) }

    /// Opens Claude Code in a Terminal window with the message, then follows the session's log to
    /// see when it's done (or hit the limit). The window stays open so you can keep talking to it.
    private func runInTerminal(_ id: UUID, _ target: ScheduledMessage.CodeTarget, exe: String,
                               session: CodeCommand.SessionMode, prompt: String, timeout: TimeInterval) async {
        let sessionId = session.id
        let fm = FileManager.default
        let dir = runsDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let msg = dir.appendingPathComponent("\(id).msg"), pidFile = dir.appendingPathComponent("\(id).pid")
        let script = dir.appendingPathComponent("\(id).command")
        try? fm.removeItem(at: pidFile)
        guard fm.createFile(atPath: msg.path, contents: Data(prompt.utf8), attributes: [.posixPermissions: 0o600]) else {
            return fail(id, "Couldn't write the message file in \(dir.path).")
        }
        let body = CodeCommand.terminalScript(claude: exe, target: target, session: session,
                                              messageFile: msg.path, pidFile: pidFile.path,
                                              title: "Scheduled: \(target.sessionTitle ?? target.projectName)")
        guard fm.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return fail(id, "Couldn't open Terminal.")
        }
        // Only what's written after this point counts.
        var logURL = SessionTurn.logFile(sessionId: sessionId)
        var offset = logURL.flatMap { (try? fm.attributesOfItem(atPath: $0.path))?[.size] as? UInt64 } ?? 0
        do {
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: cfg)
        } catch {
            return fail(id, "Couldn't open Terminal: \(error.localizedDescription)")
        }
        live[id, default: []].append(CodeLiveLine(.info, "Opened in a Terminal window"))

        let started = Date()
        var lines: [String] = [], partial = Data(), lastChange = Date()
        while Date().timeIntervalSince(started) < timeout {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard job(id)?.state == .waitingForReply else { return }   // cancelled meanwhile
            if logURL == nil { logURL = SessionTurn.logFile(sessionId: sessionId); offset = 0 }
            if let url = logURL, let h = try? FileHandle(forReadingFrom: url) {
                try? h.seek(toOffset: offset)
                let data = (try? h.readToEnd()) ?? Data()
                try? h.close()
                if !data.isEmpty {
                    offset += UInt64(data.count); lastChange = Date()
                    partial.append(data)
                    while let nl = partial.firstIndex(of: 10) {
                        let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                        partial.removeSubrange(partial.startIndex...nl)
                        lines.append(line); appendLive(id, line)
                    }
                }
            }
            let alive = Self.terminalPid(pidFile).map { kill($0, 0) == 0 } ?? false
            switch SessionTurn.evaluate(lines: lines, marker: prompt) {
            case .finished(let text):
                guard Date().timeIntervalSince(lastChange) >= 15 || !alive else { continue }
                update(id) {
                    $0.state = .done; $0.finishedAt = Date(); $0.continueOnRetry = nil
                    $0.detail = "Finished. The Terminal window is still open if you want to keep going."
                }
                if await Self.desktopHolds(sessionId) { update(id) { $0.detail = ($0.detail ?? "") + " " + Self.reopenHint } }
                log.add("Scheduled message: Claude Code finished in \(target.projectName) (Terminal)")
                let preview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
                model?.notifier.post(id: "sched-\(id)", title: "Claude Code finished in \(target.projectName)",
                                     body: preview.isEmpty ? "Your scheduled message was run." : preview)
                model?.refreshNow()
                return
            case .limited(let resetsAt, _):
                return limitReached(id, resetsAt: resetsAt)   // the window is closed before the next try
            case .notStarted:
                if !alive, Date().timeIntervalSince(started) > 20 {
                    return fail(id, "Claude Code closed in Terminal before it started. Look at the Terminal window for the error.")
                }
                if Date().timeIntervalSince(started) > 180 {
                    return fail(id, "Claude Code didn't start in the Terminal window within 3 minutes (it may be asking whether you trust the folder). Answer it there, then use Retry.")
                }
            case .working:
                if !alive { return fail(id, "The Terminal window was closed before Claude Code finished.") }
            }
        }
        fail(id, "Still running after \(Int(timeout / 3600)) hours; stopped keeping the Mac awake for it. The Terminal window is still open.")
    }

    nonisolated static func terminalPid(_ file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Ends Claude Code left running in Terminal by an earlier try (so two copies never write to one
    /// session). Only a process that is really `claude` is signalled.
    private func stopTerminalRun(_ id: UUID) async {
        let pidFile = runsDir.appendingPathComponent("\(id).pid")
        guard let pid = Self.terminalPid(pidFile), kill(pid, 0) == 0 else { return }
        let (_, comm, _) = await Self.runProcess("/bin/ps", args: ["-p", "\(pid)", "-o", "comm="], stdin: "", cwd: "/", timeout: 5)
        guard (comm.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent == "claude" else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        try? FileManager.default.removeItem(at: pidFile)
        log.add("Closed Claude Code left open in Terminal from the previous try")
    }

    /// Opens the session in the Claude desktop app (`claude --desktop --resume`, which needs a terminal,
    /// so it runs under `script`). It can't send a message there, only show the conversation.
    func openInClaudeApp(_ id: UUID) {
        guard let t = job(id)?.code, let sid = t.sessionId else { return }
        Task { _ = await openSession(sid, in: t.projectPath) }
    }

    @discardableResult
    func openSession(_ sid: String, in folder: String) async -> Bool {
        guard let exe = await Self.findClaude() else { return false }
        if await Self.desktopHolds(sid) {
            log.add("Session is already open in the Claude app; press ⌘R there (View → Reload) to see new messages")
            return false
        }
        let (status, out, err) = await Self.runProcess("/usr/bin/script", args: ["-q", "/dev/null", exe, "--desktop", "--resume", sid],
                                                       stdin: "", cwd: folder, timeout: 30)
        let text = out + err
        let ok = status == 0 && text.contains("Opening session")
        log.add(ok ? "Opened the session in the Claude app" : "Couldn't open the session in the Claude app: \(text.suffix(200))")
        return ok
    }

    static let reopenHint = "The chat was open in the Claude app, which doesn't refresh it by itself: click the chat there and press ⌘R (View → Reload) to see the new messages. Don't type in that chat before you do."

    /// Whether the Claude desktop app currently has this session open.
    nonisolated static func desktopHolds(_ sid: String) async -> Bool {
        let (_, out, _) = await runProcess("/bin/ps", args: ["-axo", "command="], stdin: "", cwd: "/", timeout: 10)
        return CodeCommand.desktopHolds(sessionId: sid, commands: out.split(separator: "\n").map(String.init))
    }

    func fail(_ id: UUID, _ why: String) {
        update(id) { $0.state = .failed; $0.finishedAt = Date(); $0.detail = why }
        log.add("Scheduled message failed: \(why)")
        if let j = job(id) { model?.notifier.post(id: "sched-\(id)", title: "Scheduled message not sent", body: "\(j.conversationName): \(why)") }
        updateAwake()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        jobs = (try? d.decode([ScheduledMessage].self, from: data)) ?? []
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]
        guard let data = try? e.encode(jobs) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
