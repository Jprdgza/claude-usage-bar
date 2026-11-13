import XCTest
@testable import UsageCore

final class EfficiencyTests: XCTestCase {
    let config = ConfigLoader.defaultConfig()
    let utc: TimeZone = TimeZone(identifier: "UTC")!

    /// A Sunday (off-peak) or Monday 14:00 UTC (peak) base time.
    func date(_ iso: String) -> Date { JSON.parseISODate(iso)! }

    func entry(_ t: Date, out: Int) -> CodeUsageEntry {
        CodeUsageEntry(id: UUID().uuidString, time: t, project: "/p", sessionId: "s", model: "claude-opus-5-5",
                       input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: out)
    }

    /// One 5-hour window: session goes 0 → `delta`, weekly grows, all of it Claude Code.
    func window(reset: Date, delta: Double, out: Int, weeklyStart: Double) -> ([HistoryPoint], [CodeUsageEntry]) {
        let start = reset.addingTimeInterval(-5 * 3600 + 60)
        let end = reset.addingTimeInterval(-60)
        let p0 = HistoryPoint(t: start, v: ["session": 0, "weekly_all": weeklyStart], r: ["session": reset], b: ["Claude Code": 100])
        let p1 = HistoryPoint(t: end, v: ["session": delta, "weekly_all": weeklyStart + delta / 5], r: ["session": reset], b: ["Claude Code": 100])
        return ([p0, p1], [entry(start.addingTimeInterval(600), out: out)])
    }

    func build(_ specs: [(String, Double, Int)], now: Date) -> [EfficiencySample] {
        var pts: [HistoryPoint] = [], es: [CodeUsageEntry] = []
        var weekly = 0.0
        for (iso, delta, out) in specs {
            let (p, e) = window(reset: date(iso), delta: delta, out: out, weeklyStart: weekly)
            pts += p; es += e; weekly += delta / 5
        }
        return EfficiencyAnalyzer.samples(points: pts, entries: es, config: config, now: now)
    }

    func testFlagsTighterWindowOffPeak() {
        // Sundays (off-peak): 4 normal windows (1000 out per 10%), then one where 10% bought half as much.
        let specs: [(String, Double, Int)] = [
            ("2026-10-04T10:00:00Z", 10, 1000), ("2026-10-11T10:00:00Z", 10, 1000),
            ("2026-10-18T10:00:00Z", 10, 1100), ("2026-10-25T10:00:00Z", 10, 900),
            ("2026-11-01T10:00:00Z", 10, 500), ("2026-11-08T10:00:00Z", 10, 1000),
        ]
        let samples = build(specs, now: date("2026-11-09T00:00:00Z"))
        XCTAssertEqual(samples.count, 6)
        XCTAssertEqual(samples[0].codeFraction, 1, accuracy: 0.001)
        let v = EfficiencyAnalyzer.verdict(for: samples[4], among: samples)
        XCTAssertEqual(v?.kind, .tighter)
        XCTAssertEqual(v!.ratio, 0.5, accuracy: 0.01)
        let text = EfficiencyAnalyzer.explain(samples[4], verdict: v, config: config)
        XCTAssertTrue(text.contains("Decreased limits?"))
        XCTAssertTrue(text.contains("outside peak hours"))
        XCTAssertEqual(EfficiencyAnalyzer.verdict(for: samples[5], among: samples)?.kind, .normal)
        XCTAssertNil(EfficiencyAnalyzer.verdict(for: samples[3], among: samples), "only 3 earlier windows: normal not known yet")
    }

    func testPeakWindowIsExplainedByPeakHours() {
        // Off-peak normal windows, then a weekday 14:00-UTC (peak) window that's tighter.
        let specs: [(String, Double, Int)] = [
            ("2026-10-04T10:00:00Z", 10, 1000), ("2026-10-11T10:00:00Z", 10, 1000),
            ("2026-10-18T10:00:00Z", 10, 1000), ("2026-10-25T10:00:00Z", 10, 1000),
            ("2026-11-02T17:00:00Z", 10, 600),   // Monday; activity at 12:10 UTC = peak
        ]
        let samples = build(specs, now: date("2026-11-03T00:00:00Z"))
        let s = samples.last!
        XCTAssertTrue(s.mostlyPeak)
        let v = EfficiencyAnalyzer.verdict(for: s, among: samples)
        XCTAssertEqual(v?.kind, .tighter)
        XCTAssertEqual(v?.comparedWithPeak, false)
        XCTAssertTrue(EfficiencyAnalyzer.explain(s, verdict: v, config: config).contains("known to be tighter"))
    }

    func testCodeFractionUsesBreakdownAndSkipsSmallWindows() {
        let reset = date("2026-11-01T10:00:00Z")
        // Weekly 40 → 50; Claude Code share 50% → 60%: code part 20 → 30 = all 10 points. Then half Code.
        let a = HistoryPoint(t: reset.addingTimeInterval(-4 * 3600), v: ["session": 0, "weekly_all": 40], r: ["session": reset], b: ["Claude Code": 50, "Cowork": 50])
        let b = HistoryPoint(t: reset.addingTimeInterval(-60), v: ["session": 20, "weekly_all": 50], r: ["session": reset], b: ["Claude Code": 60, "Cowork": 40])
        XCTAssertEqual(EfficiencyAnalyzer.codeFraction(a, b)!, 1.0, accuracy: 0.001)
        let c = HistoryPoint(t: b.t, v: b.v, r: b.r, b: ["Claude Code": 50, "Cowork": 50])
        XCTAssertEqual(EfficiencyAnalyzer.codeFraction(a, c)!, 0.5, accuracy: 0.001)
        XCTAssertNil(EfficiencyAnalyzer.codeFraction(a, HistoryPoint(t: b.t, v: b.v, r: b.r, b: nil)))
        // 2 points of the limit is too small to measure.
        let tiny = EfficiencySample(resetsAt: reset, start: a.t, end: b.t, sessionDelta: 2, codeFraction: 1, codeCost: 100,
                                    codeTokens: 100, peakFraction: 0, finished: true)
        XCTAssertNil(tiny.costPerPercent)
    }

