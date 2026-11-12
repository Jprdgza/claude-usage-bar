import Foundation

/// Everything that is "claude.ai's current shape" rather than logic lives here: endpoint paths,
/// cookie names, window labels, and every estimation constant. The default is compiled in
/// (`DefaultConfig.json`); a user copy at
/// `~/Library/Application Support/ClaudeUsageBar/endpoints.json` replaces it wholesale, so a
/// changed path or constant can be fixed without a rebuild.
public struct AppConfig: Codable, Sendable {
    public var configVersion: Int
    public var baseURL: String
    public var allowedHosts: [String]
    public var endpoints: Endpoints
    public var cookies: Cookies
    public var webTransportOriginPath: String
    public var tokens: TokenConstants
    public var modelFamilies: [String]
    public var modelWeights: [String: ModelWeight]
    public var familyWeights: [String: Double]
    public var fallbackWeight: Double
    public var contextWindows: [String: ContextWindow]
    public var estimatedCaps: [String: [String: Double]]
    public var peakHours: PeakHours
    public var windowKinds: [String: WindowKind]
    public var legacyWindowKeys: [String: LegacyWindow]
    public var sandboxTools: [String]
    public var visualizeToolId: String
    public var countTokensModel: String
    /// Timing for scheduled messages (all targets). Optional so older override files still load.
    public var scheduling: SchedulingConfig?
    public var schedule: SchedulingConfig { scheduling ?? SchedulingConfig() }

    public struct SchedulingConfig: Codable, Sendable {
        /// Wait this long after the reset time before sending (lets the counters roll over).
        public var delayAfterResetSeconds: Double = 60
        /// If the limit is still hit, retry every `limitRetrySeconds` for this long.
        public var limitRetryMinutes: Double = 30
        public var limitRetrySeconds: Double = 120
        public init() {}
    }

    public struct Endpoints: Codable, Sendable {
        public var usage: String
        public var credits: String
        public var bootstrap: String
        public var accountProfile: String
        public var organizations: String
        public var conversationList: String
        public var conversationTree: String
        public var projectStats: String
        public var login: String
        public var anthropicCountTokens: String
    }

    public struct Cookies: Codable, Sendable {
        public var session: String
        public var org: String
        public var domain: String
    }

    public struct TokenConstants: Codable, Sendable {
        public var systemPrompt: [String: Int]
        public var preferencesSection: Int
        public var featurePrompts: [String: Int]
        public var compactionSummary: Int
        public var outputMultiplier: Double
        public var cachingMultiplier: Double
        public var cacheLifetimeMinutes: Double
        public var localEstimatorMultiplier: Double
        public var workspaceAttachmentMaxTokens: Int
        public var imageTokensPerPixelDivisor: Double
        public var imageTokensMax: Int
        public var documentTokensPerPage: Int
    }

    public struct ContextWindow: Codable, Sendable {
        public var chat: Int
        public var workspace: [Int]
    }

    public struct PeakHours: Codable, Sendable {
        public var weekdaysOnly: Bool
        public var startHourUTC: Int
        public var endHourUTC: Int
        public var sessionCapDivisor: Double
    }

    public struct WindowKind: Codable, Sendable {
        public var label: String
        public var hours: Double?
        public var capKey: String?
    }

    public struct LegacyWindow: Codable, Sendable {
        public var kind: String
        public var model: String?
    }

    public var cacheLifetime: TimeInterval { tokens.cacheLifetimeMinutes * 60 }
    public var fixedSystemPromptTokens: Int { tokens.systemPrompt.values.reduce(0, +) }

    public func url(_ template: String, _ params: [String: String] = [:]) -> URL? {
        var path = template
        for (k, v) in params {
            let escaped = v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? v
            path = path.replacingOccurrences(of: "{\(k)}", with: escaped)
        }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        return URL(string: baseURL + path)
    }
}

/// A model's cost weight: a flat number, or tiered by conversation length.
public enum ModelWeight: Codable, Sendable, Equatable {
    case flat(Double)
    case tiered(weight: Double, longWeight: Double, longAbove: Int)

    private struct Tiered: Codable { var weight: Double; var longWeight: Double; var longAbove: Int }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .flat(n); return }
        let t = try c.decode(Tiered.self)
        self = .tiered(weight: t.weight, longWeight: t.longWeight, longAbove: t.longAbove)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .flat(let n): try c.encode(n)
        case .tiered(let w, let lw, let la): try c.encode(Tiered(weight: w, longWeight: lw, longAbove: la))
        }
    }

    public func value(forLength length: Int) -> Double {
        switch self {
        case .flat(let n): return n
        case .tiered(let w, let lw, let la): return length > la ? lw : w
        }
    }
}

/// The compiled-in default, exported so the app can write a copy users can edit.
public enum DefaultConfigExport {
    public static var json: String { DefaultConfig.json }
}

public enum ConfigLoader {
    public static func defaultConfig() -> AppConfig {
        // The compiled-in default is covered by a unit test, so this cannot fail in a shipped build.
        try! JSONDecoder().decode(AppConfig.self, from: Data(DefaultConfig.json.utf8))
    }

    /// Returns the override if it exists and decodes, else the default. `problem` explains a
    /// rejected override so the UI/log can say why it was ignored.
    public static func load(overrideURL: URL?) -> (config: AppConfig, problem: String?) {
        guard let url = overrideURL, FileManager.default.fileExists(atPath: url.path) else {
            return (defaultConfig(), nil)
        }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(AppConfig.self, from: data), nil)
        } catch {
            return (defaultConfig(), "Ignored \(url.lastPathComponent): \(error)")
        }
    }
}
