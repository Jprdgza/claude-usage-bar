import XCTest
@testable import UsageCore

final class HistoryTests: XCTestCase {
    func testRecordsChangesAndHeartbeatOnly() {
        var h = UsageHistory(heartbeat: 1800)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(h.record(["session": 10], at: t0))
        XCTAssertFalse(h.record(["session": 10], at: t0.addingTimeInterval(60)))       // unchanged
        XCTAssertTrue(h.record(["session": 12], at: t0.addingTimeInterval(120)))       // changed
        XCTAssertTrue(h.record(["session": 12], at: t0.addingTimeInterval(120 + 1800))) // heartbeat
        XCTAssertFalse(h.record([:], at: t0.addingTimeInterval(9999)))
        XCTAssertEqual(h.points.count, 3)
    }

    func testRoundTripSkipsBadLinesAndPrunes() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var h = UsageHistory(retention: 86400)
        h.record(["session": 5, "weekly_all": 40], at: t0)
        h.record(["session": 6, "weekly_all": 40], at: t0.addingTimeInterval(2 * 86400))
        let text = h.serialized() + "{\"t\": broken\n"
        let parsed = UsageHistory.parse(text)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].v["weekly_all"], 40)
        var back = UsageHistory(points: parsed, retention: 86400)
        XCTAssertTrue(back.prune(now: t0.addingTimeInterval(2 * 86400 + 10)))
        XCTAssertEqual(back.points.count, 1)
    }
}

final class ClaudeCodeLogTests: XCTestCase {
    let config = ConfigLoader.defaultConfig()

    func line(id: String, cwd: String, ts: String, model: String = "claude-opus-5-5", input: Int = 10, w1h: Int = 0, read: Int = 0, out: Int = 100, session: String = "s1") -> String {
        """
        {"type":"assistant","cwd":"\(cwd)","sessionId":"\(session)","timestamp":"\(ts)","message":{"id":"\(id)","model":"\(model)","role":"assistant","content":[{"type":"text","text":"secret"}],"usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(w1h),"cache_read_input_tokens":\(read),"output_tokens":\(out),"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":\(w1h)}}}}
        """
    }

    func testParseAndIgnoreOtherLines() {
        let e = CodeUsageEntry.parse(line: Substring(line(id: "m1", cwd: "/Users/x/Proj", ts: "2026-11-05T04:36:24.867Z", w1h: 1000, read: 5000)))
        XCTAssertEqual(e?.cacheWrite1h, 1000)
        XCTAssertEqual(e?.cacheRead, 5000)
        XCTAssertEqual(e?.project, "/Users/x/Proj")
        XCTAssertEqual(e?.totalTokens, 10 + 1000 + 5000 + 100)
        XCTAssertNil(CodeUsageEntry.parse(line: #"{"type":"user","message":{"role":"user","content":"hi"}}"#))
        XCTAssertNil(CodeUsageEntry.parse(line: "not json \"usage\" \"assistant\""))
    }

    func testDedupesByMessageIdAndSplitsByProject() {
        var ledger = CodeUsageLedger()
        let ts = "2026-11-05T04:36:24Z"
        // Same API message logged twice (one line per content block).
        for raw in [line(id: "a", cwd: "/p/A", ts: ts, out: 100), line(id: "a", cwd: "/p/A", ts: ts, out: 100),
                    line(id: "b", cwd: "/p/B", ts: ts, out: 100, session: "s2")] {
            ledger.add(CodeUsageEntry.parse(line: Substring(raw))!)
        }
        let rows = ledger.projects(since: JSON.parseISODate("2026-11-05T00:00:00Z")!, config: config)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].share + rows[1].share, 100, accuracy: 0.001)
        XCTAssertEqual(rows[0].share, 50, accuracy: 0.001)
        XCTAssertEqual(rows.first { $0.name == "A" }?.tokens, 110)
        // Outside the period: nothing.
        XCTAssertTrue(ledger.projects(since: JSON.parseISODate("2026-11-06T00:00:00Z")!, config: config).isEmpty)
    }

    func testScannerReadsIncrementally() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID())")
        let proj = dir.appendingPathComponent("-Users-x-A")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = proj.appendingPathComponent("s.jsonl")
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        try (line(id: "a", cwd: "/x/A", ts: iso) + "\n" + line(id: "half", cwd: "/x/A", ts: iso)).write(to: f, atomically: true, encoding: .utf8)
        let scanner = CodeLogScanner(root: dir)
        scanner.scan(now: now)
        XCTAssertEqual(scanner.ledger.entries.count, 1, "the unterminated last line waits")
        let h = try FileHandle(forWritingTo: f); h.seekToEndOfFile(); h.write(Data("\n".utf8)); try h.close()
        scanner.scan(now: now)
        XCTAssertEqual(scanner.ledger.entries.count, 2)
    }
}

final class SchedulingTests: XCTestCase {
    func testResolveFollowsResetThenFreezes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var j = ScheduledMessage(conversationId: "c", conversationName: "Chat", text: "hi",
                                 trigger: .afterReset(windowId: "session", label: "5-hour"), now: now)
        func win(_ reset: Date) -> [UsageWindow] {
            [UsageWindow(id: "session", label: "5-hour", percent: 100, resetsAt: reset, windowLength: 18000, capKey: nil)]
        }
        j.resolve(windows: win(now.addingTimeInterval(3600)), delay: 60, now: now)
        XCTAssertEqual(j.fireAt, now.addingTimeInterval(3660))
        XCTAssertFalse(j.isDue(now: now))
        // After the reset passes, /usage reports the next window's reset: the job must not move.
        let later = now.addingTimeInterval(3630)
        j.resolve(windows: win(now.addingTimeInterval(3600 + 18000)), delay: 60, now: later)
        XCTAssertEqual(j.fireAt, now.addingTimeInterval(3660))
        XCTAssertTrue(j.isDue(now: now.addingTimeInterval(3661)))
    }

    func testSchedulingConfigDefaultsAndBackCompat() throws {
        let cfg = ConfigLoader.defaultConfig()
        XCTAssertEqual(cfg.schedule.delayAfterResetSeconds, 60)
        var obj = try JSONSerialization.jsonObject(with: Data(DefaultConfigExport.json.utf8)) as! [String: Any]
        obj.removeValue(forKey: "scheduling")
        let old = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.scheduling)
        XCTAssertEqual(old.schedule.limitRetrySeconds, 120)
    }
}
