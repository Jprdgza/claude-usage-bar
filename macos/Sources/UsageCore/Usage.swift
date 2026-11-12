import Foundation

/// green < 50, yellow 50–80, red > 80 (the spec's thresholds, not the extension's 90 %).
public enum UsageLevel: Sendable, Equatable {
    case low, medium, high
    public static func of(_ percent: Double) -> UsageLevel {
        if percent > 80 { return .high }
        if percent >= 50 { return .medium }
        return .low
    }
}

public struct Pace: Sendable, Equatable {
    /// Linear extrapolation of the current rate to the reset time. Can exceed 100.
    public var projectedPercent: Double
    /// When 100 % is reached at the current rate, if that happens before the reset.
    public var hitsLimitAt: Date?
    /// How far into the window we are, 0–1.
    public var elapsedFraction: Double
}

public struct UsageWindow: Identifiable, Sendable, Equatable {
    /// Stable id: the new format's `kind` (+ `:model` when scoped), legacy keys mapped onto the
    /// same ids, unknown keys used as-is.
    public var id: String
    public var label: String
    public var percent: Double
    public var resetsAt: Date?
    /// Window length when known (from config, or inferred from a legacy key like `five_hour`).
    public var windowLength: TimeInterval?
    /// Key into `estimatedCaps[tier]` (e.g. "session", "weekly:sonnet"); nil = no estimate.
    public var capKey: String?
    public var exceeded: Bool

    public var level: UsageLevel { UsageLevel.of(percent) }

    public init(id: String, label: String, percent: Double, resetsAt: Date?, windowLength: TimeInterval?,
                capKey: String?, exceeded: Bool = false) {
        self.id = id; self.label = label; self.percent = percent; self.resetsAt = resetsAt
        self.windowLength = windowLength; self.capKey = capKey; self.exceeded = exceeded
    }

    /// Nil when the window length is unknown, the reset is in the past, or less than
    /// `minElapsedFraction` of the window has elapsed (too early to extrapolate meaningfully).
    public func pace(now: Date, minElapsedFraction: Double = 0.05) -> Pace? {
        guard let length = windowLength, length > 0, let reset = resetsAt else { return nil }
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0, remaining <= length * 1.01 else { return nil }
        let elapsed = max(0, length - remaining)
        guard elapsed >= length * minElapsedFraction else { return nil }
        let projected = percent * length / elapsed
        var hits: Date? = nil
        if percent > 0, projected >= 100 {
            let start = reset.addingTimeInterval(-length)
            hits = start.addingTimeInterval(elapsed * 100 / percent)
        }
        return Pace(projectedPercent: projected, hitsLimitAt: hits, elapsedFraction: elapsed / length)
    }
}

/// Extra usage / spend, all amounts in minor units (cents).
public struct ExtraUsage: Sendable, Equatable {
    public var monthlyLimitCents: Int
    public var usedCents: Int
    public var balanceCents: Int?

    public var remainingCents: Int {
        let monthly = max(0, monthlyLimitCents - usedCents)
        guard let balance = balanceCents else { return monthly }
        return min(monthly, balance)
    }
    public var effectiveTotalCents: Int { usedCents + remainingCents }
    public var percent: Double {
        let total = effectiveTotalCents
        return total > 0 ? Double(usedCents) / Double(total) * 100 : 0
    }
}

/// A split of one window's usage by product (e.g. `seven_day_breakdown`: Claude Code / Chats / Cowork).
public struct UsageBreakdown: Sendable, Equatable, Identifiable {
    public struct Row: Sendable, Equatable {
        public var name: String; public var percent: Double
        public init(name: String, percent: Double) { self.name = name; self.percent = percent }
    }
    public var id: String
    public var label: String
    public var rows: [Row]
    public init(id: String, label: String, rows: [Row]) { self.id = id; self.label = label; self.rows = rows }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var windows: [UsageWindow]
    public var extra: ExtraUsage?
    /// Every top-level `*_breakdown` object with a `rows` array, rendered generically.
    public var breakdowns: [UsageBreakdown] = []
    /// Top-level keys we saw but couldn't interpret, for the debug log.
    public var ignoredKeys: [String]
    public var format: Format

    public enum Format: String, Sendable { case limitsArray, legacyTopLevel, empty }

