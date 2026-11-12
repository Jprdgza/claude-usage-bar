import XCTest
@testable import UsageCore

final class CodeLiveTests: XCTestCase {
    // Shapes taken from real `claude -p --output-format stream-json --verbose` output and session logs.
    func testStreamEvents() {
        let initLine = #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-5-5","tools":[]}"#
        XCTAssertEqual(CodeStreamEvent.parse(line: initLine)?.sessionId, "s1")
        XCTAssertEqual(CodeStreamEvent.parse(line: initLine)?.lines.first?.kind, .info)

        let assistant = #"{"type":"assistant","session_id":"s1","message":{"role":"assistant","content":[{"type":"text","text":"Adding the header now."},{"type":"tool_use","name":"Edit","input":{"file_path":"/x/y/page.js","old_string":"a"}},{"type":"tool_use","name":"Bash","input":{"command":"npm run build\nnpm test"}}]}}"#
        let e = CodeStreamEvent.parse(line: assistant)!
        XCTAssertEqual(e.lines.map(\.kind), [.text, .tool, .tool])
        XCTAssertEqual(e.lines.map(\.text), ["Adding the header now.", "Edit page.js", "Bash: npm run build npm test"])

        let toolErr = #"{"type":"user","session_id":"s1","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"content":"Exit code 1"}]}}"#
        XCTAssertEqual(CodeStreamEvent.parse(line: toolErr)?.lines.map(\.kind), [.error])

        let ok = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1794963600,"rateLimitType":"seven_day"},"session_id":"s1"}"#
        XCTAssertEqual(CodeStreamEvent.parse(line: ok)?.limitRejected, false)
        let rejected = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794465000,"rateLimitType":"five_hour"},"session_id":"s1"}"#
        let r = CodeStreamEvent.parse(line: rejected)!
        XCTAssertTrue(r.limitRejected)
        XCTAssertEqual(r.limitResetsAt, Date(timeIntervalSince1970: 1794465000))

        XCTAssertNil(CodeStreamEvent.parse(line: "not json"))
        XCTAssertNil(CodeStreamEvent.parse(line: #"{"type":"attachment","attachment":{}}"#))
    }

    func testResultUsesStreamResetTime() {
        let out = [
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794465000},"session_id":"s1"}"#,
            #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your session limit · resets 12:30am (America/New_York)","session_id":"s1"}"#,
        ].joined(separator: "\n")
        let r = CodeRunResult.parse(stdout: out)!
        XCTAssertTrue(r.limitHit)
        XCTAssertEqual(r.limitResetsAt, Date(timeIntervalSince1970: 1794465000))
    }

    func testResetFromText() {
        // 2026-11-12 02:24 in New York (07:24 UTC) → next 5:30 AM New York = 10:30 UTC.
        let now = JSON.parseISODate("2026-11-12T07:24:24Z")!
        let r = CodeRunResult.resetFromText("You've hit your session limit · resets 5:30am (America/New_York)", now: now)
        XCTAssertEqual(r, JSON.parseISODate("2026-11-12T10:30:00Z"))
        // 12:30am, said at 12:29am → one minute later, not tomorrow.
        let r2 = CodeRunResult.resetFromText("resets 12:30am (America/New_York)", now: JSON.parseISODate("2026-11-12T05:29:32Z")!)
        XCTAssertEqual(r2, JSON.parseISODate("2026-11-12T05:30:00Z"))
        XCTAssertEqual(CodeRunResult.resetFromText("resets 3pm (UTC)", now: now), JSON.parseISODate("2026-11-12T15:00:00Z"))
        XCTAssertNil(CodeRunResult.resetFromText("Something else went wrong", now: now))
        // The older parser missed this wording entirely; it must count as a limit.
        let res = #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your session limit · resets 5:30am (America/New_York)"}"#
        XCTAssertTrue(CodeRunResult.parse(stdout: res)!.limitHit)
        XCTAssertNotNil(CodeRunResult.parse(stdout: res)!.limitResetsAt)
    }

    func testSessionTurnDetection() {
        let prompt = #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"--weird 'start' \"q\": reply with exactly dash-ok"}}"#
        let older = #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"old reply"}]}}"#
        let toolUse = #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#
        let toolResult = #"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
        let sidechain = #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"subagent"}]}}"#
        let done = #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"dash-ok"}]}}"#
        let marker = "--weird 'start' \"q\": reply with exactly dash-ok"

        XCTAssertEqual(SessionTurn.evaluate(lines: [older], marker: marker), .notStarted, "an earlier turn's reply doesn't count")
        XCTAssertEqual(SessionTurn.evaluate(lines: [older, prompt], marker: marker), .working)
        XCTAssertEqual(SessionTurn.evaluate(lines: [prompt, toolUse, toolResult], marker: marker), .working)
        XCTAssertEqual(SessionTurn.evaluate(lines: [prompt, toolUse, toolResult, sidechain], marker: marker), .working, "subagent messages are ignored")
        XCTAssertEqual(SessionTurn.evaluate(lines: [prompt, toolUse, toolResult, done], marker: marker), .finished(text: "dash-ok"))

        // A usage-limit stop as written in a real session log.
        let limit = #"{"type":"assistant","isSidechain":false,"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1794465000}},"isApiErrorMessage":true,"apiErrorStatus":429,"message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You've hit your session limit · resets 12:30am (America/New_York)"}]}}"#
        if case .limited(let at, _) = SessionTurn.evaluate(lines: [prompt, toolUse, toolResult, limit], marker: marker) {
            XCTAssertEqual(at, Date(timeIntervalSince1970: 1794465000))
        } else { XCTFail("expected a limit stop") }
    }

    func testCleanEnvironmentAndScriptQuoting() {
        let env = ["PATH": "/bin", "HOME": "/Users/x", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1",
                   "CLAUDE_CODE_SESSION_ID": "abc", "ANTHROPIC_BASE_URL": "http://localhost:1", "ANTHROPIC_API_KEY": "k"]
        XCTAssertEqual(Set(CodeCommand.cleanEnvironment(env).keys), ["PATH", "HOME", "ANTHROPIC_API_KEY"])

        XCTAssertEqual(CodeCommand.shellQuote("it's $(rm -rf ~) `x`"), #"'it'\''s $(rm -rf ~) `x`'"#)
        let t = ScheduledMessage.CodeTarget(projectPath: "/Users/x/My Project", projectName: "My Project",
                                            sessionId: "d6a7", sessionTitle: nil, permissionMode: "auto")
        let s = CodeCommand.terminalScript(claude: "/Users/x/.local/bin/claude", target: t, session: .resume("d6a7"),
                                           messageFile: "/tmp/m.msg", pidFile: "/tmp/m.pid", title: "Scheduled: it's")
        XCTAssertTrue(s.contains("cd -- '/Users/x/My Project'"))
        XCTAssertTrue(s.contains("'--resume' 'd6a7' -- \"$prompt\""), "the message is passed after -- so it can't become a flag")
        XCTAssertTrue(s.contains("'Scheduled: it'\\''s'"))
        XCTAssertFalse(s.contains("reply"), "the message itself never appears in the script")
        let fresh = CodeCommand.terminalScript(claude: "/c", target: t, session: .new("new-id"),
                                               messageFile: "/m", pidFile: "/p", title: "t")
        XCTAssertTrue(fresh.contains("'--session-id' 'new-id'"))
        XCTAssertEqual(CodeCommand.streamArguments(target: t, session: .resume("d6a7")), ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "auto", "--resume", "d6a7"])
        let fork = CodeCommand.SessionMode.fork(from: "d6a7", to: "f00d", name: "Website (scheduled)")
        XCTAssertEqual(fork.id, "f00d")
        XCTAssertEqual(fork.arguments, ["--resume", "d6a7", "--fork-session", "--session-id", "f00d", "--name", "Website (scheduled)"])
        let forkScript = CodeCommand.terminalScript(claude: "/c", target: t, session: fork, messageFile: "/m", pidFile: "/p", title: "t")
        XCTAssertTrue(forkScript.contains("'--fork-session' '--session-id' 'f00d' '--name' 'Website (scheduled)' -- \"$prompt\""))
    }

    func testDesktopHoldsSession() {
        // Real shape of the Claude app's per-session process.
        let ps = [
            "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- /Users/x/Library/Application Support/Claude/claude-code/2.1.321/ab/claude.app/Contents/MacOS/claude --output-format stream-json --verbose --resume=96e07b58-3e4f",
            "/Users/x/.local/bin/claude -p --output-format json --resume aaaa-bbbb",
        ]
        XCTAssertTrue(CodeCommand.desktopHolds(sessionId: "96e07b58-3e4f", commands: ps))
        XCTAssertFalse(CodeCommand.desktopHolds(sessionId: "aaaa-bbbb", commands: ps), "a plain terminal claude isn't the Claude app")
        XCTAssertFalse(CodeCommand.desktopHolds(sessionId: "other", commands: ps))
    }

    func testOlderQueueFilesStillLoad() throws {
        let old = #"[{"id":"33606205-01F5-4087-AADC-4D466E28B595","created":"2026-11-12T05:12:40Z","conversationName":"A","text":"t","trigger":{"at":{"_0":"2026-11-12T06:15:57Z"}},"state":"waiting","attempts":0}]"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let jobs = try d.decode([ScheduledMessage].self, from: Data(old.utf8))
        XCTAssertNil(jobs[0].continueOnRetry)
    }
}
