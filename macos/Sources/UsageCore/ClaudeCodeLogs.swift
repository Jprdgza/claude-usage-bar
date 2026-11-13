import Foundation

/// Reads Claude Code's own session logs (`~/.claude/projects/**/*.jsonl`) to show which projects
/// use the most. Each assistant line carries the exact `usage` the API returned. Read-only and
/// local: nothing is sent anywhere, and message text is never kept (only token counts).
public struct CodeUsageEntry: Sendable, Equatable {
    public var id: String
    public var time: Date
    public var project: String      // the session's working directory
    public var sessionId: String?
    public var model: String?
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int

    public var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    /// Relative cost in input-token equivalents, using the API's published price ratios (cache write
    /// 1.25× for 5 min / 2× for 1 h, cache read 0.1×, output 5×) times the model's price weight.
    /// claude.ai doesn't say how it charges plan limits, so this is only good for comparing projects.
    public func cost(config: AppConfig) -> Double {
        let units = Double(input) + 1.25 * Double(cacheWrite5m) + 2.0 * Double(cacheWrite1h) + 0.1 * Double(cacheRead) + 5.0 * Double(output)
        return units * ConversationAnalyzer.weight(model: model, length: 0, config: config)
    }

    /// Parses one log line. Returns nil for anything that isn't an assistant message with usage.
    public static func parse(line: Substring) -> CodeUsageEntry? {
        // Cheap pre-filter: most lines are user/tool/progress lines.
        guard line.contains("\"usage\""), line.contains("\"assistant\"") else { return nil }
        return parse(json: Data(line.utf8))
    }

    /// Parses one already pre-filtered log line.
    static func parse(json data: Data) -> CodeUsageEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let id = msg["id"] as? String,
              let ts = obj["timestamp"] as? String, let time = JSON.parseISODate(ts) else { return nil }
        func n(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }
        let creation = usage["cache_creation"] as? [String: Any]
        var w5 = n(creation, "ephemeral_5m_input_tokens"), w1 = n(creation, "ephemeral_1h_input_tokens")
        if creation == nil { w5 = n(usage, "cache_creation_input_tokens") }   // older logs: one number, assume 5 min
        if w5 + w1 == 0 { w5 = n(usage, "cache_creation_input_tokens") }
        let model = msg["model"] as? String
        if model == "<synthetic>" { return nil }   // locally generated messages, not API calls
        return CodeUsageEntry(id: id, time: time, project: obj["cwd"] as? String ?? "(unknown)",
                              sessionId: obj["sessionId"] as? String, model: model,
                              input: n(usage, "input_tokens"), cacheWrite5m: w5, cacheWrite1h: w1,
                              cacheRead: n(usage, "cache_read_input_tokens"), output: n(usage, "output_tokens"))
    }
}

public struct CodeProjectUsage: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var tokens: Int
    public var output: Int
    public var cost: Double
    public var share: Double        // 0–100 of all Claude Code cost in the period
    public var sessions: Int
    public var lastActive: Date
    public var topModel: String?

    public init(path: String, name: String, tokens: Int, output: Int, cost: Double, share: Double,
                sessions: Int, lastActive: Date, topModel: String?) {
        self.path = path; self.name = name; self.tokens = tokens; self.output = output; self.cost = cost
        self.share = share; self.sessions = sessions; self.lastActive = lastActive; self.topModel = topModel
    }
}

/// Aggregation, kept separate from file I/O so it can be unit-tested.
public struct CodeUsageLedger: Sendable {
    /// Keyed by API message id: Claude Code writes one line per content block, all with the same usage.
    public private(set) var entries: [String: CodeUsageEntry] = [:]
    public init() {}

    public mutating func add(_ e: CodeUsageEntry) {
        if let old = entries[e.id] {
            // Streaming can log a partial usage first; keep the largest numbers seen.
            var m = old
            m.output = max(old.output, e.output); m.input = max(old.input, e.input)
            m.cacheRead = max(old.cacheRead, e.cacheRead)
            m.cacheWrite5m = max(old.cacheWrite5m, e.cacheWrite5m); m.cacheWrite1h = max(old.cacheWrite1h, e.cacheWrite1h)
            entries[e.id] = m
        } else {
            entries[e.id] = e
        }
    }

    public mutating func prune(before: Date) { entries = entries.filter { $0.value.time >= before } }

