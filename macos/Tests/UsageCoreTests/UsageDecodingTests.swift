import XCTest
@testable import UsageCore

final class UsageDecodingTests: XCTestCase {
    let config = ConfigLoader.defaultConfig()

    func testDefaultConfigDecodes() {
        XCTAssertEqual(config.fixedSystemPromptTokens, 94_900)
        XCTAssertEqual(config.url(config.endpoints.usage, ["org": "abc"])?.absoluteString, "https://claude.ai/api/organizations/abc/usage")
        XCTAssertEqual(config.url(config.endpoints.anthropicCountTokens)?.host, "api.anthropic.com")
        XCTAssertEqual(config.modelWeights["claude-haiku-5-5"]?.value(forLength: 200_000), 0.5)
    }

    func testLimitsArrayFormatRendersEveryEntryGenerically() throws {
        let snap = UsageDecoder.decode(try Fixture.json("usage_limits_array.json"),
                                       credits: try Fixture.json("credits.json"), config: config)
        XCTAssertEqual(snap.format, .limitsArray)
        XCTAssertEqual(snap.windows.map(\.id), ["session", "weekly_all", "weekly_scoped:sonnet", "daily_research"])

        let session = snap.windows[0]
        XCTAssertEqual(session.label, "Session (5h)")
        XCTAssertEqual(session.percent, 37)
        XCTAssertEqual(session.windowLength, 5 * 3600)
        XCTAssertEqual(session.resetsAt, JSON.parseISODate("2026-11-04T20:00:00Z"))
        XCTAssertEqual(session.capKey, "session")
        XCTAssertEqual(snap.session?.id, "session")

        XCTAssertNotNil(snap.windows[1].resetsAt, "fractional-second ISO dates parse")
        XCTAssertEqual(snap.windows[2].label, "Weekly – Sonnet")
        XCTAssertEqual(snap.windows[2].capKey, "weekly:sonnet")

        // Unknown kind: still shown, with a prettified label, no cap, no pace (length unknown).
        let research = snap.windows[3]
        XCTAssertEqual(research.label, "Daily research")
        XCTAssertNil(research.capKey)
        XCTAssertNil(research.windowLength)
        XCTAssertTrue(research.exceeded)

        let extra = try XCTUnwrap(snap.extra)
        XCTAssertEqual(extra.monthlyLimitCents, 5000)
        XCTAssertEqual(extra.usedCents, 1250)
        XCTAssertEqual(extra.remainingCents, 1000, "credit balance caps what can still be spent")
        XCTAssertEqual(extra.percent, 1250.0 / 2250.0 * 100, accuracy: 0.001)
    }

    func testLegacyTopLevelFormatIncludingUnknownKeys() throws {
        let snap = UsageDecoder.decode(try Fixture.json("usage_legacy.json"), config: config)
        XCTAssertEqual(snap.format, .legacyTopLevel)
        XCTAssertEqual(snap.windows.map(\.id), ["session", "weekly_all", "weekly_scoped:opus", "seven_day_oauth_apps"])
        XCTAssertEqual(snap.windows[0].percent, 82.5)
        XCTAssertEqual(snap.windows[0].level, .high)
        let unknown = snap.windows[3]
        XCTAssertEqual(unknown.label, "Seven day oauth apps")
        XCTAssertEqual(unknown.windowLength, 7 * 86400, "length inferred from the key")
        XCTAssertNil(unknown.resetsAt)
        XCTAssertEqual(snap.extra, ExtraUsage(monthlyLimitCents: 2000, usedCents: 500, balanceCents: nil))
    }

