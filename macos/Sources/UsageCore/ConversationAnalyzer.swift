import Foundation

/// Context length split by where the tokens come from. `total` is the conversation length.
public struct ContextBreakdown: Sendable, Equatable {
    public var systemPrompt = 0
    public var featurePrompts = 0
    public var preferences = 0
    public var projectKnowledge = 0
    public var files = 0
    public var history = 0
    public var compactionSummary = 0

    public init() {}

    public var total: Int {
        systemPrompt + featurePrompts + preferences + projectKnowledge + files + history + compactionSummary
    }

    public var items: [(label: String, tokens: Int, help: String)] {
        [
            ("System prompt", systemPrompt, "claude.ai's fixed system prompt and built-in tool schemas (a measured constant, cached)."),
            ("Feature sections", featurePrompts, "Extra prompt sections added by Memory, past-chat search and inline visuals when they're on."),
            ("Your preferences", preferences, "Your profile's conversation preferences, plus the section that explains them."),
            ("Project knowledge", projectKnowledge, "The project's knowledge files (0 when the project uses retrieval instead)."),
            ("Files", files, "Images and PDFs attached in this conversation that are in context."),
            ("Message history", history, "Every message on the current branch, including tool calls and their results."),
            ("Compaction summary", compactionSummary, "The summary that replaced older history after the conversation was compacted."),
        ]
    }
}

public struct ConversationStats: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var modelVersion: String?
    public var modelFamily: String?
    public var breakdown: ContextBreakdown
    /// Next message's cost in input-token equivalents (unweighted), if the cache is still warm.
    public var nextCostCached: Int
    /// Same, with nothing cached.
    public var nextCostUncached: Int
    /// The reply surcharge (output priced at `outputMultiplier`×) included in both costs.
    public var outputSurcharge: Int
    public var cachedUntil: Date?
    public var weight: Double
    public var contextWindow: Int?
    public var compactAt: Int?
    public var workspaceUpgraded: Bool
    public var lastActivity: Date?
    /// Why the length is an estimate (features whose tokens can't be seen), shown to the user.
    public var estimateReasons: [String]
    /// True only if every count came from the Anthropic API.
    public var countsExact: Bool

    public var length: Int { breakdown.total }
    public var lengthIsApprox: Bool { !countsExact || !estimateReasons.isEmpty }

    public func isCached(now: Date) -> Bool { (cachedUntil ?? .distantPast) > now }

    /// The figure the UI shows as "Cost": weighted by the model's price.
    public func weightedNextCost(now: Date) -> Int {
        Int((Double(isCached(now: now) ? nextCostCached : nextCostUncached) * weight).rounded())
    }
}

public struct AnalysisContext: Sendable {
    public var config: AppConfig
    public var accountFlags: FeatureFlags
    public var preferencesTokens: TokenCount
    public var project: ProjectInfo?
    public var name: String?

    public init(config: AppConfig, accountFlags: FeatureFlags, preferencesTokens: TokenCount,
                project: ProjectInfo?, name: String? = nil) {
        self.config = config; self.accountFlags = accountFlags
        self.preferencesTokens = preferencesTokens; self.project = project; self.name = name
    }
}

struct Message {
    var uuid: String
    var parent: String?
    var sender: String
    var createdAt: Date
    var raw: JSON

    var content: [JSON] { raw["content"].arrayOrEmpty }
    var attachments: [JSON] { raw["attachments"].arrayOrEmpty }
    var files: [JSON] { raw["files"].arrayOrEmpty }
    var isHuman: Bool { sender == "human" }
    var isAssistant: Bool { sender == "assistant" }

    init?(_ j: JSON) {
        guard let uuid = j["uuid"].string else { return nil }
        self.uuid = uuid
        parent = j["parent_message_uuid"].string
        sender = j["sender"].string ?? ""
        createdAt = j["created_at"].date ?? .distantPast
        raw = j
    }

    func usesTool(_ names: Set<String>) -> Bool {
        content.contains { $0["type"].string == "tool_use" && names.contains($0["name"].string ?? "") }
    }
}

public struct CacheBoundary: Sendable, Equatable {
    public var isCached: Bool
    public var cacheEndId: String?
    public var cachedUntil: Date?
}

