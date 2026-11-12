import Foundation
@testable import UsageCore

enum Fixture {
    static func json(_ name: String) throws -> JSON {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try JSON.parse(Data(contentsOf: dir.appendingPathComponent(name)))
    }
}

/// Deterministic counter: one token per whitespace-separated word. Makes the math checkable by hand.
struct WordCounter: TokenCounting {
    func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
    func countText(_ text: String) async -> TokenCount { TokenCount(words(text), exact: true) }
    func countConversation(humans: [String], assistants: [String]) async -> TokenCount {
        TokenCount((humans + assistants).reduce(0) { $0 + words($1) }, exact: true)
    }
}

struct ExactFileCounter: FileTokenCounting {
    let config: AppConfig
    func count(file: JSON) async -> TokenCount { TokenCount(EstimatedFileCounter(config: config).estimate(file), exact: true) }
}

let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

/// Builds a conversation tree with message times relative to `now`.
struct TreeBuilder {
    let now: Date
    var messages: [JSON] = []

    mutating func add(_ id: String, parent: String?, _ sender: String, minutesAgo: Double, text: String = "",
                      content: [JSON]? = nil, extra: [String: JSON] = [:]) {
        var o: [String: JSON] = [
            "uuid": .string(id),
            "parent_message_uuid": .string(parent ?? "00000000-0000-4000-8000-000000000000"),
            "sender": .string(sender),
            "created_at": .string(iso.string(from: now.addingTimeInterval(-minutesAgo * 60))),
            "content": .array(content ?? (text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])])),
        ]
        for (k, v) in extra { o[k] = v }
        messages.append(.object(o))
    }

    func tree(leaf: String, model: String = "claude-sonnet-5-5", extra: [String: JSON] = [:]) -> JSON {
        var o: [String: JSON] = [
            "uuid": .string("conv"), "name": .string("Test"), "model": .string(model),
            "current_leaf_message_uuid": .string(leaf), "chat_messages": .array(messages),
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
}

func textBlock(_ s: String) -> JSON { .object(["type": .string("text"), "text": .string(s)]) }