    public init(windows: [UsageWindow], extra: ExtraUsage? = nil, breakdowns: [UsageBreakdown] = [],
                ignoredKeys: [String] = [], format: Format = .limitsArray) {
        self.windows = windows; self.extra = extra; self.breakdowns = breakdowns
        self.ignoredKeys = ignoredKeys; self.format = format
    }

    /// claude.ai reports nothing at all (the free plan answers 200 with all-null fields).
    public var isEmpty: Bool { windows.isEmpty && extra == nil }

    /// The 5-hour window, wherever it came from.
    public var session: UsageWindow? {
        windows.first { $0.id == "session" } ?? windows.first { ($0.windowLength ?? 0) == 5 * 3600 }
    }
}

public enum UsageDecoder {
    public static func decode(_ json: JSON, credits: JSON? = nil, config: AppConfig) -> UsageSnapshot {
        var ignored: [String] = []
        var windows: [UsageWindow] = []
        var format: UsageSnapshot.Format = .empty

        if let limits = json["limits"].array, !limits.isEmpty {
            format = .limitsArray
            for entry in limits {
                if let w = window(fromLimitEntry: entry, config: config) { windows.append(w) }
            }
        } else if let obj = json.object {
            // Legacy format: every top-level object that has a numeric `utilization` is a window,
            // known key or not.
            let known = config.legacyWindowKeys
            let keys = obj.keys.sorted { a, b in
                let ia = legacyOrder.firstIndex(of: a) ?? Int.max, ib = legacyOrder.firstIndex(of: b) ?? Int.max
                return ia != ib ? ia < ib : a < b
            }
            for key in keys {
                let value = obj[key]!
                // Only objects can be windows; known non-window objects (spend, extra usage, breakdowns) are skipped.
                guard value.object != nil, !nonWindowKeys.contains(key), !key.hasSuffix("_breakdown") else { continue }
                guard let pct = value["utilization"].number ?? value["percent"].number else {
                    ignored.append(key)
                    continue
                }
                format = .legacyTopLevel
                if let mapped = known[key] {
                    windows.append(makeWindow(kind: mapped.kind, model: mapped.model, percent: pct,
                                              resetsAt: value["resets_at"].date, config: config))
                } else {
                    windows.append(UsageWindow(id: key, label: prettify(key), percent: pct,
                                               resetsAt: value["resets_at"].date,
                                               windowLength: inferLength(fromKey: key), capKey: nil))
                }
            }
        }

        return UsageSnapshot(windows: windows, extra: extraUsage(json, credits: credits), breakdowns: breakdowns(json, config: config),
                             ignoredKeys: ignored, format: windows.isEmpty ? .empty : format)
    }

    static func breakdowns(_ json: JSON, config: AppConfig) -> [UsageBreakdown] {
        guard let obj = json.object else { return [] }
        return obj.keys.sorted().compactMap { key in
            guard key.hasSuffix("_breakdown"), let rows = obj[key]?["rows"].array else { return nil }
            let parsed = rows.compactMap { r -> UsageBreakdown.Row? in
                guard let pct = r["percent"].number else { return nil }
                return UsageBreakdown.Row(name: r["display_name"].string ?? r["key"].string.map(prettify) ?? "?", percent: pct)
            }
            guard !parsed.isEmpty else { return nil }
            let base = String(key.dropLast("_breakdown".count))
            let windowLabel = config.legacyWindowKeys[base].flatMap { config.windowKinds[$0.kind]?.label } ?? prettify(base)
            return UsageBreakdown(id: key, label: "\(windowLabel) by product", rows: parsed)
        }
    }