public enum ConversationAnalyzer {
    static let rootId = "00000000-0000-4000-8000-000000000000"

    // MARK: Text extraction (port of getTextFromContent)

    /// Context view (`asOutput == false`): what later turns send back, so tool results count and
    /// thinking doesn't. Output view: what the model generated (text, thinking, tool inputs).
    public static func texts(_ block: JSON, asOutput: Bool) -> [String] {
        var out: [String] = []
        if let t = block["text"].string, !t.isEmpty { out.append(t) }
        if asOutput, let th = block["thinking"].string, !th.isEmpty { out.append(th) }
        if block["input"].isTruthy { out.append(block["input"].string ?? block["input"].serialized) }
        if block["type"].string == "tool_result", asOutput { return out }
        if let nested = block["content"].array {
            for n in nested { out += texts(n, asOutput: asOutput) }
        } else if block["content"].object != nil {
            out += texts(block["content"], asOutput: asOutput)
        }
        return out
    }

    static func messageText(_ m: Message, asOutput: Bool, includeAttachment: (Int) -> Bool = { _ in true }) -> String {
        var pieces = m.content.flatMap { texts($0, asOutput: asOutput) }
        for (i, a) in m.attachments.enumerated() {
            if let ec = a["extracted_content"].string, !ec.isEmpty, includeAttachment(i) { pieces.append(ec) }
        }
        return pieces.joined(separator: " ")
    }

    static func isCompactionDivider(_ m: Message?, parent: Message?) -> Bool {
        guard let m, let parent else { return false }
        return m.isAssistant && m.content.isEmpty && parent.isAssistant
    }

    // MARK: Trunk

    static func messages(_ tree: JSON) -> [Message] { tree["chat_messages"].arrayOrEmpty.compactMap(Message.init) }

    static func trunk(_ tree: JSON, byId: [String: Message]) -> [Message] {
        var result: [Message] = []
        var seen = Set<String>()
        var current = tree["current_leaf_message_uuid"].string
        while let id = current, id != rootId, let m = byId[id], !seen.contains(id) {
            result.append(m); seen.insert(id); current = m.parent
        }
        return result.reversed()
    }

    // MARK: Caching (port of getCachingInfo, "next" boundary only: the fallback never sees a send)

    static func cacheBoundary(all: [Message], trunk: [Message], compactionIdx: Int, now: Date,
                              lifetime: TimeInterval) -> CacheBoundary {
        var byId: [String: Message] = [:]
        var children: [String: [Message]] = [:]
        for m in all {
            byId[m.uuid] = m
            if let p = m.parent { children[p, default: []].append(m) }
        }
        let trunkIds = Set(trunk.map(\.uuid))
        var trunkIndex: [String: Int] = [:]
        for (i, m) in trunk.enumerated() { trunkIndex[m.uuid] = i }

        let trunkAssistants = trunk.filter(\.isAssistant)
        let candidates = trunk.filter { $0.isHuman && (trunkIndex[$0.uuid] ?? -1) > compactionIdx }
        let candidateIds = Set(candidates.map(\.uuid))
        let age = { (m: Message) in now.timeIntervalSince(m.createdAt) }

        // Fast path: the latest trunk reply is still inside the cache lifetime.
        if let last = trunkAssistants.last, let latestHuman = candidates.last, age(last) < lifetime {
            var latestChild = last.createdAt
            for c in children[latestHuman.uuid] ?? [] where c.isAssistant && c.createdAt > latestChild {
                latestChild = c.createdAt
            }
            return CacheBoundary(isCached: true, cacheEndId: latestHuman.uuid,
                                 cachedUntil: latestChild.addingTimeInterval(lifetime))
        }

        // Slow path: a recent off-trunk branch tip (a retry, an edit) can keep a trunk prefix warm.
        let leaves = all.filter { $0.isAssistant && !trunkIds.contains($0.uuid) && age($0) < lifetime && children[$0.uuid] == nil }
        var best: (idx: Int, id: String, until: Date)? = nil
        for leaf in leaves {
            var path = [leaf]
            var walk = leaf.parent
            var guardCount = 0
            while let w = walk, w != rootId, !trunkIds.contains(w), let m = byId[w], guardCount < 100_000 {
                if m.isAssistant { path.insert(m, at: 0) }
                walk = m.parent; guardCount += 1
            }
            guard let junction = walk, trunkIds.contains(junction), let ancestor = byId[junction] else { continue }
            var valid = true
            for i in 1..<max(1, path.count) where path[i].createdAt.timeIntervalSince(path[i - 1].createdAt) >= lifetime {
                valid = false; break
            }
            guard valid else { continue }
            let anchor = ancestor.isHuman ? ancestor : ancestor.parent.flatMap { byId[$0] }
            guard let anchor, candidateIds.contains(anchor.uuid), let idx = trunkIndex[anchor.uuid] else { continue }
            let until = leaf.createdAt.addingTimeInterval(lifetime)
            if best == nil || idx > best!.idx || (idx == best!.idx && until > best!.until) {
                best = (idx, anchor.uuid, until)
            }
        }
        if let best { return CacheBoundary(isCached: true, cacheEndId: best.id, cachedUntil: best.until) }
        return CacheBoundary(isCached: false, cacheEndId: nil, cachedUntil: nil)
    }

