import Foundation

public enum Tier: String, Sendable, CaseIterable {
    case free = "claude_free", pro = "claude_pro", team = "claude_team"
    case max5x = "claude_max_5x", max20x = "claude_max_20x"

    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        case .team: return "Team"
        case .max5x: return "Max 5×"
        case .max20x: return "Max 20×"
        }
    }
}

/// Account-level switches that add system-prompt sections (keys match `tokens.featurePrompts`).
public struct FeatureFlags: Sendable, Equatable {
    public var memory = false
    public var pastChatSearch = false   // enabled_saffron_search
    public var inlineVisuals = false
    public var driveSearch = false      // enabled_bananagrams (only marks length as an estimate)

    public init(memory: Bool = false, pastChatSearch: Bool = false, inlineVisuals: Bool = false, driveSearch: Bool = false) {
        self.memory = memory; self.pastChatSearch = pastChatSearch
        self.inlineVisuals = inlineVisuals; self.driveSearch = driveSearch
    }

    /// The conversation's own settings win over the account's; the per-chat Memory checkbox
    /// (`chat_memory_mode: "disabled"`) turns off both memory and past-chat search.
    public func overlaid(with settings: JSON) -> FeatureFlags {
        var f = self
        if let b = settings["memory"].bool { f.memory = b }
        if let b = settings["enabled_saffron_search"].bool { f.pastChatSearch = b }
        if let b = settings["inline_visuals"].bool { f.inlineVisuals = b }
        if let b = settings["enabled_bananagrams"].bool { f.driveSearch = b }
        if settings["chat_memory_mode"].string == "disabled" { f.memory = false; f.pastChatSearch = false }
        return f
    }

    public var featurePromptKeys: [String] {
        var keys: [String] = []
        if memory { keys.append("memory") }
        if pastChatSearch { keys.append("enabled_saffron_search") }
        if inlineVisuals { keys.append("inline_visuals") }
        return keys
    }
}

public struct AccountInfo: Sendable, Equatable {
    public var orgId: String
    public var orgName: String?
    public var tier: Tier
    public var flags: FeatureFlags

    public init(orgId: String, orgName: String?, tier: Tier, flags: FeatureFlags) {
        self.orgId = orgId; self.orgName = orgName; self.tier = tier; self.flags = flags
    }
}

public enum AccountDecoder {
    /// From `/api/bootstrap/{org}/app_start`.
    public static func decodeBootstrap(_ json: JSON, orgId: String, config: AppConfig) -> AccountInfo {
        let membership = json["account"]["memberships"].arrayOrEmpty
            .first { $0["organization"]["uuid"].string == orgId }
        let org = membership?["organization"] ?? .null
        let settings = json["account"]["settings"]
        let flags = FeatureFlags(
            memory: json["memory_mode"].string == "melange",
            pastChatSearch: settings["enabled_saffron_search"].bool ?? false,
            inlineVisuals: settings["enabled_mcp_tools"][config.visualizeToolId].bool ?? false,
            driveSearch: settings["enabled_bananagrams"].bool ?? false)
        return AccountInfo(orgId: orgId, orgName: org["name"].string, tier: tier(fromOrg: org), flags: flags)
    }

    public static func tier(fromOrg org: JSON) -> Tier {
        guard org.object != nil else { return .free }
        let caps = Set(org["capabilities"].arrayOrEmpty.compactMap(\.string))
        let rateTier = org["rate_limit_tier"].string ?? "default_claude_ai"
        if org["raven_type"].isTruthy { return .team }
        if caps.contains("claude_max") { return rateTier.contains("5x") ? .max5x : .max20x }
        if caps.contains("claude_pro") { return .pro }
        return .free
    }

    /// From `/api/organizations`: the first org that can chat, else the first one.
    public static func pickOrg(_ json: JSON) -> String? {
        let orgs = json.array ?? json["data"].arrayOrEmpty
        let chat = orgs.first { $0["capabilities"].arrayOrEmpty.contains { $0.string == "chat" } }
        return (chat ?? orgs.first)?["uuid"].string
    }
}

public struct ConversationSummary: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var model: String?
    public var updatedAt: Date?
    public var projectId: String?
}

public enum ConversationListDecoder {
    public static func decode(_ json: JSON) -> [ConversationSummary] {
        let items = json.array ?? json["data"].array ?? json["conversations"].arrayOrEmpty
        return items.compactMap { c in
            guard let id = c["uuid"].string else { return nil }
            let name = c["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            return ConversationSummary(id: id, name: name, model: c["model"].string,
                                       updatedAt: c["updated_at"].date, projectId: c["project_uuid"].string)
        }
    }
}

public struct ProjectInfo: Sendable, Equatable {
    public var knowledgeTokens: Int
    public var usesRetrieval: Bool

    /// From `/projects/{id}/kb/stats`. With retrieval (RAG) on, knowledge isn't in context.
    public static func decode(_ json: JSON) -> ProjectInfo {
        let rag = json["use_project_knowledge_search"].bool ?? false
        return ProjectInfo(knowledgeTokens: rag ? 0 : (json["knowledge_size"].int ?? 0), usesRetrieval: rag)
    }
}