    func testMergeKeepsFinishedWindowsAndRoundTrips() {
        let reset = date("2026-11-01T10:00:00Z")
        let old = EfficiencySample(resetsAt: reset, start: reset.addingTimeInterval(-18000), end: reset, sessionDelta: 10, codeFraction: 1,
                                   codeCost: 5000, codeTokens: 9000, peakFraction: 0, finished: true)
        var partial = old; partial.end = reset.addingTimeInterval(-3600); partial.codeCost = 1   // logs since deleted
        let merged = EfficiencyAnalyzer.merge(stored: [old], fresh: [partial])
        XCTAssertEqual(merged, [old])
        XCTAssertEqual(EfficiencyAnalyzer.parse(EfficiencyAnalyzer.serialize(merged)), merged)
    }

    func testPeakHoursInLocalTime() {
        XCTAssertEqual(EfficiencyAnalyzer.peakHoursLocal(config, timeZone: TimeZone(identifier: "America/New_York")!).hasPrefix("Mon–Fri "), true)
        XCTAssertEqual(EfficiencyAnalyzer.peakHoursLocal(config, timeZone: utc, locale: Locale(identifier: "en_GB")), "Mon–Fri 12:00–18:00")
        // A 12-hour clock in another time zone: 12–18 UTC is 7 AM–1 PM in New York in winter.
        let ny = TimeZone(identifier: "America/New_York")!, winter = JSON.parseISODate("2026-01-15T12:00:00Z")!
        let us = EfficiencyAnalyzer.peakHoursLocal(config, timeZone: ny, locale: Locale(identifier: "en_US"), now: winter)
        XCTAssertEqual(us.replacingOccurrences(of: "\u{202F}", with: " "), "Mon–Fri 7 AM–1 PM")
        // Half-hour offsets keep their minutes (India is UTC+5:30).
        let india = EfficiencyAnalyzer.peakHoursLocal(config, timeZone: TimeZone(identifier: "Asia/Kolkata")!, locale: Locale(identifier: "en_US"), now: winter)
        XCTAssertEqual(india.replacingOccurrences(of: "\u{202F}", with: " "), "Mon–Fri 5:30 PM–11:30 PM")
        let iv = EfficiencyAnalyzer.peakIntervals(from: date("2026-10-31T00:00:00Z"), to: date("2026-11-03T00:00:00Z"), config: config)
        XCTAssertEqual(iv.count, 1, "Sat/Sun skipped, Monday counted")
        XCTAssertEqual(iv[0].0, date("2026-11-02T12:00:00Z"))
    }
}

final class CodeTargetTests: XCTestCase {
    func testRunResultParsing() {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"OK","session_id":"abc","permission_denials":[]}"#
        let r = CodeRunResult.parse(stdout: "noise\n" + ok)
        XCTAssertEqual(r?.success, true); XCTAssertEqual(r?.text, "OK"); XCTAssertEqual(r?.sessionId, "abc")
        let limit = #"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1800000000","session_id":"abc"}"#
        let l = CodeRunResult.parse(stdout: limit)
        XCTAssertEqual(l?.limitHit, true)
        XCTAssertEqual(l?.limitResetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(CodeRunResult.parse(stdout: "Error: not logged in"))
    }

    func testArgumentsAndSessionTail() {
        let t = ScheduledMessage.CodeTarget(projectPath: "/p", projectName: "p", sessionId: "s1", sessionTitle: "T", permissionMode: "acceptEdits")
        XCTAssertEqual(CodeCommand.streamArguments(target: t, session: .resume("s1")),
                       ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits", "--resume", "s1"])
        XCTAssertEqual(CodeCommand.streamArguments(target: t, session: .new("n1")).suffix(2), ["--session-id", "n1"])
        let tail = """
        {"type":"user","cwd":"/Users/x/Project","message":{"content":"hi"}}
        {"type":"custom-title","customTitle":"Refactor the parser","sessionId":"s"}
        {"type":"last-prompt","lastPrompt":"# Plan","sessionId":"s"}
        """
        let info = CodeSessionCatalog.parseTail(tail)
        XCTAssertEqual(info.title, "Refactor the parser"); XCTAssertEqual(info.cwd, "/Users/x/Project")
    }

    func testOldQueueFileWithoutCodeStillDecodes() throws {
        var j = ScheduledMessage(conversationId: "c", conversationName: "Chat", text: "hi", trigger: .at(Date(timeIntervalSince1970: 1_800_000_000)))
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        var obj = try JSONSerialization.jsonObject(with: e.encode(j)) as! [String: Any]
        obj.removeValue(forKey: "code")
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ScheduledMessage.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(back.isClaudeCode)
        j.code = .init(projectPath: "/p", projectName: "p", sessionId: nil, sessionTitle: nil, permissionMode: "dontAsk")
        XCTAssertTrue(try d.decode(ScheduledMessage.self, from: e.encode(j)).isClaudeCode)
    }
}