    // MARK: Sandboxed files (port of sandboxedFiles)

    /// Keys "<msg>#a<i>" (text attachment) / "<msg>#f<i>" (file) for files that live in the
    /// workspace sandbox rather than in context.
    static func sandboxedFiles(all: [Message], trunk: [Message], fromIdx: Int, workspaceUpgraded: Bool,
                               config: AppConfig, estimator: LocalTokenEstimator) -> Set<String> {
        var result = Set<String>()
        guard workspaceUpgraded else { return result }
        let sandboxTools = Set(config.sandboxTools)
        var upgrade: (at: Date, forcedTurn: String?)? = nil
        for m in all {
            var candidate: (Date, String?)? = nil
            if m.isAssistant, m.usesTool(sandboxTools) {
                candidate = (m.createdAt, m.usesTool(["prepare_session"]) ? m.parent : nil)
            } else if m.isHuman, m.files.contains(where: { $0["file_kind"].string == "blob" }) {
                candidate = (m.createdAt, m.uuid)
            }
            if let c = candidate, upgrade == nil || c.0 < upgrade!.at { upgrade = (c.0, c.1) }
        }
        guard let upgrade else { return result }
        let cap = config.tokens.workspaceAttachmentMaxTokens
        let overCap = { (text: String) -> Bool in
            Double(text.utf8.count) * config.tokens.localEstimatorMultiplier > Double(cap) && estimator.estimate(text) > cap
        }
        for m in trunk.dropFirst(max(0, fromIdx)) where m.isHuman {
            let forcedHere = m.uuid == upgrade.forcedTurn
            if !forcedHere && !(m.createdAt > upgrade.at) { continue }
            for (i, a) in m.attachments.enumerated() {
                if let ec = a["extracted_content"].string, !ec.isEmpty, forcedHere || overCap(ec) { result.insert("\(m.uuid)#a\(i)") }
            }
            for (i, f) in m.files.enumerated() where ["document", "blob"].contains(f["file_kind"].string ?? "") {
                result.insert("\(m.uuid)#f\(i)")
            }
        }
        return result
    }

    // MARK: Model helpers

    public static func undated(_ model: String) -> String {
        model.lowercased().replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }

    public static func family(of model: String?, config: AppConfig) -> String? {
        guard let slug = model?.lowercased() else { return nil }
        return config.modelFamilies.first { slug.contains($0.lowercased()) }
    }

    public static func weight(model: String?, length: Int, config: AppConfig) -> Double {
        if let m = model?.lowercased() {
            if let w = config.modelWeights[m] ?? config.modelWeights[undated(m)] { return w.value(forLength: length) }
        }
        if let fam = family(of: model, config: config), let w = config.familyWeights[fam] { return w }
        return config.fallbackWeight
    }

    // MARK: Analysis (port of getInfo)

