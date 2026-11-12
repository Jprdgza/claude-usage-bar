import Foundation

/// "How much work did 1 % of the 5-hour limit buy?" per 5-hour window, from two local sources:
///  - the usage history (how far the 5-hour % moved, and how much of the weekly growth was Claude Code,
///    from claude.ai's own product breakdown), and
///  - Claude Code's logs (exactly how many tokens were used in the same time span).
/// Comparing a window against your own long-term normal shows when the same work suddenly costs
/// more of the limit, e.g. during peak hours or after a limit change.
public struct EfficiencySample: Codable, Identifiable, Sendable, Equatable {
    public var id: Date { resetsAt }
    public var resetsAt: Date
    public var start: Date            // first reading in this window
    public var end: Date              // last reading
    public var sessionDelta: Double   // 5-hour % points gained between the readings
    /// Share of the usage in this span that was Claude Code (0–1), from the weekly product breakdown.
    public var codeFraction: Double
    public var codeCost: Double       // price-weighted Claude Code tokens (see CodeUsageEntry.cost)
    public var codeTokens: Int
    public var peakFraction: Double   // share of that cost spent during peak hours
    public var finished: Bool

    public static let minAttributedDelta = 3.0

    /// 5-hour % points that Claude Code accounts for.
    public var attributedDelta: Double { sessionDelta * codeFraction }

    /// Price-weighted tokens per 1 % of the 5-hour limit. Nil when too little moved to measure
    /// (percentages are whole numbers, so a 1–2 point move is mostly rounding).
    public var costPerPercent: Double? {
        guard attributedDelta >= Self.minAttributedDelta, codeCost > 0 else { return nil }
        return codeCost / attributedDelta
    }
    public var tokensPerPercent: Double? {
        guard attributedDelta >= Self.minAttributedDelta, codeTokens > 0 else { return nil }
        return Double(codeTokens) / attributedDelta
    }
    public var mostlyPeak: Bool { peakFraction >= 0.5 }
}

public struct EfficiencyVerdict: Sendable, Equatable {
    public enum Kind: String, Sendable { case tighter, normal, looser }
    public var kind: Kind
    /// This window's work-per-1 % divided by your normal (1.0 = normal, 0.6 = 40 % less work per 1 %).
    public var ratio: Double
    public var baselineCount: Int
    /// The baseline was other peak-hour windows (so peak hours alone don't explain it).
    public var comparedWithPeak: Bool
}

public enum EfficiencyAnalyzer {
    public static let tighterBelow = 0.7
    public static let looserAbove = 1.4
    public static let minBaseline = 4

    /// One sample per 5-hour window found in the history (identified by its reset time).
    public static func samples(points: [HistoryPoint], entries: [CodeUsageEntry], config: AppConfig, now: Date) -> [EfficiencySample] {
        let withReset = points.filter { $0.r?["session"] != nil && $0.v["session"] != nil }
        let groups = Dictionary(grouping: withReset) { ($0.r!["session"]!.timeIntervalSince1970 / 60).rounded() }
        let sortedEntries = entries.sorted { $0.time < $1.time }
        return groups.compactMap { _, pts -> EfficiencySample? in
            let pts = pts.sorted { $0.t < $1.t }
            guard pts.count >= 2, let first = pts.first, let last = pts.last,
                  let s0 = first.v["session"], let s1 = last.v["session"], let reset = last.r?["session"] else { return nil }
            let delta = max(0, s1 - s0)
            guard let fraction = codeFraction(first, last) else { return nil }
            let span = sortedEntries.filter { $0.time > first.t && $0.time <= last.t }
            var cost = 0.0, peakCost = 0.0, tokens = 0
            for e in span {
                let c = e.cost(config: config)
                cost += c; tokens += e.totalTokens
                if UsageMath.isPeak(e.time, config: config) { peakCost += c }
            }
            return EfficiencySample(resetsAt: reset, start: first.t, end: last.t, sessionDelta: delta, codeFraction: fraction,
                                    codeCost: cost, codeTokens: tokens, peakFraction: cost > 0 ? peakCost / cost : 0,
                                    finished: reset <= now)
        }
        .sorted { $0.resetsAt < $1.resetsAt }
    }

    /// How much of the weekly growth between two readings was Claude Code. Nil if unknown.
    static func codeFraction(_ a: HistoryPoint, _ b: HistoryPoint) -> Double? {
        guard let w0 = a.v["weekly_all"], let w1 = b.v["weekly_all"], let b0 = a.b, let b1 = b.b,
              let k = b1.keys.first(where: { $0.localizedCaseInsensitiveContains("code") }),
              let c0 = b0[k], let c1 = b1[k] else { return nil }
        let dw = w1 - w0
        if dw < 0 { return nil }                     // weekly reset in between
        if dw == 0 { return c1 >= 99 ? 1 : nil }     // nothing measurable; only trust "all Code"
        let dc = w1 * c1 / 100 - w0 * c0 / 100
        return min(1, max(0, dc / dw))
    }

    public static func medianPublic(_ xs: [Double]) -> Double? { median(xs) }

