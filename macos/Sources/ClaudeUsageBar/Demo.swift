import AppKit
import SwiftUI
import UsageCore

/// Made-up data for README screenshots (`ClaudeUsageBar --render-screenshots <folder>`).
/// Project names, numbers and history are invented; nothing is read from the real account or logs.
struct DemoData {
    let now: Date
    let account: AccountInfo
    let usage: UsageSnapshot
    let history: UsageHistory
    let efficiency: [EfficiencySample]
    let codeSession: [CodeProjectUsage]
    let codeWeek: [CodeProjectUsage]
    let jobs: [ScheduledMessage]

    static func make(now: Date = Date()) -> DemoData {
        let h: TimeInterval = 3600
        let sessionReset = now.addingTimeInterval(1 * h + 50 * 60)
        let weeklyReset = now.addingTimeInterval(3 * 86400 + 4 * h)
        let windows = [
            UsageWindow(id: "session", label: "5-hour", percent: 64, resetsAt: sessionReset, windowLength: 5 * h, capKey: "session"),
            UsageWindow(id: "weekly_all", label: "Weekly", percent: 41, resetsAt: weeklyReset, windowLength: 7 * 86400, capKey: "weekly"),
            UsageWindow(id: "weekly_scoped:opus", label: "Weekly · Opus", percent: 23, resetsAt: weeklyReset, windowLength: 7 * 86400, capKey: nil),
        ]
        let breakdown = UsageBreakdown(id: "seven_day_breakdown", label: "Weekly by product", rows: [
            .init(name: "Claude Code", percent: 71), .init(name: "Chats", percent: 18), .init(name: "Cowork", percent: 11), .init(name: "Other", percent: 0),
        ])
        let usage = UsageSnapshot(windows: windows, breakdowns: [breakdown])

        // A week of history: 5-hour windows climbing during the day, weekly usage creeping up.
        var history = UsageHistory()
        let start = now.addingTimeInterval(-7 * 86400)
        // Each 5-hour window climbs during waking hours and resets; weekly usage climbs steadily to 41 %.
        let step: TimeInterval = 30 * 60
        let steps = Int(now.timeIntervalSince(start) / step)
        func active(_ t: Date) -> Bool { let hr = Calendar.current.component(.hour, from: t); return hr >= 9 && hr <= 23 }
        let activeSteps = max(1, (0..<steps).filter { active(start.addingTimeInterval(Double($0) * step)) }.count)
        var rng = SystemRandomNumberGenerator()
        var pct = 0.0, weekly = 2.0, lastWindow = -1
        for k in 0..<steps {
            let t = start.addingTimeInterval(Double(k) * step)
            // Windows are anchored to the current one, so the last window ends at `sessionReset`.
            let w = Int(floor(sessionReset.timeIntervalSince(t) / (5 * h)))
            let reset = sessionReset.addingTimeInterval(-Double(w) * 5 * h)
            if w != lastWindow { pct = 0; lastWindow = w }
            if active(t) {
                pct = min(97, pct + Double.random(in: 0...7.5, using: &rng))
                weekly += 39.0 / Double(activeSteps) * Double.random(in: 0.4...1.6, using: &rng)
            }
            history.record(["session": pct.rounded(), "weekly_all": min(41, weekly).rounded()],
                           resets: ["session": reset, "weekly_all": weeklyReset],
                           breakdown: ["Claude Code": 71, "Chats": 18, "Cowork": 11], at: t)
        }
        history.record(["session": 64, "weekly_all": 41], resets: ["session": sessionReset, "weekly_all": weeklyReset],
                       breakdown: ["Claude Code": 71, "Chats": 18, "Cowork": 11], at: now)

        // Efficiency: ~30 days of windows around a normal of 100K weighted tokens per 1 %, a few
        // tighter ones (some during peak hours), and the current window running tight.
        var eff: [EfficiencySample] = []
        let base = 100_000.0
        for day in stride(from: 30, through: 1, by: -1) {
            for slot in [14.0, 20.0] where (day + Int(slot)) % 3 != 0 {
                let reset = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(day) * 86400 + slot * h)
                let peak = slot == 14 && day % 4 == 0
                var ratio = Double.random(in: 0.85...1.15, using: &rng)
                if peak { ratio = Double.random(in: 0.55...0.68, using: &rng) }
                if day == 9 || day == 10 { ratio = 0.58 }      // a stretch of tighter limits
                let delta = Double.random(in: 12...40, using: &rng)
                let cost = base * ratio * delta * 0.9
                eff.append(EfficiencySample(resetsAt: reset, start: reset.addingTimeInterval(-5 * h + 300), end: reset.addingTimeInterval(-120),
                                            sessionDelta: delta, codeFraction: 0.9, codeCost: cost, codeTokens: Int(cost * 2.6),
                                            peakFraction: peak ? 0.85 : 0.1, finished: true))
            }
        }
        eff.append(EfficiencySample(resetsAt: sessionReset, start: sessionReset.addingTimeInterval(-5 * h + 300), end: now,
                                    sessionDelta: 52, codeFraction: 0.95, codeCost: base * 0.62 * 52 * 0.95,
                                    codeTokens: Int(base * 0.62 * 52 * 0.95 * 2.6), peakFraction: 0.2, finished: false))

