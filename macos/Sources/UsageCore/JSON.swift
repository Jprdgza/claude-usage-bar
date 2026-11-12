import Foundation

/// A dynamically-typed JSON value. Every claude.ai response is decoded into this first, then read
/// with optional accessors, so a missing field, a renamed field, or an unknown key can never fail
/// a decode: it just reads as `nil` / `.null`. That is the whole robustness strategy for
/// undocumented endpoints.
public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    public static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    public static func parse(_ string: String) throws -> JSON {
        try parse(Data(string.utf8))
    }

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { number.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var arrayOrEmpty: [JSON] { array ?? [] }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// JS-style truthiness, for porting `if (x)` checks faithfully.
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// ISO-8601 string (with or without fractional seconds / offset) or unix seconds.
    public var date: Date? {
        if let n = number { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        guard let s = string else { return nil }
        return JSON.parseISODate(s)
    }

    public static func parseISODate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    /// Compact serialization, used to count tool-call inputs the way the extension does
    /// (`JSON.stringify(content.input)`).
    public var serialized: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let d = try? enc.encode(self) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}