    static let legacyOrder = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]
    static let nonWindowKeys: Set<String> = ["limits", "spend", "extra_usage"]

    static func window(fromLimitEntry entry: JSON, config: AppConfig) -> UsageWindow? {
        guard let kind = entry["kind"].string,
              let pct = entry["percent"].number ?? entry["utilization"].number else { return nil }
        let model = entry["scope"]["model"]["display_name"].string ?? entry["scope"]["model"]["name"].string
        let exceeded = ["exceeded", "exceeded_limit"].contains(entry["status"].string ?? "")
        var w = makeWindow(kind: kind, model: model, percent: pct, resetsAt: entry["resets_at"].date, config: config)
        w.exceeded = exceeded
        return w
    }

    static func makeWindow(kind: String, model: String?, percent: Double, resetsAt: Date?, config: AppConfig) -> UsageWindow {
        let meta = config.windowKinds[kind]
        let baseLabel = meta?.label ?? prettify(kind)
        let label = model.map { "\(baseLabel) – \($0)" } ?? baseLabel
        let id = model.map { "\(kind):\($0.lowercased())" } ?? kind
        let capKey = meta?.capKey.map { base in model.map { "\(base):\($0.lowercased())" } ?? base }
        let length = meta?.hours.map { $0 * 3600 } ?? inferLength(fromKey: kind)
        return UsageWindow(id: id, label: label, percent: percent, resetsAt: resetsAt,
                           windowLength: length, capKey: capKey)
    }

    static func extraUsage(_ json: JSON, credits: JSON?) -> ExtraUsage? {
        let balance = credits?["amount"].int
        let spend = json["spend"]
        if spend["enabled"].bool == true {
            let limit = spend["limit"]["amount_minor"].int ?? spend["cap"]["money"]["amount_minor"].int ?? 0
            return ExtraUsage(monthlyLimitCents: limit, usedCents: spend["used"]["amount_minor"].int ?? 0,
                              balanceCents: balance)
        }
        let legacy = json["extra_usage"]
        if legacy["is_enabled"].bool == true {
            return ExtraUsage(monthlyLimitCents: legacy["monthly_limit"].int ?? 0,
                              usedCents: legacy["used_credits"].int ?? 0, balanceCents: balance)
        }
        return nil
    }

    /// "seven_day_oauth_apps" -> "Seven day oauth apps"
    public static func prettify(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ":", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "five_hour..." -> 5h, "seven_day..." -> 7d, "24_hour" -> 24h. Nil if it doesn't start that way.
    public static func inferLength(fromKey key: String) -> TimeInterval? {
        let parts = key.lowercased().split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                       "eight": 8, "nine": 9, "ten": 10, "twelve": 12, "thirty": 30]
        guard let n = Double(parts[0]) ?? numbers[parts[0]].map(Double.init) else { return nil }
        switch parts[1] {
        case "hour", "hours", "h": return n * 3600
        case "day", "days", "d": return n * 86400
        case "week", "weeks": return n * 7 * 86400
        default: return nil
        }
    }
}

public enum UsageMath {
    public static func isPeak(_ now: Date, config: AppConfig) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let weekday = cal.component(.weekday, from: now) // 1 = Sunday
        if config.peakHours.weekdaysOnly, weekday == 1 || weekday == 7 { return false }
        let hour = cal.component(.hour, from: now)
        return hour >= config.peakHours.startHourUTC && hour < config.peakHours.endHourUTC
    }

    /// Estimated token capacity of a window for a tier. These caps are the extension's
    /// self-described "napkin math", so everything derived from them is an estimate.
    public static func cap(for window: UsageWindow, tier: Tier, now: Date, config: AppConfig) -> Double? {
        guard let key = window.capKey else { return nil }
        let caps = config.estimatedCaps[tier.rawValue] ?? [:]
        guard var cap = caps[key] else { return nil }
        if key == "session", isPeak(now, config: config) { cap /= config.peakHours.sessionCapDivisor }
        return cap
    }

    public static func sessionCap(tier: Tier, now: Date, config: AppConfig) -> Double? {
        guard var cap = config.estimatedCaps[tier.rawValue]?["session"] else { return nil }
        if isPeak(now, config: config) { cap /= config.peakHours.sessionCapDivisor }
        return cap
    }

    /// Messages left before the most constraining window runs out, at `messageCost` weighted tokens.
    public static func messagesLeft(_ usage: UsageSnapshot, tier: Tier, messageCost: Double,
                                    now: Date, config: AppConfig) -> (windowId: String, messages: Double)? {
        guard messageCost > 0 else { return nil }
        var best: (String, Double)? = nil
        for w in usage.windows {
            guard let cap = cap(for: w, tier: tier, now: now, config: config) else { continue }
            let left = max(0, 100 - w.percent) / 100 * cap / messageCost
            if best == nil || left < best!.1 { best = (w.id, left) }
        }
        return best
    }
}
