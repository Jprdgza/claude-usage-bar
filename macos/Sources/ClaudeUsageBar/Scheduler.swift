import Foundation
import IOKit.pwr_mgt
import UsageCore

/// Queued messages: keeps the Mac awake while one is waiting, sends it when its time comes (usually
/// just after a limit resets) into Claude Code (`claude -p`), waits for the reply to finish, then lets go so the Mac can sleep on its normal idle timer.
@MainActor final class Scheduler: ObservableObject {
    @Published private(set) var jobs: [ScheduledMessage] = []
    @Published private(set) var keepingAwake = false

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
        update(id) { $0.state = .waitingForReply; $0.sentAt = Date(); $0.detail = "Running in Claude Code (\(target.projectName))…" }
        log.add("Scheduled message: running Claude Code in \(target.projectName)\(target.sessionId != nil ? " (resuming a session)" : " (new session)")")

        let args = CodeCommand.arguments(target: target)
        let timeout: TimeInterval = 4 * 3600
        let (status, out, err) = await Self.runProcess(exe, args: args, stdin: j.text, cwd: target.projectPath, timeout: timeout)
        let result = CodeRunResult.parse(stdout: out)

        if let r = result, r.limitHit {
            return retryOrFail(id, "Claude Code says the usage limit is reached.", nextTry: r.limitResetsAt?.addingTimeInterval(model.config.schedule.delayAfterResetSeconds))
        }
        if let r = result, r.success {
            let preview = String(r.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
            update(id) {
                $0.state = .done; $0.finishedAt = Date()
                if $0.code?.sessionId == nil, let sid = r.sessionId { $0.code?.sessionId = sid }   // so "Retry" continues it
                $0.detail = "Finished." + (r.permissionDenials > 0 ? " \(r.permissionDenials) action(s) needed permission and were skipped; open the session to approve them." : "")
            }
            log.add("Scheduled message: Claude Code finished in \(target.projectName)")
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
    nonisolated static func runProcess(_ exe: String, args: [String], stdin: String, cwd: String, timeout: TimeInterval) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" + (env["PATH"].map { ":" + $0 } ?? "")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                let input = Pipe()
                p.standardInput = input
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
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
        if let t = nextTry, t > next { next = t }
        // A reset more than 6 hours out is a weekly limit: don't hold the Mac awake for days.
        if j.attempts < maxAttempts, next.timeIntervalSinceNow < 6 * 3600 {
            update(id) { $0.state = .waiting; $0.fireAt = next; $0.detail = "\(why) Trying again at \(Fmt.clock(next))." }
            log.add("Scheduled message: \(why) Retrying at \(Fmt.clock(next))")
        } else {
            fail(id, "\(why) Gave up after \(j.attempts) tries.")
        }
        updateAwake()
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
