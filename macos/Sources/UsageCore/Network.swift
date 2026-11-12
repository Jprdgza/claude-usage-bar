import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String?
    public init(status: Int, body: Data, contentType: String?) {
        self.status = status; self.body = body; self.contentType = contentType
    }
    public var looksLikeHTML: Bool {
        let head = String(decoding: body.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype") || head.hasPrefix("<html") || (contentType?.contains("text/html") ?? false)
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum ClaudeAPIError: Error, CustomStringConvertible, Equatable {
    case hostNotAllowed(String)
    case badURL(String)
    case unauthorized(Int)
    case html(status: Int)
    case http(status: Int, snippet: String)
    case invalidJSON(snippet: String)

    public var description: String {
        switch self {
        case .hostNotAllowed(let h): return "Blocked request to \(h) (only claude.ai and api.anthropic.com are allowed)"
        case .badURL(let u): return "Bad URL: \(u)"
        case .unauthorized(let s): return "Not logged in (HTTP \(s))"
        case .html(let s): return "Got an HTML page instead of JSON (HTTP \(s)) – Cloudflare check, maintenance page or login redirect"
        case .http(let s, let snip): return "HTTP \(s): \(snip)"
        case .invalidJSON(let snip): return "Response wasn't JSON: \(snip)"
        }
    }

    public var isAuthFailure: Bool { if case .unauthorized = self { return true }; return false }
}

/// Every outbound request passes through here. The allowlist comes from config and is the
/// enforcement point for "the only network calls allowed are claude.ai and api.anthropic.com".
public struct NetworkPolicy: Sendable {
    public var allowedHosts: Set<String>
    public init(allowedHosts: [String]) { self.allowedHosts = Set(allowedHosts.map { $0.lowercased() }) }

    public func check(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            throw ClaudeAPIError.hostNotAllowed(url.host ?? url.absoluteString)
        }
    }
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResponse(status: http?.statusCode ?? 0, body: data,
                            contentType: http?.value(forHTTPHeaderField: "Content-Type"))
    }
}

/// claude.ai, authenticated by the `sessionKey` cookie.
public final class ClaudeClient: @unchecked Sendable {
    public let config: AppConfig
    let transport: HTTPTransport
    let policy: NetworkPolicy
    let sessionKey: String

    public init(config: AppConfig, transport: HTTPTransport, sessionKey: String) {
        self.config = config; self.transport = transport; self.sessionKey = sessionKey
        policy = NetworkPolicy(allowedHosts: config.allowedHosts)
    }

    public func request(_ template: String, _ params: [String: String] = [:]) throws -> URLRequest {
        guard let url = config.url(template, params) else { throw ClaudeAPIError.badURL(template) }
        try policy.check(url)
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("\(config.cookies.session)=\(sessionKey)", forHTTPHeaderField: "Cookie")
        return r
    }

    public func getJSON(_ template: String, _ params: [String: String] = [:]) async throws -> JSON {
        let response = try await transport.send(try request(template, params))
        return try Self.decode(response)
    }

    public static func decode(_ r: HTTPResponse) throws -> JSON {
        let snippet = String(decoding: r.body.prefix(200), as: UTF8.self)
        if r.looksLikeHTML { throw ClaudeAPIError.html(status: r.status) }
        if r.status == 401 || r.status == 403 {
            // A JSON 403 with "permission"/"billing" is a missing right, not a logout.
            if snippet.contains("permission") || snippet.contains("billing") {
                throw ClaudeAPIError.http(status: r.status, snippet: snippet)
            }
            throw ClaudeAPIError.unauthorized(r.status)
        }
        guard (200..<300).contains(r.status) else { throw ClaudeAPIError.http(status: r.status, snippet: snippet) }
        do { return try JSON.parse(r.body) } catch { throw ClaudeAPIError.invalidJSON(snippet: snippet) }
    }

    public func usage(org: String) async throws -> JSON { try await getJSON(config.endpoints.usage, ["org": org]) }
    public func credits(org: String) async throws -> JSON { try await getJSON(config.endpoints.credits, ["org": org]) }
    public func bootstrap(org: String) async throws -> JSON { try await getJSON(config.endpoints.bootstrap, ["org": org]) }
    public func accountProfile() async throws -> JSON { try await getJSON(config.endpoints.accountProfile) }
    public func organizations() async throws -> JSON { try await getJSON(config.endpoints.organizations) }
    public func conversations(org: String, limit: Int) async throws -> JSON {
        try await getJSON(config.endpoints.conversationList, ["org": org, "limit": String(limit)])
    }
    public func tree(org: String, conversation: String) async throws -> JSON {
        try await getJSON(config.endpoints.conversationTree, ["org": org, "conv": conversation])
    }
    public func projectStats(org: String, project: String) async throws -> JSON {
        try await getJSON(config.endpoints.projectStats, ["org": org, "project": project])
    }

