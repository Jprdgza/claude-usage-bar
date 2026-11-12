import XCTest
@testable import UsageCore

/// The token-breakdown and caching math, checked by hand with a one-token-per-word counter.
final class TokenBreakdownTests: XCTestCase {
    let config = ConfigLoader.defaultConfig()
    let now = JSON.parseISODate("2026-11-04T12:00:00Z")!
    let system = 94_900

    func ctx(flags: FeatureFlags = FeatureFlags(), prefs: Int = 0, project: ProjectInfo? = nil) -> AnalysisContext {
        AnalysisContext(config: config, accountFlags: flags, preferencesTokens: TokenCount(prefs, exact: true), project: project)
    }

    func analyze(_ tree: JSON, _ c: AnalysisContext? = nil, at: Date? = nil) async -> ConversationStats {
        await ConversationAnalyzer.analyze(tree: tree, context: c ?? ctx(), counter: WordCounter(),
                                           fileCounter: ExactFileCounter(config: config), now: at ?? now)
    }

    func testWarmCacheFastPath() async {
        var b = TreeBuilder(now: now)
        b.add("h1", parent: nil, "human", minutesAgo: 30, text: "a b c")
        b.add("a1", parent: "h1", "assistant", minutesAgo: 29, text: "d e")
        b.add("h2", parent: "a1", "human", minutesAgo: 10, text: "f g h i")
        b.add("a2", parent: "h2", "assistant", minutesAgo: 9, text: "j k l")
        let s = await analyze(b.tree(leaf: "a2"))

        XCTAssertEqual(s.breakdown.systemPrompt, system)
        XCTAssertEqual(s.breakdown.history, 12)
        XCTAssertEqual(s.length, system + 12)
        // Output surcharge: last reply (3) × 4 = 12. Cached prefix h1,a1,h2 = 9 of 12 history tokens.
        XCTAssertEqual(s.outputSurcharge, 12)
        XCTAssertEqual(s.nextCostCached, 12 + (12 - 9))
        XCTAssertEqual(s.nextCostUncached, 12 + 12)
        XCTAssertEqual(s.cachedUntil, now.addingTimeInterval(-9 * 60 + 3600))
        XCTAssertTrue(s.isCached(now: now))
        XCTAssertEqual(s.weight, 2)
        XCTAssertEqual(s.weightedNextCost(now: now), 15 * 2)
        XCTAssertEqual(s.weightedNextCost(now: now.addingTimeInterval(3 * 3600)), 24 * 2, "uncached once the hour passes")
        XCTAssertEqual(s.contextWindow, 1_000_000)
        XCTAssertTrue(s.countsExact)
        XCTAssertTrue(s.estimateReasons.isEmpty)
    }

    func testOffTrunkRetryKeepsPrefixWarmSlowPath() async {
        var b = TreeBuilder(now: now)
        b.add("h1", parent: nil, "human", minutesAgo: 180, text: "one two")
        b.add("a1", parent: "h1", "assistant", minutesAgo: 179, text: "three")
        b.add("h2", parent: "a1", "human", minutesAgo: 120, text: "four five six")
        b.add("a2", parent: "h2", "assistant", minutesAgo: 119, text: "seven")
        b.add("a1b", parent: "h1", "assistant", minutesAgo: 10, text: "retry of the first reply")
        let s = await analyze(b.tree(leaf: "a2"))

        XCTAssertEqual(s.cachedUntil, now.addingTimeInterval(50 * 60))
        XCTAssertEqual(s.breakdown.history, 7)
        XCTAssertEqual(s.nextCostCached, 4 + (7 - 2), "only h1 is in the warm prefix")
        XCTAssertEqual(s.nextCostUncached, 4 + 7)
    }

    func testColdConversationHasNoCache() async {
        var b = TreeBuilder(now: now)
        b.add("h1", parent: nil, "human", minutesAgo: 300, text: "x")
        b.add("a1", parent: "h1", "assistant", minutesAgo: 299, text: "y")
        let s = await analyze(b.tree(leaf: "a1"))
        XCTAssertNil(s.cachedUntil)
        XCTAssertFalse(s.isCached(now: now))
        XCTAssertEqual(s.nextCostCached, s.nextCostUncached)
    }

