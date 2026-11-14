import Foundation

/// A message queued to be sent into a claude.ai chat later, usually right after a limit resets.
/// Saved locally (`scheduled.json`), since the text has to survive a restart.
public struct ScheduledMessage: Codable, Identifiable, Sendable, Equatable {
    public enum Trigger: Codable, Sendable, Equatable {
        /// Shortly after this usage window resets (`windowId` as in UsageWindow.id, e.g. "session").
        case afterReset(windowId: String, label: String)
        case at(Date)
    }

    public enum State: String, Codable, Sendable {
        case waiting, sending, waitingForReply, done, failed, cancelled
        public var isActive: Bool { self == .waiting || self == .sending || self == .waitingForReply }
    }

    public var id: UUID
    public var created: Date
    /// nil = start a new chat.
    public var conversationId: String?
    public var conversationName: String
    public var text: String
    public var trigger: Trigger
    /// Resolved send time. For `afterReset` this is filled in from /usage and can move.
    public var fireAt: Date?
    public var state: State
    public var detail: String?
    public var sentAt: Date?
    public var finishedAt: Date?
    public var attempts: Int
    /// Set after a new chat is created, so a retry doesn't make a second one.
    public var createdConversationId: String?
    /// Set for a Claude Code job instead of a claude.ai chat. Optional, so older queue files still load.
    public var code: CodeTarget?
    /// Set after a Claude Code run hit the usage limit: the next try asks it to continue instead of
    /// pasting the whole message into the conversation again.
    public var continueOnRetry: Bool?

    public struct CodeTarget: Codable, Sendable, Equatable {
        public var projectPath: String
        public var projectName: String
        /// nil = start a new session in the project.
        public var sessionId: String?
        public var sessionTitle: String?
        /// `claude --permission-mode`: "dontAsk" (only already-allowed tools), "acceptEdits", or "auto".
        public var permissionMode: String
        /// The chat's own model (`claude --model`); nil = Claude Code's default.
        public var model: String?
        public init(projectPath: String, projectName: String, sessionId: String?, sessionTitle: String?, permissionMode: String, model: String? = nil) {
            self.projectPath = projectPath; self.projectName = projectName; self.sessionId = sessionId
            self.sessionTitle = sessionTitle; self.permissionMode = permissionMode; self.model = model
        }

        /// `--model <id>` when the chat's model is known and looks like a model id.
        public var modelArguments: [String] {
            guard let m = model, m.hasPrefix("claude-"), m.allSatisfy({ $0.isLetter || $0.isNumber || "-.[]_".contains($0) }) else { return [] }
            return ["--model", m]
        }
    }

    public var isClaudeCode: Bool { code != nil }

    public init(conversationId: String?, conversationName: String, text: String, trigger: Trigger,
                code: CodeTarget? = nil, now: Date = Date()) {
        id = UUID(); created = now; self.code = code
        self.conversationId = conversationId; self.conversationName = conversationName
        self.text = text; self.trigger = trigger
        state = .waiting; attempts = 0
        if case .at(let d) = trigger { fireAt = d }
    }

    public var targetConversation: String? { conversationId ?? createdConversationId }

    /// Updates `fireAt` from the latest usage windows. An `afterReset` job whose window has no reset
    /// time (no usage in that window yet) keeps its previous time, or stays unresolved.
    public mutating func resolve(windows: [UsageWindow], delay: TimeInterval, now: Date = Date()) {
        guard state == .waiting, attempts == 0, case .afterReset(let wid, _) = trigger,
              let reset = windows.first(where: { $0.id == wid })?.resetsAt else { return }
        // Once the reset moment has passed, freeze: /usage then reports the *next* window's reset.
        if let current = fireAt, current.addingTimeInterval(-delay) <= now { return }
        fireAt = reset.addingTimeInterval(delay)
    }

    public func isDue(now: Date) -> Bool { state == .waiting && (fireAt.map { $0 <= now } ?? false) }
}

public enum CodeCommand {
    /// Where the `claude` CLI usually lives (an app launched at login doesn't get the shell's PATH).
    public static func candidatePaths(home: String = NSHomeDirectory()) -> [String] {
        [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
    }

    /// "2.1.325 (Claude Code)" → [2, 1, 325].
    public static func version(fromOutput s: String) -> [Int]? {
        guard let word = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).first(where: { $0.first?.isNumber == true }) else { return nil }
        let parts = word.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    public static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The Claude desktop app keeps its own copy of Claude Code, one folder per version:
    /// …/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude.
    /// Returns the newest one (only read and run, never changed).
    public static func appBundledClaude(home: String = NSHomeDirectory()) -> (path: String, version: [Int])? {
        let root = home + "/Library/Application Support/Claude/claude-code"
        let fm = FileManager.default
        var best: (String, [Int])?
        for v in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            guard let ver = version(fromOutput: v) else { continue }
            for build in (try? fm.contentsOfDirectory(atPath: root + "/" + v)) ?? [] {
                let exe = "\(root)/\(v)/\(build)/claude.app/Contents/MacOS/claude"
                if fm.isExecutableFile(atPath: exe), best.map({ isNewer(ver, than: $0.1) }) ?? true { best = (exe, ver) }
            }
        }
        return best.map { (path: $0.0, version: $0.1) }
    }
}