    /// Sends any request built with `request(...)` through this client's transport.
    public func send(_ r: URLRequest) async throws -> HTTPResponse { try await transport.send(r) }

    /// Raw download of a claude.ai-relative asset URL (for exact file counting with an API key).
    public func download(path: String) async throws -> (Data, String) {
        let response = try await transport.send(try request(path))
        guard (200..<300).contains(response.status), !response.looksLikeHTML else {
            throw ClaudeAPIError.http(status: response.status, snippet: "download failed")
        }
        return (response.body, response.contentType ?? "application/octet-stream")
    }
}

/// `/v1/messages/count_tokens`, called with the user's key from the app process. Any failure
/// falls back to the local estimator for that call and reports `exact: false`.
public final class AnthropicTokenCounter: TokenCounting, @unchecked Sendable {
    let apiKey: String
    let transport: HTTPTransport
    let config: AppConfig
    let fallback: LocalTokenEstimator
    let policy: NetworkPolicy
    let onError: @Sendable (String) -> Void

    public init(apiKey: String, transport: HTTPTransport, config: AppConfig, onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.apiKey = apiKey; self.transport = transport; self.config = config; self.onError = onError
        fallback = LocalTokenEstimator(multiplier: config.tokens.localEstimatorMultiplier)
        policy = NetworkPolicy(allowedHosts: config.allowedHosts)
    }

    public func countText(_ text: String) async -> TokenCount {
        guard !text.isEmpty else { return TokenCount(0, exact: true) }
        if let n = try? await call(messages: [["role": "user", "content": text]]), n > 0 { return TokenCount(n, exact: true) }
        return await fallback.countText(text)
    }

    public func countConversation(humans: [String], assistants: [String]) async -> TokenCount {
        let messages = Self.interleave(humans: humans, assistants: assistants)
        guard !messages.isEmpty else { return TokenCount(0, exact: true) }
        if let n = try? await call(messages: messages), n > 0 { return TokenCount(n, exact: true) }
        return await fallback.countConversation(humans: humans, assistants: assistants)
    }

    /// h0, a0, h1, a1…; empty text becomes "." because the API rejects empty content.
    public static func interleave(humans: [String], assistants: [String]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for i in 0..<max(humans.count, assistants.count) {
            if i < humans.count { out.append(["role": "user", "content": humans[i].isEmpty ? "." : humans[i]]) }
            if i < assistants.count { out.append(["role": "assistant", "content": assistants[i].isEmpty ? "." : assistants[i]]) }
        }
        return out
    }

    public func countFile(data: Data, mediaType: String) async -> Int? {
        let kind = mediaType.hasPrefix("image/") ? "image" : "document"
        let block: [String: Any] = ["type": kind, "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
        return try? await call(messages: [["role": "user", "content": [block, ["type": "text", "text": "1"]]]])
    }

    func call(messages: [[String: Any]]) async throws -> Int {
        guard let url = URL(string: config.endpoints.anthropicCountTokens) else { throw ClaudeAPIError.badURL("count_tokens") }
        try policy.check(url)
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.countTokensModel, "messages": messages])
        let response = try await transport.send(r)
        let json = try JSON.parse(response.body)
        if let message = json["error"]["message"].string {
            onError("count_tokens: \(message)")
            throw ClaudeAPIError.http(status: response.status, snippet: message)
        }
        guard let n = json["input_tokens"].int else { throw ClaudeAPIError.invalidJSON(snippet: "no input_tokens") }
        return n
    }

    /// For the settings "Test key" button.
    public func test() async -> Result<Int, Error> {
        do { return .success(try await call(messages: [["role": "user", "content": "Test"]])) }
        catch { return .failure(error) }
    }
}

/// Exact file counts with an API key: download the asset from claude.ai, count it once, cache by
/// file_uuid (files never change). Falls back to the metadata estimate.
public actor APIFileCounter: FileTokenCounting {
    let client: ClaudeClient
    let counter: AnthropicTokenCounter
    let estimate: EstimatedFileCounter
    var cache: [String: Int]
    let persist: @Sendable ([String: Int]) -> Void

    public init(client: ClaudeClient, counter: AnthropicTokenCounter, config: AppConfig,
                cache: [String: Int], persist: @escaping @Sendable ([String: Int]) -> Void) {
        self.client = client; self.counter = counter; self.cache = cache; self.persist = persist
        estimate = EstimatedFileCounter(config: config)
    }

    public func count(file: JSON) async -> TokenCount {
        let id = file["file_uuid"].string ?? file["uuid"].string
        if let id, let cached = cache[id] { return TokenCount(cached, exact: true) }
        let url = file["file_kind"].string == "image" ? file["preview_asset"]["url"].string : file["document_asset"]["url"].string
        if let id, let url, let dl = try? await client.download(path: url),
           let n = await counter.countFile(data: dl.0, mediaType: dl.1), n > 0 {
            cache[id] = n
            persist(cache)
            return TokenCount(n, exact: true)
        }
        return await estimate.count(file: file)
    }
}
