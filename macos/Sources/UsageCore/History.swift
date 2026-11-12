import Foundation

/// One saved reading of every usage window, e.g. `["session": 24, "weekly_all": 40]`.
public struct HistoryPoint: Codable, Sendable, Equatable {
    public var t: Date
    public var v: [String: Double]
    /// Reset time of each window (identifies which 5-hour window a reading belongs to). Optional: older lines lack it.
    public var r: [String: Date]?
    /// Weekly usage split by product, e.g. ["Claude Code": 52, "Cowork": 48]. Optional.
    public var b: [String: Double]?
    public init(t: Date, v: [String: Double], r: [String: Date]? = nil, b: [String: Double]? = nil) {
        self.t = t; self.v = v; self.r = r; self.b = b
    }
}

/// Local usage history: one JSON line per point in `history.jsonl`. Nothing leaves the Mac.
/// A point is recorded when any percentage changes, or every `heartbeat` otherwise, so the chart
/// has flat segments without a line per refresh.
public struct UsageHistory: Sendable {
    public private(set) var points: [HistoryPoint]
    public var retention: TimeInterval
    public var heartbeat: TimeInterval

    /// Kept for about 13 months: the point is to compare against your own long-term normal.
    public init(points: [HistoryPoint] = [], retention: TimeInterval = 400 * 86400, heartbeat: TimeInterval = 30 * 60) {
        self.points = points.sorted { $0.t < $1.t }
        self.retention = retention; self.heartbeat = heartbeat
    }

    /// Returns true when the point was kept (the caller then appends it to disk).
    @discardableResult
    public mutating func record(_ values: [String: Double], resets: [String: Date]? = nil, breakdown: [String: Double]? = nil,
                                at now: Date) -> Bool {
        guard !values.isEmpty else { return false }
        if let last = points.last {
            if now < last.t { return false }
            let same = last.v == values && last.b == breakdown && last.r?.mapValues { $0.timeIntervalSince1970.rounded() } == resets?.mapValues { $0.timeIntervalSince1970.rounded() }
            if same, now.timeIntervalSince(last.t) < heartbeat { return false }
        }
        points.append(HistoryPoint(t: now, v: values, r: resets, b: breakdown))
        return true
    }

    /// Drops points older than the retention period. Returns true when anything was removed.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-retention)
        let before = points.count
        points.removeAll { $0.t < cutoff }
        return points.count != before
    }

    public func points(since: Date) -> [HistoryPoint] { points.filter { $0.t >= since } }

    /// Window ids that appear in the history, most recent first-seen order.
    public var windowIds: [String] {
        var seen: [String] = []
        for p in points.reversed() { for k in p.v.keys.sorted() where !seen.contains(k) { seen.append(k) } }
        return seen
    }

    // MARK: JSON lines

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public static func line(_ p: HistoryPoint) -> String {
        (try? String(decoding: encoder.encode(p), as: UTF8.self)) ?? ""
    }

    /// Bad lines are skipped, so a half-written last line can't lose the file.
    public static func parse(_ text: String) -> [HistoryPoint] {
        text.split(separator: "\n").compactMap { try? decoder.decode(HistoryPoint.self, from: Data($0.utf8)) }
    }

    public func serialized() -> String { points.map(Self.line).joined(separator: "\n") + (points.isEmpty ? "" : "\n") }
}