    /// Captured from a live Pro account on 2026-11-05: the limits array plus legacy mirrors,
    /// ~20 null codename keys, and a per-product weekly breakdown.
    func testRealProResponse() throws {
        let json = try Fixture.json("usage_real_2026-11-05_pro.json")
        let snap = UsageDecoder.decode(json, config: config)
        XCTAssertEqual(snap.format, .limitsArray)
        XCTAssertEqual(snap.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(snap.windows.map(\.percent), [22, 40])
        XCTAssertEqual(snap.session?.resetsAt, JSON.parseISODate("2026-11-06T00:20:00.214309+00:00"))
        XCTAssertNotNil(snap.session?.resetsAt, "microsecond timestamps parse")
        XCTAssertNil(snap.extra, "spend and extra_usage are both disabled")

        XCTAssertEqual(snap.breakdowns.count, 1)
        let b = snap.breakdowns[0]
        XCTAssertEqual(b.label, "Weekly by product")
        XCTAssertEqual(b.rows.map(\.name), ["Claude Code", "Chats", "Cowork", "Other"])
        XCTAssertEqual(b.rows.map(\.percent), [51, 0, 49, 0])

        // The legacy mirrors agree with the limits array.
        XCTAssertEqual(json["five_hour"]["utilization"].number, 22)
        XCTAssertEqual(json["seven_day"]["utilization"].number, 40)

        // If `limits` disappeared, the legacy fields alone would still give the same windows.
        var legacyOnly = json.object!
        legacyOnly["limits"] = .array([])
        let fallback = UsageDecoder.decode(.object(legacyOnly), config: config)
        XCTAssertEqual(fallback.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(fallback.windows.map(\.percent), [22, 40])
        XCTAssertEqual(fallback.ignoredKeys, [], "breakdowns and null codenames aren't reported as unknown")
    }

    func testFreePlanEmptyResponse() throws {
        let snap = UsageDecoder.decode(try Fixture.json("usage_free.json"), config: config)
        XCTAssertTrue(snap.isEmpty)
        XCTAssertEqual(snap.format, .empty)
        XCTAssertNil(snap.session)
    }

    func testGarbageNeverThrows() throws {
        for body in ["[]", "null", "\"x\"", "{\"limits\": \"nope\"}", "{\"five_hour\": {\"utilization\": \"high\"}}"] {
            let snap = UsageDecoder.decode(try JSON.parse(body), config: config)
            XCTAssertTrue(snap.isEmpty, body)
        }
    }

    func testLevels() {
        XCTAssertEqual(UsageLevel.of(49.9), .low)
        XCTAssertEqual(UsageLevel.of(50), .medium)
        XCTAssertEqual(UsageLevel.of(80), .medium)
        XCTAssertEqual(UsageLevel.of(80.1), .high)
    }

    func testPaceProjection() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let half = now.addingTimeInterval(2.5 * 3600)
        var w = UsageWindow(id: "session", label: "S", percent: 40, resetsAt: half, windowLength: 5 * 3600, capKey: "session")
        let slow = try! XCTUnwrap(w.pace(now: now))
        XCTAssertEqual(slow.projectedPercent, 80, accuracy: 0.001)
        XCTAssertNil(slow.hitsLimitAt)
        XCTAssertEqual(slow.elapsedFraction, 0.5, accuracy: 0.001)

        w.percent = 60
        let fast = try! XCTUnwrap(w.pace(now: now))
        XCTAssertEqual(fast.projectedPercent, 120, accuracy: 0.001, "projection may exceed 100")
        let start = half.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(fast.hitsLimitAt!.timeIntervalSince(start), 2.5 * 3600 * 100 / 60, accuracy: 1)

        w.resetsAt = now.addingTimeInterval(5 * 3600 - 60) // 1 minute in: too early
        XCTAssertNil(w.pace(now: now))
        w.resetsAt = now.addingTimeInterval(-10) // already reset
        XCTAssertNil(w.pace(now: now))
        w.windowLength = nil
        w.resetsAt = half
        XCTAssertNil(w.pace(now: now))
    }

    func testInferLength() {
        XCTAssertEqual(UsageDecoder.inferLength(fromKey: "five_hour"), 18000)
        XCTAssertEqual(UsageDecoder.inferLength(fromKey: "24_hour_x"), 86400)
        XCTAssertEqual(UsageDecoder.inferLength(fromKey: "seven_day_opus"), 604800)
        XCTAssertNil(UsageDecoder.inferLength(fromKey: "weekly_all"))
    }

    func testBootstrapTierAndFlags() throws {
        let info = AccountDecoder.decodeBootstrap(try Fixture.json("bootstrap.json"), orgId: "org-1", config: config)
        XCTAssertEqual(info.tier, .max5x)
        XCTAssertEqual(info.orgName, "Personal")
        XCTAssertEqual(info.flags, FeatureFlags(memory: true, pastChatSearch: true, inlineVisuals: true, driveSearch: false))
        XCTAssertEqual(AccountDecoder.decodeBootstrap(.null, orgId: "x", config: config).tier, .free)
        XCTAssertEqual(AccountDecoder.tier(fromOrg: try JSON.parse(#"{"capabilities":["claude_pro"],"raven_type":"team"}"#)), .team)
        XCTAssertEqual(AccountDecoder.tier(fromOrg: try JSON.parse(#"{"capabilities":["claude_max"],"rate_limit_tier":"default_claude_max_20x"}"#)), .max20x)
        XCTAssertEqual(AccountDecoder.tier(fromOrg: try JSON.parse(#"{"capabilities":["claude_pro"]}"#)), .pro)
    }

    func testConversationListAndProject() throws {
        let list = ConversationListDecoder.decode(try Fixture.json("conversation_list.json"))
        XCTAssertEqual(list.map(\.id), ["c1", "c2"])
        XCTAssertEqual(list[1].name, "Untitled")
        XCTAssertEqual(list[1].projectId, "p1")
        XCTAssertNotNil(list[0].updatedAt, "microsecond ISO dates parse")
        XCTAssertEqual(ConversationListDecoder.decode(try JSON.parse(#"{"data":[{"uuid":"z"}]}"#)).map(\.id), ["z"])

        XCTAssertEqual(ProjectInfo.decode(try JSON.parse(#"{"knowledge_size":1200}"#)), ProjectInfo(knowledgeTokens: 1200, usesRetrieval: false))
        XCTAssertEqual(ProjectInfo.decode(try JSON.parse(#"{"knowledge_size":1200,"use_project_knowledge_search":true}"#)).knowledgeTokens, 0)
    }

    func testMessagesLeftAndPeak() throws {
        let snap = UsageDecoder.decode(try Fixture.json("usage_limits_array.json"), config: config)
        let sunday = JSON.parseISODate("2026-11-08T13:00:00Z")!
        XCTAssertFalse(UsageMath.isPeak(sunday, config: config))
        let left = try XCTUnwrap(UsageMath.messagesLeft(snap, tier: .max5x, messageCost: 1000, now: sunday, config: config))
        XCTAssertEqual(left.windowId, "session")
        XCTAssertEqual(left.messages, 0.63 * 15_000_000 / 1000, accuracy: 0.01)

        let wedPeak = JSON.parseISODate("2026-11-04T13:00:00Z")!
        XCTAssertTrue(UsageMath.isPeak(wedPeak, config: config))
        XCTAssertEqual(UsageMath.sessionCap(tier: .max5x, now: wedPeak, config: config), 10_000_000)
        XCTAssertFalse(UsageMath.isPeak(JSON.parseISODate("2026-11-04T19:00:00Z")!, config: config))
    }

    func testClientErrorClassification() {
        let html = HTTPResponse(status: 200, body: Data("<!DOCTYPE html><html>Just a moment".utf8), contentType: "text/html")
        XCTAssertThrowsError(try ClaudeClient.decode(html)) { XCTAssertEqual($0 as? ClaudeAPIError, .html(status: 200)) }
        let unauth = HTTPResponse(status: 401, body: Data(#"{"error":"x"}"#.utf8), contentType: "application/json")
        XCTAssertThrowsError(try ClaudeClient.decode(unauth)) { XCTAssertTrue(($0 as? ClaudeAPIError)?.isAuthFailure == true) }
        let noRight = HTTPResponse(status: 403, body: Data(#"{"error":{"message":"missing permission billing:credit:get"}}"#.utf8), contentType: "application/json")
        XCTAssertThrowsError(try ClaudeClient.decode(noRight)) { XCTAssertFalse(($0 as? ClaudeAPIError)?.isAuthFailure ?? true) }
        let garbage = HTTPResponse(status: 200, body: Data("not json".utf8), contentType: "application/json")
        XCTAssertThrowsError(try ClaudeClient.decode(garbage))
        let ok = HTTPResponse(status: 200, body: Data(#"{"a":1}"#.utf8), contentType: "application/json")
        XCTAssertEqual(try ClaudeClient.decode(ok)["a"].int, 1)
    }

    func testNetworkPolicy() throws {
        let p = NetworkPolicy(allowedHosts: config.allowedHosts)
        XCTAssertNoThrow(try p.check(URL(string: "https://claude.ai/api/x")!))
        XCTAssertNoThrow(try p.check(URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!))
        XCTAssertThrowsError(try p.check(URL(string: "https://firebaseio.com/x")!))
        XCTAssertThrowsError(try p.check(URL(string: "http://claude.ai/api/x")!))
        XCTAssertThrowsError(try p.check(URL(string: "https://claude.ai.evil.com/x")!))
    }
}