    func testLegacyCompactionProjectAndPreferences() async {
        var b = TreeBuilder(now: now)
        b.add("h1", parent: nil, "human", minutesAgo: 10, text: "old old old old")
        b.add("a1", parent: "h1", "assistant", minutesAgo: 9, text: "old reply")
        b.add("h2", parent: "a1", "human", minutesAgo: 8, text: "older still")
        b.add("a2", parent: "h2", "assistant", minutesAgo: 7, text: "compacting",
              extra: ["compaction_summary": .array([textBlock("sum sum sum")])])
        b.add("h3", parent: "a2", "human", minutesAgo: 5, text: "x y")
        b.add("a3", parent: "h3", "assistant", minutesAgo: 4, text: "z")
        let s = await analyze(b.tree(leaf: "a3"), ctx(prefs: 100, project: ProjectInfo(knowledgeTokens: 500, usesRetrieval: false)))

        XCTAssertEqual(s.breakdown.compactionSummary, 3)
        XCTAssertEqual(s.breakdown.history, 3, "only messages after the compaction")
        XCTAssertEqual(s.breakdown.projectKnowledge, 500)
        XCTAssertEqual(s.breakdown.preferences, 100)
        XCTAssertEqual(s.length, system + 3 + 3 + 500 + 100)
        // cached: summary 0, output 4, history 3−2 (h3 cached), project 0, prefs 0.
        XCTAssertEqual(s.nextCostCached, 4 + 1)
        XCTAssertEqual(s.nextCostUncached, 3 + 4 + 3 + 500 + 100)
        XCTAssertTrue(s.estimateReasons.isEmpty, "legacy summaries are counted, not assumed")
    }

    func testMergedCompactionDividerUsesConstant() async {
        var b = TreeBuilder(now: now)
        b.add("h1", parent: nil, "human", minutesAgo: 100, text: "a lot of words here")
        b.add("a1", parent: "h1", "assistant", minutesAgo: 99, text: "reply")
        b.add("div", parent: "a1", "assistant", minutesAgo: 98)
        b.add("h2", parent: "div", "human", minutesAgo: 90, text: "after")
        b.add("a2", parent: "h2", "assistant", minutesAgo: 89, text: "done now")
        let s = await analyze(b.tree(leaf: "a2"))
        XCTAssertEqual(s.breakdown.compactionSummary, 6000)
        XCTAssertEqual(s.breakdown.history, 3)
        XCTAssertTrue(s.lengthIsApprox)
        XCTAssertTrue(s.estimateReasons.contains { $0.contains("Compacted") })
    }

    func testFeatureFlagsAndPerChatMemoryOverride() async {
        var b = TreeBuilder(now: now)
        b.add("h1", parent: nil, "human", minutesAgo: 300, text: "x")
        let all = FeatureFlags(memory: true, pastChatSearch: true, inlineVisuals: true, driveSearch: true)
        let on = await analyze(b.tree(leaf: "h1"), ctx(flags: all))
        XCTAssertEqual(on.breakdown.featurePrompts, 24_800 + 3_700 + 4_200)
        XCTAssertTrue(on.estimateReasons.contains { $0.contains("Memory") })
        XCTAssertTrue(on.estimateReasons.contains { $0.contains("Drive") })

        let off = await analyze(b.tree(leaf: "h1", extra: ["settings": .object(["chat_memory_mode": .string("disabled")])]), ctx(flags: all))
        XCTAssertEqual(off.breakdown.featurePrompts, 4_200, "per-chat Memory off drops memory and past-chat search")
    }