    public static func analyze(tree: JSON, context ctx: AnalysisContext, counter: TokenCounting,
                               fileCounter: FileTokenCounting, now: Date = Date()) async -> ConversationStats {
        let config = ctx.config
        let mult = config.tokens.cachingMultiplier
        let estimator = LocalTokenEstimator(multiplier: config.tokens.localEstimatorMultiplier)
        let all = messages(tree)
        var byId: [String: Message] = [:]
        for m in all { byId[m.uuid] = m }
        let trunk = trunk(tree, byId: byId)
        let modelVersion = tree["model"].string
        let workspaceUpgraded = tree["workspace_upgraded"].bool ?? false
        let flags = ctx.accountFlags.overlaid(with: tree["settings"])
        var exact = true
        var reasons: [String] = []
        var b = ContextBreakdown()

        // 1–2. Fixed system prompt + feature sections (always in the cached prefix).
        b.systemPrompt = config.fixedSystemPromptTokens
        b.featurePrompts = flags.featurePromptKeys.reduce(0) { $0 + (config.tokens.featurePrompts[$1] ?? 0) }
        var future = Double(b.systemPrompt + b.featurePrompts) * mult
        var uncached = future // system prompts are always platform-cached

        // Compaction boundary: the latest legacy summary or merged divider on the trunk.
        var compactionIdx = -1
        for i in stride(from: trunk.count - 1, through: 0, by: -1) {
            let hasSummary = !trunk[i].raw["compaction_summary"].arrayOrEmpty.isEmpty
            if hasSummary || isCompactionDivider(trunk[i], parent: i > 0 ? trunk[i - 1] : nil) { compactionIdx = i; break }
        }

        let boundary = cacheBoundary(all: all, trunk: trunk, compactionIdx: compactionIdx, now: now,
                                     lifetime: config.cacheLifetime)
        let cached = boundary.isCached

        // 3. Compaction summary.
        if compactionIdx >= 0 {
            let summary = trunk[compactionIdx].raw["compaction_summary"].arrayOrEmpty
            if !summary.isEmpty {
                let c = await counter.countText(summary.flatMap { texts($0, asOutput: false) }.joined(separator: "\n"))
                b.compactionSummary = c.value; exact = exact && c.exact
            } else {
                b.compactionSummary = config.tokens.compactionSummary
                reasons.append("Compacted conversation: the summary's real size isn't exposed, so a typical size is assumed.")
            }
            future += cached ? Double(b.compactionSummary) * mult : Double(b.compactionSummary)
            uncached += Double(b.compactionSummary)
        }

        // The turn the trunk ends on, and the reply whose output that turn paid for.
        let lastIdx = trunk.count - 1
        let turnIdx = lastIdx >= 1 && isCompactionDivider(trunk[lastIdx], parent: trunk[lastIdx - 1]) ? lastIdx - 1 : lastIdx
        let beforeHumanIdx = turnIdx >= 2 && isCompactionDivider(trunk[turnIdx - 1], parent: trunk[turnIdx - 2]) ? turnIdx - 2 : turnIdx - 1
        let outputIdx = [turnIdx, beforeHumanIdx].first { $0 >= 0 && $0 < trunk.count && trunk[$0].isAssistant } ?? -1

        // 6. Output surcharge: the reply priced again at the output multiplier.
        var surcharge = 0.0
        if outputIdx >= 0 {
            let reply = await counter.countText(messageText(trunk[outputIdx], asOutput: true))
            exact = exact && reply.exact
            surcharge = Double(reply.value) * config.tokens.outputMultiplier
            let out = surcharge + (outputIdx <= compactionIdx ? Double(reply.value) : 0)
            future += out; uncached += out
        }

        let sandboxed = sandboxedFiles(all: all, trunk: trunk, fromIdx: compactionIdx + 1,
                                       workspaceUpgraded: workspaceUpgraded, config: config, estimator: estimator)
        if !sandboxed.isEmpty { reasons.append("Some files sit in the chat's workspace; Claude may read only parts of them.") }

        // 4–5. Walk the trunk after the compaction: files and message text.
        var cacheActive = cached
        var humans: [(String, Bool)] = [], assistants: [(String, Bool)] = []
        var sawWebSearch = false
        for m in trunk.dropFirst(compactionIdx + 1) {
            if !sawWebSearch {
                sawWebSearch = m.content.contains { $0["type"].string == "tool_result" && $0["name"].string == "web_search" }
            }
            for (i, f) in m.files.enumerated() {
                let kind = f["file_kind"].string
                guard kind == "image" || kind == "document", !sandboxed.contains("\(m.uuid)#f\(i)") else { continue }
                let c = await fileCounter.count(file: f)
                exact = exact && c.exact
                b.files += c.value
                future += cacheActive ? Double(c.value) * mult : Double(c.value)
                uncached += Double(c.value)
            }
            let text = messageText(m, asOutput: false) { !sandboxed.contains("\(m.uuid)#a\($0)") }
            if m.isHuman { humans.append((text, cacheActive)) } else { assistants.append((text, cacheActive)) }
            if m.uuid == boundary.cacheEndId { cacheActive = false }
        }
        if sawWebSearch { reasons.append("Web search results: only titles/URLs are exposed, not the page text Claude read.") }

        let allTokens = humans.isEmpty && assistants.isEmpty ? TokenCount(0, exact: true)
            : await counter.countConversation(humans: humans.map(\.0), assistants: assistants.map(\.0))
        let cachedHumans = humans.filter(\.1).map(\.0), cachedAssistants = assistants.filter(\.1).map(\.0)
        let cachedTokens = cachedHumans.isEmpty && cachedAssistants.isEmpty ? TokenCount(0, exact: true)
            : await counter.countConversation(humans: cachedHumans, assistants: cachedAssistants)
        exact = exact && allTokens.exact && cachedTokens.exact
        b.history = allTokens.value
        future += Double(allTokens.value) - Double(cachedTokens.value) * (1 - mult)
        uncached += Double(allTokens.value)

        // 7. Project knowledge. The fallback never sees a send, so "cached" follows the conversation.
        if let p = ctx.project {
            b.projectKnowledge = p.knowledgeTokens
            future += cached ? 0 : Double(p.knowledgeTokens)
            uncached += Double(p.knowledgeTokens)
            if p.usesRetrieval { reasons.append("Project uses retrieval: the knowledge chunks pulled in per message can't be seen.") }
        }

        // 8. Preferences (in the system-prompt prefix: cached by the next message).
        b.preferences = ctx.preferencesTokens.value
        exact = exact && ctx.preferencesTokens.exact
        future += Double(b.preferences) * mult
        uncached += Double(b.preferences)

        if flags.memory { reasons.append("Memory is on: the memory files Claude loads aren't counted.") }
        if flags.driveSearch { reasons.append("Drive search is on: retrieved documents aren't counted.") }
        if workspaceUpgraded { reasons.append("This chat runs in a workspace (Claude Code session); its real context size isn't read.") }

        let length = b.total
        var window: Int? = nil, compactAt: Int? = nil
        if let m = modelVersion, let cw = config.contextWindows[undated(m)] {
            if workspaceUpgraded, cw.workspace.count >= 1 {
                window = cw.workspace[0]; compactAt = cw.workspace.count > 1 ? cw.workspace[1] : nil
            } else { window = cw.chat }
        }
        let last = turnIdx >= 0 && turnIdx < trunk.count ? trunk[turnIdx].createdAt : nil

        return ConversationStats(
            id: tree["uuid"].string ?? "",
            name: ctx.name ?? tree["name"].string ?? "Untitled",
            modelVersion: modelVersion,
            modelFamily: family(of: modelVersion, config: config),
            breakdown: b,
            nextCostCached: Int(future.rounded()),
            nextCostUncached: Int(uncached.rounded()),
            outputSurcharge: Int(surcharge.rounded()),
            cachedUntil: boundary.cachedUntil,
            weight: weight(model: modelVersion, length: length, config: config),
            contextWindow: window, compactAt: compactAt,
            workspaceUpgraded: workspaceUpgraded,
            lastActivity: last == .distantPast ? nil : last,
            estimateReasons: reasons,
            countsExact: exact)
    }

    /// Things that are never in any count, shown in the UI regardless of the conversation.
    public static let neverCounted = [
        "Thinking tokens (claude.ai never exposes them).",
        "Research runs (they happen on Anthropic's backend).",
        "Web-search page text (only titles/URLs are visible).",
        "Anything sent from Claude Code or the API (separate from these chats).",
    ]
}
