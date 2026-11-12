import Foundation

/// Watching a scheduled Claude Code run while it happens: the stream-json events of a headless run,
/// the session log of a run in a Terminal window, and launching that Terminal run safely.

// MARK: Live transcript lines

public struct CodeLiveLine: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case text, tool, error, info }
    public var id = UUID()
    public var kind: Kind
    public var text: String
    public var time: Date
    public init(_ kind: Kind, _ text: String, time: Date = Date()) { self.kind = kind; self.text = text; self.time = time }
    public static func == (a: Self, b: Self) -> Bool { a.kind == b.kind && a.text == b.text }
}

/// One line of `claude -p --output-format stream-json --verbose`.
public struct CodeStreamEvent: Equatable, Sendable {
    public var lines: [CodeLiveLine] = []
    public var sessionId: String?
    /// Set when Claude Code reports the plan's limit as reached ("rejected"), with when it resets.
    public var limitRejected = false
    public var limitResetsAt: Date?
    public var isResult = false

    public static func parse(line: String, now: Date = Date()) -> CodeStreamEvent? {
        guard let json = try? JSON.parse(line) else { return nil }
        var e = CodeStreamEvent()
        e.sessionId = json["session_id"].string
        switch json["type"].string {
        case "system" where json["subtype"].string == "init":
            e.lines.append(CodeLiveLine(.info, "Started Claude Code (\(json["model"].string ?? "default model"))", time: now))
        case "assistant":
            let m = json["message"]
            if json["isApiErrorMessage"].bool == true || json["error"].string != nil {
                let t = m["content"][0]["text"].string ?? "API error"
                e.lines.append(CodeLiveLine(.error, t, time: now))
            }
            for block in m["content"].arrayOrEmpty where json["isApiErrorMessage"].bool != true {
                switch block["type"].string {
                case "text":
                    let t = (block["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { e.lines.append(CodeLiveLine(.text, t, time: now)) }
                case "tool_use":
                    e.lines.append(CodeLiveLine(.tool, toolSummary(name: block["name"].string ?? "tool", input: block["input"]), time: now))
                default: break
                }
            }
        case "user":
            for block in json["message"]["content"].arrayOrEmpty where block["type"].string == "tool_result" && block["is_error"].bool == true {
                let raw = block["content"].string ?? block["content"][0]["text"].string ?? "Tool error"
                e.lines.append(CodeLiveLine(.error, String(raw.prefix(200)), time: now))
            }
        case "rate_limit_event":
            let info = json["rate_limit_info"]
            if info["status"].string == "rejected" {
                e.limitRejected = true
                e.limitResetsAt = info["resetsAt"].number.map { Date(timeIntervalSince1970: $0) }
                e.lines.append(CodeLiveLine(.error, "Usage limit reached" + (e.limitResetsAt.map { " (resets \(Self.clock($0)))" } ?? ""), time: now))
            }
        case "result":
            e.isResult = true
            let ok = json["is_error"].bool == false || json["subtype"].string == "success"
            e.lines.append(CodeLiveLine(ok ? .info : .error, ok ? "Finished" : "Stopped: \(String((json["result"].string ?? json["subtype"].string ?? "error").prefix(200)))", time: now))
        default:
            return e.sessionId == nil ? nil : e
        }
        return e
    }

    /// "Edit index.html", "Bash: npm run build", "Read styles.css".
    public static func toolSummary(name: String, input: JSON) -> String {
        if let p = input["file_path"].string ?? input["notebook_path"].string ?? input["path"].string {
            return "\(name) \((p as NSString).lastPathComponent)"
        }
        for key in ["command", "description", "pattern", "url", "query", "prompt"] {
            if let s = input[key].string {
                let one = s.replacingOccurrences(of: "\n", with: " ")
                return "\(name): \(one.count > 90 ? String(one.prefix(90)) + "…" : one)"
            }
        }
        return name
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }
}

// MARK: Limit reset time from Claude Code's message

extension CodeRunResult {
    /// "You've hit your session limit · resets 5:30am (America/New_York)" → the next 5:30 AM in that
    /// time zone after `now`. Also handles "resets 12pm" and an optional weekday/date before the time
    /// by taking the next matching time (which is right for a session limit, early for a weekly one;
    /// the retry then simply finds the limit still reached and waits again).
    public static func resetFromText(_ text: String, now: Date = Date()) -> Date? {
        let pattern = #"resets\s+(?:[A-Za-z]{3,9},?\s+)?(?:[A-Za-z]{3,9}\s+\d{1,2},?\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)(?:\s*\(([^)]+)\))?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
        guard var hour = g(1).flatMap(Int.init), hour >= 1, hour <= 12 else { return nil }
        let minute = g(2).flatMap(Int.init) ?? 0
        let pm = g(3)?.lowercased() == "pm"
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = g(4).flatMap(TimeZone.init(identifier:)) ?? .current
        return cal.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
    }
}

// MARK: Session log (for runs in a Terminal window)

public enum SessionTurn: Equatable, Sendable {
    case notStarted
    case working
    case finished(text: String)
    case limited(resetsAt: Date?, text: String)

    /// Looks at session-log lines written since the run started. Our prompt must have been recorded
    /// (`marker` = the start of what we sent); after it, the last main-thread message decides:
    /// a usage-limit error → limited; an assistant message that ended its turn → finished.
    /// The caller also waits for the file to go quiet before trusting "finished".
    public static func evaluate(lines: [String], marker: String) -> SessionTurn {
        let needle = String(marker.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        var started = false
        var last: JSON?
        for line in lines {
            guard let j = try? JSON.parse(line), j["isSidechain"].bool != true else { continue }
            let type = j["type"].string
            if type == "user", !started {
                let c = j["message"]["content"]
                let text = c.string ?? c.arrayOrEmpty.compactMap { $0["text"].string }.joined(separator: "\n")
                if needle.isEmpty || text.contains(needle) { started = true; last = nil; continue }
            }
            if started, type == "user" || type == "assistant" { last = j }
        }
        guard started else { return .notStarted }
        guard let l = last, l["type"].string == "assistant" else { return .working }
        let text = l["message"]["content"].arrayOrEmpty.compactMap { $0["text"].string }.joined(separator: "\n")
        if l["apiError"].string == "usage_limit_reached" || (l["isApiErrorMessage"].bool == true && l["apiErrorStatus"].int == 429) {
            let secs = l["apiErrorParams"]["rate_limit_info"]["resetsAt"].number ?? l["quotaLimits"]["resetsAt"].number
            return .limited(resetsAt: secs.map { Date(timeIntervalSince1970: $0) } ?? CodeRunResult.resetFromText(text), text: text)
        }
        if l["message"]["stop_reason"].string == "end_turn" || l["isApiErrorMessage"].bool == true { return .finished(text: text) }
        return .working
    }

    /// Where Claude Code keeps a session's log: ~/.claude/projects/<folder>/<sessionId>.jsonl.
    public static func logFile(sessionId: String, home: String = NSHomeDirectory()) -> URL? {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy.map { $0.appendingPathComponent(sessionId + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: Launching

extension CodeCommand {
    /// Which session a run writes to.
    public enum SessionMode: Equatable, Sendable {
        case resume(String)
        case new(String)
        /// A copy of `from` with its whole history, under a new ID. Used when the session is open in
        /// the Claude app, which doesn't show changes made to an open session from outside.
        case fork(from: String, to: String, name: String)

        public var id: String {
            switch self { case .resume(let s), .new(let s): return s; case .fork(_, let to, _): return to }
        }
        public var arguments: [String] {
            switch self {
            case .resume(let s): return ["--resume", s]
            case .new(let s): return ["--session-id", s]
            case .fork(let from, let to, let name): return ["--resume", from, "--fork-session", "--session-id", to, "--name", name]
            }
        }
    }

    /// Headless run that reports progress as it goes (one JSON event per line).
    public static func streamArguments(target: ScheduledMessage.CodeTarget, session: SessionMode) -> [String] {
        ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", target.permissionMode] + session.arguments
    }

    /// True if the Claude desktop app has this session open: it runs its own `claude` for each open
    /// session (`…/Claude/claude-code/…/claude … --resume=<id>`). `commands` = `ps -axo command=` lines.
    public static func desktopHolds(sessionId: String, commands: [String]) -> Bool {
        commands.contains { c in
            (c.contains("/Claude.app/") || c.contains("Application Support/Claude/claude-code/"))
                && (c.contains("--resume=\(sessionId)") || c.contains("--resume \(sessionId)"))
        }
    }

    /// Sent instead of the original message when a run that already started is resumed after a
    /// limit reset, so the full instructions aren't pasted into the conversation again.
    public static let continuePrompt = "The usage limit has reset. Continue where you left off with the task from my scheduled message, without asking me anything first."

    /// Removes variables a Claude Code process passes to its children. If this app was started from
    /// inside a Claude Code session, they would make the scheduled run think it's a sub-session (it
    /// then doesn't save its transcript) or point it at another session's endpoints.
    public static func cleanEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { k, _ in !(k.hasPrefix("CLAUDE") || k == "ANTHROPIC_BASE_URL") }
    }

    /// Single-quotes a value for zsh/sh: nothing inside is interpreted.
    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A `.command` script for Terminal/iTerm. The message is read from `messageFile` (0600) at run
    /// time and passed after `--`, so nothing in it can become a flag or a shell command; the file
    /// is deleted once read. The script records its PID (which `exec` hands to claude).
    public static func terminalScript(claude: String, target: ScheduledMessage.CodeTarget, session: SessionMode,
                                      messageFile: String, pidFile: String, title: String) -> String {
        let q = shellQuote
        return """
        #!/bin/zsh
        # Scheduled by Claude Usage. Safe to close this window once Claude Code has finished.
        for v in ${(k)parameters[(I)CLAUDE*]}; do unset $v; done
        unset ANTHROPIC_BASE_URL
        printf '\\e]0;%s\\a' \(q(title))
        cd -- \(q(target.projectPath)) || { echo "Project folder not found."; exit 1; }
        echo $$ > \(q(pidFile))
        prompt="$(cat -- \(q(messageFile)))"
        rm -f -- \(q(messageFile))
        exec \(q(claude)) --permission-mode \(q(target.permissionMode)) \(session.arguments.map(q).joined(separator: " ")) -- "$prompt"

        """
    }
}