    func testWorkspaceSandboxedFiles() async {
        var b = TreeBuilder(now: now)
        let doc = { (id: String, pages: Int) -> JSON in
            .object(["file_uuid": .string(id), "file_kind": .string("document"),
                     "document_asset": .object(["page_count": .number(Double(pages))])])
        }
        let img: JSON = .object(["file_uuid": .string("i2"), "file_kind": .string("image"),
                                 "preview_asset": .object(["image_width": .number(100), "image_height": .number(75)])])
        b.add("h1", parent: nil, "human", minutesAgo: 50, text: "first", extra: ["files": .array([doc("d1", 1)])])
        b.add("a1", parent: "h1", "assistant", minutesAgo: 49,
              content: [.object(["type": .string("tool_use"), "name": .string("Bash"), "input": .object(["cmd": .string("ls")])])])
        b.add("h2", parent: "a1", "human", minutesAgo: 40, text: "second",
              extra: ["files": .array([doc("d2", 2), img]),
                      "attachments": .array([.object(["extracted_content": .string("tiny note")])])])
        b.add("a2", parent: "h2", "assistant", minutesAgo: 39, text: "ok")
        let s = await analyze(b.tree(leaf: "a2", extra: ["workspace_upgraded": .bool(true)]))

        XCTAssertEqual(s.breakdown.files, 2250 + 10, "d1 predates the upgrade; d2 is sandboxed; images stay in context")
        XCTAssertEqual(s.breakdown.history, 1 + 1 + 3 + 1, #"tool input {"cmd":"ls"} is one word; the small attachment stays"#)
        XCTAssertTrue(s.workspaceUpgraded)
        XCTAssertEqual(s.contextWindow, 500_000)
        XCTAssertEqual(s.compactAt, 467_000)
        XCTAssertTrue(s.estimateReasons.contains { $0.contains("workspace") })
    }

    func testSavedTreeFixture() async throws {
        let tree = try Fixture.json("conversation_tree.json")
        let flags = FeatureFlags(memory: true, pastChatSearch: true, inlineVisuals: true)
        let s = await ConversationAnalyzer.analyze(tree: tree, context: ctx(flags: flags), counter: WordCounter(),
                                                   fileCounter: EstimatedFileCounter(config: config), now: now)
        XCTAssertEqual(s.breakdown.featurePrompts, 4_200)
        XCTAssertEqual(s.breakdown.files, 1000 + 3 * 2250)
        // m1 "hello there alpha beta" 4, m2 {"query":"q"} + "result text" + "answer one" 5 (no thinking),
        // m3 2, m4 2. The off-trunk m2b is ignored.
        XCTAssertEqual(s.breakdown.history, 13)
        XCTAssertEqual(s.outputSurcharge, 8)
        XCTAssertNil(s.cachedUntil)
        XCTAssertEqual(s.nextCostUncached, 8 + 7750 + 13)
        XCTAssertEqual(s.weightedNextCost(now: now), (8 + 7750 + 13) * 2)
        XCTAssertFalse(s.countsExact, "file sizes came from metadata")
        XCTAssertTrue(s.estimateReasons.contains { $0.contains("Web search") })
    }

    func testTextExtractionViews() throws {
        let thinking = try JSON.parse(#"{"type":"thinking","thinking":"hmm"}"#)
        XCTAssertEqual(ConversationAnalyzer.texts(thinking, asOutput: false), [])
        XCTAssertEqual(ConversationAnalyzer.texts(thinking, asOutput: true), ["hmm"])
        let result = try JSON.parse(#"{"type":"tool_result","content":[{"type":"text","text":"file body"}]}"#)
        XCTAssertEqual(ConversationAnalyzer.texts(result, asOutput: false), ["file body"], "tool results stay in context")
        XCTAssertEqual(ConversationAnalyzer.texts(result, asOutput: true), [], "but aren't output")
    }

    func testModelWeights() {
        XCTAssertEqual(ConversationAnalyzer.weight(model: "claude-opus-5-5", length: 0, config: config), 4)
        XCTAssertEqual(ConversationAnalyzer.weight(model: "claude-sonnet-4-5-20250929", length: 0, config: config), 3, "dated id falls back to undated")
        XCTAssertEqual(ConversationAnalyzer.weight(model: "claude-opus-9", length: 0, config: config), 5, "unknown id: family weight")
        XCTAssertEqual(ConversationAnalyzer.weight(model: nil, length: 0, config: config), 5)
        XCTAssertEqual(ConversationAnalyzer.weight(model: "claude-haiku-5-5", length: 150_000, config: config), 0.5)
    }

    func testLocalEstimatorAndInterleave() {
        let e = LocalTokenEstimator()
        XCTAssertEqual(e.estimate(""), 0)
        XCTAssertGreaterThan(e.estimate("hello world"), 0)
        let short = e.baseTokens("The quick brown fox jumps over the lazy dog.")
        XCTAssertTrue((9...14).contains(short), "English ≈ one token per word: got \(short)")
        XCTAssertEqual(e.baseTokens("你好世界"), 4)
        XCTAssertLessThan(e.estimate("abc"), e.estimate(String(repeating: "abc ", count: 50)))

        let msgs = AnthropicTokenCounter.interleave(humans: ["h0", ""], assistants: ["a0"])
        XCTAssertEqual(msgs.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(msgs[2]["content"] as? String, ".")
    }
}