    /// Median of a list.
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(); let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Compares one window with your normal: the median of the finished windows in the 60 days
    /// before it. Peak-hour windows are compared with other peak-hour windows when there are
    /// enough, so the known peak-hour tightening isn't mistaken for a change.
    public static func verdict(for sample: EfficiencySample, among all: [EfficiencySample]) -> EfficiencyVerdict? {
        guard let value = sample.costPerPercent else { return nil }
        let window = all.filter { $0.id != sample.id && $0.finished && $0.costPerPercent != nil &&
            $0.resetsAt < sample.resetsAt.addingTimeInterval(1) && $0.resetsAt > sample.resetsAt.addingTimeInterval(-60 * 86400) }
        var pool = window
        var peakBaseline = false
        if sample.mostlyPeak {
            let peak = window.filter(\.mostlyPeak)
            if peak.count >= minBaseline { pool = peak; peakBaseline = true }
        } else {
            let off = window.filter { !$0.mostlyPeak }
            if off.count >= minBaseline { pool = off }
        }
        guard pool.count >= minBaseline, let base = median(pool.compactMap(\.costPerPercent)), base > 0 else { return nil }
        let ratio = value / base
        let kind: EfficiencyVerdict.Kind = ratio < tighterBelow ? .tighter : ratio > looserAbove ? .looser : .normal
        return EfficiencyVerdict(kind: kind, ratio: ratio, baselineCount: pool.count, comparedWithPeak: peakBaseline)
    }

    /// Merge freshly computed samples into the long-term store: new windows are added, unfinished
    /// ones updated, and finished ones are kept even after Claude Code deletes old logs.
    public static func merge(stored: [EfficiencySample], fresh: [EfficiencySample]) -> [EfficiencySample] {
        var byId = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in fresh {
            if let old = byId[s.id], old.finished, old.end >= s.end { continue }   // already final
            byId[s.id] = s
        }
        return byId.values.sorted { $0.resetsAt < $1.resetsAt }
    }

    /// Plain-language explanation for a window.
    public static func explain(_ s: EfficiencySample, verdict v: EfficiencyVerdict?, config: AppConfig) -> String {
        guard s.costPerPercent != nil else {
            return s.attributedDelta < EfficiencySample.minAttributedDelta
                ? "Not enough Claude Code use in this window to measure (needs at least \(Int(EfficiencySample.minAttributedDelta)) points of the 5-hour limit)."
                : "No Claude Code tokens found for this window."
        }
        guard let v else { return "Measured, but there aren't enough earlier windows yet to know your normal (needs \(minBaseline))." }
        let pct = Int((abs(1 - v.ratio) * 100).rounded())
        let peakText = "peak hours (\(peakHoursLocal(config)))"
        switch v.kind {
        case .normal:
            return "About your normal: the same work cost about the usual share of the limit."
        case .looser:
            return "Looser than usual: about \(pct)% more work per 1% of the 5-hour limit."
        case .tighter:
            var t = "Decreased limits? About \(pct)% less work per 1% of the 5-hour limit than your normal."
            if s.mostlyPeak {
                t += v.comparedWithPeak
                    ? " Mostly during \(peakText), and still tighter than your other peak-hour windows, so peak hours alone don't explain it."
                    : " Mostly during \(peakText), when the 5-hour limit is known to be tighter. That's likely most of it."
            } else {
                t += " Mostly outside peak hours, so this isn't the usual peak-hour tightening."
            }
            return t
        }
    }

    /// "Mon–Fri 06:00–12:00" in the Mac's time zone.
    public static func peakHoursLocal(_ config: AppConfig, timeZone: TimeZone = .current) -> String {
        let offset = Double(timeZone.secondsFromGMT()) / 3600
        func local(_ h: Int) -> String {
            let x = (Double(h) + offset).truncatingRemainder(dividingBy: 24)
            let v = x < 0 ? x + 24 : x
            return String(format: "%02d:%02d", Int(v), Int((v - floor(v)) * 60))
        }
        let days = config.peakHours.weekdaysOnly ? "Mon–Fri " : ""
        return days + local(config.peakHours.startHourUTC) + "–" + local(config.peakHours.endHourUTC)
    }

    /// Peak-hour intervals overlapping [from, to], for shading charts.
    public static func peakIntervals(from: Date, to: Date, config: AppConfig) -> [(Date, Date)] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var out: [(Date, Date)] = []
        var day = cal.startOfDay(for: from)
        while day < to {
            let wd = cal.component(.weekday, from: day)
            if !(config.peakHours.weekdaysOnly && (wd == 1 || wd == 7)) {
                let a = day.addingTimeInterval(Double(config.peakHours.startHourUTC) * 3600)
                let b = day.addingTimeInterval(Double(config.peakHours.endHourUTC) * 3600)
                if b > from && a < to { out.append((max(a, from), min(b, to))) }
            }
            day = day.addingTimeInterval(86400)
        }
        return out
    }

    // JSON lines, like history.jsonl.
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    public static func serialize(_ s: [EfficiencySample]) -> String {
        s.compactMap { try? String(decoding: encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }
    public static func parse(_ text: String) -> [EfficiencySample] {
        text.split(separator: "\n").compactMap { try? decoder.decode(EfficiencySample.self, from: Data($0.utf8)) }
    }
}