        func p(_ name: String, _ share: Double, _ tokens: Int, _ sessions: Int, _ model: String, _ ago: TimeInterval) -> CodeProjectUsage {
            CodeProjectUsage(path: "/Users/you/code/\(name)", name: name, tokens: tokens, output: tokens / 40, cost: share,
                             share: share, sessions: sessions, lastActive: now.addingTimeInterval(-ago), topModel: model)
        }
        let session = [p("api-server", 46, 18_400_000, 2, "claude-opus-5-5", 120), p("ios-app", 31, 12_100_000, 1, "claude-sonnet-5-5", 900),
                       p("docs-site", 15, 6_300_000, 1, "claude-sonnet-5-5", 3000), p("scripts", 8, 2_900_000, 1, "claude-haiku-5-5", 7000)]
        let week = [p("api-server", 52, 96_000_000, 9, "claude-opus-5-5", 120), p("ios-app", 27, 51_000_000, 6, "claude-sonnet-5-5", 900),
                    p("docs-site", 13, 24_000_000, 4, "claude-sonnet-5-5", 3000), p("data-pipeline", 8, 15_000_000, 3, "claude-opus-5-5", 90000)]

        let code = ScheduledMessage.CodeTarget(projectPath: "/Users/you/code/api-server", projectName: "api-server", sessionId: "demo",
                                               sessionTitle: "Fix flaky integration tests", permissionMode: "acceptEdits")
        var waiting = ScheduledMessage(conversationId: nil, conversationName: "api-server · Fix flaky integration tests",
                                       text: "Continue where you left off: finish the retry logic and run the full test suite.",
                                       trigger: .afterReset(windowId: "session", label: "5-hour"), code: code, now: now)
        waiting.fireAt = sessionReset.addingTimeInterval(60)
        var docs = code; docs.projectName = "docs-site"; docs.projectPath = "/Users/you/code/docs-site"; docs.sessionId = nil
        var done = ScheduledMessage(conversationId: nil, conversationName: "docs-site · new session",
                                    text: "Update the API reference for the new endpoints.", trigger: .at(now.addingTimeInterval(-6 * h)), code: docs, now: now)
        done.state = .done; done.finishedAt = now.addingTimeInterval(-5.5 * h); done.detail = "Finished."

        return DemoData(now: now, account: AccountInfo(orgId: "demo", orgName: nil, tier: .max5x, flags: FeatureFlags()),
                        usage: usage, history: history, efficiency: eff, codeSession: session, codeWeek: week, jobs: [waiting, done])
    }
}

/// Renders the app's real SwiftUI views with DemoData to PNGs, light and dark.
@MainActor enum ScreenshotRenderer {
    static func run(into dir: URL) {
        // Never touch the real data folder or settings.
        AppPaths.supportOverride = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-demo-\(UUID().uuidString)")
        UserDefaults.standard.removePersistentDomain(forName: "ClaudeUsageBar.demo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = AppModel(demo: true)
        model.settings.recentChats = 0
        model.settings.showPercentInMenuBar = true
        model.loadDemo(.make())
        model.scheduler.loadDemo(DemoData.make().jobs)

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            render(PopoverView(), model: model, size: CGSize(width: 380, height: 0), dark: dark, to: dir.appendingPathComponent("popover\(suffix).png"))
            model.detailsTab = "efficiency"
            render(EfficiencyTab().padding(16), model: model, size: CGSize(width: 720, height: 560), dark: dark, to: dir.appendingPathComponent("efficiency\(suffix).png"))
            // Same chart with an off-peak "Decreased limits?" window clicked.
            let flagged = model.efficiency.last { s in
                s.finished && !s.mostlyPeak && EfficiencyAnalyzer.verdict(for: s, among: model.efficiency)?.kind == .tighter
            }
            render(EfficiencyTab(selected: flagged?.resetsAt).padding(16), model: model, size: CGSize(width: 720, height: 640), dark: dark,
                   to: dir.appendingPathComponent("efficiency-detail\(suffix).png"))
            render(HistoryTab().padding(16), model: model, size: CGSize(width: 720, height: 480), dark: dark, to: dir.appendingPathComponent("history\(suffix).png"))
        }
        UserDefaults.standard.removePersistentDomain(forName: "ClaudeUsageBar.demo")
        try? FileManager.default.removeItem(at: AppPaths.support)
        print("Rendered screenshots to \(dir.path)")
    }

    /// Hosts the view in a real (off-screen) window so native buttons and pickers draw too, lets
    /// it lay out, then snapshots the window's content at 2×.
    private static func render<V: View>(_ view: V, model: AppModel, size: CGSize, dark: Bool, to url: URL) {
        let content = view
            .environmentObject(model).environmentObject(model.settings).environmentObject(model.scheduler)
            .frame(width: size.width, height: size.height > 0 ? size.height : nil)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        let fit = host.fittingSize
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height > 0 ? size.height : fit.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))   // let charts and async layout settle
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * 2), pixelsHigh: Int(frame.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = frame.size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
