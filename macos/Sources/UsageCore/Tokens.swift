import Foundation

public struct TokenCount: Sendable, Equatable {
    public var value: Int
    public var exact: Bool
    public init(_ value: Int, exact: Bool) { self.value = value; self.exact = exact }
}

public protocol TokenCounting: Sendable {
    func countText(_ text: String) async -> TokenCount
    /// Humans and assistants are interleaved h0, a0, h1, a1… (as the extension does).
    func countConversation(humans: [String], assistants: [String]) async -> TokenCount
}

public protocol FileTokenCounting: Sendable {
    func count(file: JSON) async -> TokenCount
}

/// Local, offline approximation of Claude's tokenizer. There's no public Claude tokenizer, and the
/// extension's own fallback (o200k × 1.4) is itself an approximation; this mimics o200k's
/// pre-tokenization (words keep their leading space, digits split in groups of 3, punctuation
/// runs, one token per CJK character) and applies the same 1.4 multiplier. Always `exact: false`.
public struct LocalTokenEstimator: TokenCounting, Sendable {
    public var multiplier: Double

    public init(multiplier: Double = 1.4) { self.multiplier = multiplier }

    public func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(baseTokens(text)) * multiplier).rounded())
    }

    /// o200k-like token count before the multiplier.
    public func baseTokens(_ text: String) -> Int {
        var tokens = 0
        var letters = 0, digits = 0, punct = 0, spaces = 0
        func flushLetters() { if letters > 0 { tokens += max(1, Int((Double(letters) / 4.6).rounded(.up))); letters = 0 } }
        func flushDigits() { if digits > 0 { tokens += (digits + 2) / 3; digits = 0 } }
        func flushPunct() { if punct > 0 { tokens += (punct + 1) / 2; punct = 0 } }
        func flushSpaces() {
            // A single space is absorbed by the following word; longer runs (indentation) cost.
            if spaces > 1 { tokens += max(1, spaces / 4) }
            spaces = 0
        }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                flushLetters(); flushDigits(); flushPunct(); flushSpaces(); tokens += 1
            } else if scalar == " " {
                flushLetters(); flushDigits(); flushPunct(); spaces += 1
            } else if (0x30...0x39).contains(v) {
                flushLetters(); flushPunct(); flushSpaces(); digits += 1
            } else if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                flushDigits(); flushPunct(); flushSpaces(); letters += 1
            } else if v < 0x80 {
                flushLetters(); flushDigits(); flushSpaces(); punct += 1
            } else if isWide(v) {
                flushLetters(); flushDigits(); flushPunct(); flushSpaces(); tokens += 1
            } else {
                // Accented Latin, Cyrillic, Greek…: roughly one token per 2–3 letters.
                flushDigits(); flushPunct(); flushSpaces(); letters += 2
            }
        }
        flushLetters(); flushDigits(); flushPunct(); flushSpaces()
        return tokens
    }

    private func isWide(_ v: UInt32) -> Bool {
        (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x3040...0x30FF).contains(v) || (0x1F000...0x1FAFF).contains(v) || (0x20000...0x2FFFF).contains(v)
    }

    public func countText(_ text: String) async -> TokenCount { TokenCount(estimate(text), exact: false) }

    public func countConversation(humans: [String], assistants: [String]) async -> TokenCount {
        TokenCount((humans + assistants).reduce(0) { $0 + estimate($1) }, exact: false)
    }
}

/// claude.ai's own metadata, the extension's formula: images ≈ w·h/750 capped at 1600; documents use
/// claude.ai's `token_count` when present, else a per-page figure.
public struct EstimatedFileCounter: FileTokenCounting, Sendable {
    public var config: AppConfig
    public init(config: AppConfig) { self.config = config }

    public func count(file: JSON) async -> TokenCount { TokenCount(estimate(file), exact: false) }

    public func estimate(_ file: JSON) -> Int {
        let t = config.tokens
        switch file["file_kind"].string {
        case "image":
            let w = file["preview_asset"]["image_width"].number ?? 0
            let h = file["preview_asset"]["image_height"].number ?? 0
            return min(t.imageTokensMax, Int((w * h / t.imageTokensPerPixelDivisor).rounded(.up)))
        case "document":
            if let tc = file["document_asset"]["token_count"].int { return tc }
            return t.documentTokensPerPage * (file["document_asset"]["page_count"].int ?? 0)
        default:
            return 0
        }
    }
}