    public func projects(since: Date, config: AppConfig) -> [CodeProjectUsage] {
        let recent = entries.values.filter { $0.time >= since }
        let groups = Dictionary(grouping: recent, by: \.project)
        let costs = groups.mapValues { $0.reduce(0) { $0 + $1.cost(config: config) } }
        let total = costs.values.reduce(0, +)
        return groups.map { path, list in
            var models: [String: Double] = [:]
            for e in list { models[e.model ?? "?", default: 0] += e.cost(config: config) }
            return CodeProjectUsage(path: path, name: Self.displayName(path), tokens: list.reduce(0) { $0 + $1.totalTokens },
                                    output: list.reduce(0) { $0 + $1.output }, cost: costs[path] ?? 0,
                                    share: total > 0 ? (costs[path] ?? 0) / total * 100 : 0,
                                    sessions: Set(list.compactMap(\.sessionId)).count,
                                    lastActive: list.map(\.time).max() ?? since,
                                    topModel: models.max { $0.value < $1.value }?.key)
        }
        .sorted { $0.cost > $1.cost }
    }

    /// "/Users/me/MyCode" → "MyCode"; scratch workspaces get a readable name.
    public static func displayName(_ path: String) -> String {
        if path.contains("/T/") || path.hasPrefix("/private/var/folders") { return "Temporary workspace" }
        let home = NSHomeDirectory()
        if path == home { return "~ (home folder)" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Incremental reader: remembers how far it read in each file and only parses new bytes.
public final class CodeLogScanner: @unchecked Sendable {
    public let root: URL
    public private(set) var ledger = CodeUsageLedger()
    private var offsets: [String: UInt64] = [:]
    private let lock = NSLock()
    public var lookback: TimeInterval

    public init(root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
                lookback: TimeInterval = 8 * 86400) {
        self.root = root; self.lookback = lookback
    }

    public var rootExists: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// Scans new data. Safe to call often: unchanged files cost one stat each.
    public func scan(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-lookback)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate, mtime >= cutoff, let size = values.fileSize else { continue }
            let path = url.path
            var start = offsets[path] ?? 0
            if UInt64(size) < start { start = 0 }            // file was rewritten
            guard UInt64(size) > start, let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            try? h.seek(toOffset: start)
            guard let data = try? h.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            // A half-written last line waits for the next scan. Logs run to hundreds of MB (tool output),
            // so lines are found and pre-filtered as raw bytes; only candidates are decoded as JSON.
            let completeCount = lastNewline - data.startIndex + 1
            for e in Self.entries(in: data.prefix(completeCount)) where e.time >= cutoff { ledger.add(e) }
            offsets[path] = start + UInt64(completeCount)
        }
        ledger.prune(before: cutoff)
    }

    private static let usageKey = Array("\"usage\"".utf8), assistantKey = Array("\"type\":\"assistant\"".utf8)

    private static let messageIdKey = Array("\"id\":\"msg_".utf8)

    /// Usage entries in a block of complete log lines. Claude Code writes a message once per content
    /// block while streaming, with usage that only grows, so only the last line per message id is
    /// decoded (several times fewer JSON decodes on real logs, same totals).
    static func entries(in data: Data) -> [CodeUsageEntry] {
        var lastLine: [Data: Range<Int>] = [:], order: [Data] = [], noId: [Range<Int>] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            func find(_ key: [UInt8], _ from: Int, _ len: Int) -> Int? {
                key.withUnsafeBufferPointer { k in memmem(base + from, len, k.baseAddress, k.count).map { UnsafeRawPointer($0) - base } }
            }
            var pos = 0
            let end = raw.count
            while pos < end {
                let lineEnd = memchr(base + pos, 0x0A, end - pos).map { UnsafeRawPointer($0) - base } ?? end
                let len = lineEnd - pos
                if len > 0, find(usageKey, pos, len) != nil, find(assistantKey, pos, len) != nil {
                    if let idAt = find(messageIdKey, pos, len),
                       let close = memchr(base + idAt + messageIdKey.count, 0x22, lineEnd - idAt - messageIdKey.count) {
                        let id = Data(bytes: base + idAt, count: UnsafeRawPointer(close) - base - idAt)
                        if lastLine[id] == nil { order.append(id) }
                        lastLine[id] = pos..<lineEnd
                    } else {
                        noId.append(pos..<lineEnd)
                    }
                }
                pos = lineEnd + 1
            }
        }
        let ranges = order.compactMap { lastLine[$0] } + noId
        return ranges.compactMap { r in CodeUsageEntry.parse(json: data[data.startIndex + r.lowerBound ..< data.startIndex + r.upperBound]) }
    }

    public func projects(since: Date, config: AppConfig) -> [CodeProjectUsage] {
        lock.lock(); defer { lock.unlock() }
        return ledger.projects(since: since, config: config)
    }

    public func entries(since: Date) -> [CodeUsageEntry] {
        lock.lock(); defer { lock.unlock() }
        return ledger.entries.values.filter { $0.time >= since }
    }
}

// MARK: Sessions (for scheduling a message into Claude Code)

public struct CodeSession: Identifiable, Sendable, Equatable, Hashable {
    public var id: String          // session id = log file name; `claude --resume <id>`
    public var title: String
    public var lastActive: Date
    /// The permission mode the chat was last used with ("auto", "acceptEdits", …), if recorded.
    public var permissionMode: String? = nil
}

public struct CodeProject: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { path }
    public var path: String        // working directory
    public var name: String
    public var sessions: [CodeSession]
    public var lastActive: Date
}

public enum CodeSessionCatalog {
    /// Projects with sessions active in the last `days`, newest first. Reads only the tail of each
    /// log (titles and working directory), never the whole conversation.
    public static func list(root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
                            days: Double = 30, perProject: Int = 10, now: Date = Date()) -> [CodeProject] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var byPath: [String: [CodeSession]] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      now.timeIntervalSince(mtime) < days * 86400,
                      let info = tailInfo(f) , let cwd = info.cwd else { continue }
                let id = f.deletingPathExtension().lastPathComponent
                byPath[cwd, default: []].append(CodeSession(id: id, title: info.title ?? "Session \(id.prefix(8))", lastActive: mtime,
                                                            permissionMode: info.permissionMode))
            }
        }
        return byPath.compactMap { path, sessions in
            // Skip throwaway temp workspaces and folders that no longer exist (can't run there).
            guard !path.hasPrefix("/private/var/folders"), !path.contains("/T/"), fm.fileExists(atPath: path) else { return nil }
            let s = sessions.sorted { $0.lastActive > $1.lastActive }
            return CodeProject(path: path, name: CodeUsageLedger.displayName(path), sessions: Array(s.prefix(perProject)), lastActive: s[0].lastActive)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    /// Last custom title (or last prompt) and the working directory, from the final ~256 KB.
    static func tailInfo(_ url: URL) -> (title: String?, cwd: String?, permissionMode: String?)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? h.readToEnd() else { return nil }
        return parseTail(String(decoding: data, as: UTF8.self))
    }

    public static func parseTail(_ text: String) -> (title: String?, cwd: String?, permissionMode: String?) {
        var title: String?, prompt: String?, cwd: String?, mode: String?
        for line in text.split(separator: "\n").reversed() {
            // Each user message records the mode it was sent with: "permissionMode":"auto".
            if mode == nil, let r = line.range(of: "\"permissionMode\":\"") {
                let rest = line[r.upperBound...]
                if let end = rest.firstIndex(of: "\""), case let m = String(rest[..<end]), CodeCommand.permissionModes.contains(m) { mode = m }
            }
            if title == nil, line.contains("\"custom-title\""),
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let t = o["customTitle"] as? String, !t.isEmpty { title = t }
            if prompt == nil, line.contains("\"last-prompt\""),
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let t = o["lastPrompt"] as? String, !t.isEmpty {
                prompt = String(t.prefix(60)).replacingOccurrences(of: "\n", with: " ")
            }
            if cwd == nil, line.contains("\"cwd\""),
               let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let c = o["cwd"] as? String { cwd = c }
            if title != nil, cwd != nil, mode != nil { break }
        }
        return (title ?? prompt, cwd, mode)
    }
}

/// The JSON `claude -p --output-format json` prints at the end of a headless run.
public struct CodeRunResult: Sendable, Equatable {
    public var success: Bool
    public var text: String
    public var sessionId: String?
    public var limitHit: Bool
    public var limitResetsAt: Date?
    public var permissionDenials: Int

    public static func parse(stdout: String) -> CodeRunResult? {
        // The result is the last JSON object printed.
        for line in stdout.split(separator: "\n").reversed() {
            guard let json = try? JSON.parse(String(line)), json["type"].string == "result" else { continue }
            let text = json["result"].string ?? json["subtype"].string ?? ""
            let isError = json["is_error"].bool ?? (json["subtype"].string != "success")
            let lower = text.lowercased()
            let limit = isError && (json["api_error_status"].int == 429 || lower.contains("usage limit") || lower.contains("limit reached")
                                    || (lower.contains("hit your") && lower.contains("limit")))
            var reset: Date? = nil
            // "Claude AI usage limit reached|1762912800"
            if limit, let bar = text.lastIndex(of: "|"), let secs = Double(text[text.index(after: bar)...].trimmingCharacters(in: .whitespaces)) {
                reset = Date(timeIntervalSince1970: secs)
            }
            // stream-json runs report the exact reset time in a rate_limit_event; otherwise read
            // "resets 5:30am (America/New_York)" from the message.
            if limit, reset == nil {
                reset = stdout.split(separator: "\n").compactMap { CodeStreamEvent.parse(line: String($0)) }
                    .last(where: { $0.limitRejected && $0.limitResetsAt != nil })?.limitResetsAt
                    ?? CodeRunResult.resetFromText(text)
            }
            return CodeRunResult(success: !isError, text: text, sessionId: json["session_id"].string, limitHit: limit,
                                 limitResetsAt: reset, permissionDenials: json["permission_denials"].arrayOrEmpty.count)
        }
        return nil
    }
}
