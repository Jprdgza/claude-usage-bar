import ServiceManagement
import Foundation
import Security
import SwiftUI
import UsageCore

/// Secrets live only here: the claude.ai `sessionKey` and the optional Anthropic API key.
enum Keychain {
    static let service = "local.claude-usage-bar"
    enum Account: String { case sessionKey, anthropicAPIKey }

    static func get(_ account: Account) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account.rawValue, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: Account) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account.rawValue, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: Account) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account.rawValue]
        SecItemDelete(q as CFDictionary)
    }
}

/// In-memory ring buffer shown in Settings → Debug log. Never receives secrets or message text.
@MainActor final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func add(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        NSLog("[ClaudeUsageBar] %@", message)
        appendToFile(line)
    }

    /// Mirrors the log to ~/Library/Application Support/ClaudeUsageBar/debug.log (rotated at 512 KB).
    /// Same content as the in-app view: no cookies, keys or message text are ever logged.
    private func appendToFile(_ line: String) {
        let url = AppPaths.support.appendingPathComponent("debug.log")
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
            let old = AppPaths.support.appendingPathComponent("debug.previous.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    func clear() { lines.removeAll() }
}

/// Non-secret preferences (UserDefaults).
@MainActor final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard

    @Published var refreshSeconds: Int { didSet { d.set(refreshSeconds, forKey: "refreshSeconds") } }
    @Published var thresholdsText: String { didSet { d.set(thresholdsText, forKey: "thresholds") } }
    @Published var recentChats: Int { didSet { d.set(recentChats, forKey: "recentChats") } }
    @Published var showPercentInMenuBar: Bool { didSet { d.set(showPercentInMenuBar, forKey: "showPercent") } }
    @Published var thresholdNotifications: Bool { didSet { d.set(thresholdNotifications, forKey: "thresholdNotifications") } }
    @Published var notifyReset: Bool { didSet { d.set(notifyReset, forKey: "notifyReset") } }
    @Published var resetOnlyAfterWarning: Bool { didSet { d.set(resetOnlyAfterWarning, forKey: "resetOnlyAfterWarning") } }
    @Published var checkDesktopUpdates: Bool { didSet { d.set(checkDesktopUpdates, forKey: "checkDesktopUpdates") } }
    @Published var keepAwakeForScheduled: Bool { didSet { d.set(keepAwakeForScheduled, forKey: "keepAwakeForScheduled") } }
    @Published var globalShortcut: Bool { didSet { d.set(globalShortcut, forKey: "globalShortcut") } }
    @Published var showClaudeCode: Bool { didSet { d.set(showClaudeCode, forKey: "showClaudeCode") } }
    @Published var awakeWhileClaudeWorks: Bool { didSet { d.set(awakeWhileClaudeWorks, forKey: "awakeWhileClaudeWorks") } }
    @Published var lidClosedWhileClaudeWorks: Bool { didSet { d.set(lidClosedWhileClaudeWorks, forKey: "lidClosedWhileClaudeWorks") } }
    @Published var lidOnlyOnPower: Bool { didSet { d.set(lidOnlyOnPower, forKey: "lidOnlyOnPower") } }
    @Published var lidBatteryFloor: Int { didSet { d.set(lidBatteryFloor, forKey: "lidBatteryFloor") } }
    @Published var lidMaxHours: Int { didSet { d.set(lidMaxHours, forKey: "lidMaxHours") } }

    init() {
        d.register(defaults: ["refreshSeconds": 60, "thresholds": "80, 95", "recentChats": 5, "showPercent": true,
                              "thresholdNotifications": true, "notifyReset": true, "resetOnlyAfterWarning": true,
                              "checkDesktopUpdates": true, "keepAwakeForScheduled": true, "globalShortcut": true,
                              "showClaudeCode": true, "awakeWhileClaudeWorks": true, "lidClosedWhileClaudeWorks": false,
                              "lidOnlyOnPower": false, "lidBatteryFloor": 25, "lidMaxHours": 8])
        refreshSeconds = max(60, d.integer(forKey: "refreshSeconds"))
        thresholdsText = d.string(forKey: "thresholds") ?? "80, 95"
        recentChats = d.integer(forKey: "recentChats")
        showPercentInMenuBar = d.bool(forKey: "showPercent")
        thresholdNotifications = d.bool(forKey: "thresholdNotifications")
        notifyReset = d.bool(forKey: "notifyReset")
        resetOnlyAfterWarning = d.bool(forKey: "resetOnlyAfterWarning")
        checkDesktopUpdates = d.bool(forKey: "checkDesktopUpdates")
        keepAwakeForScheduled = d.bool(forKey: "keepAwakeForScheduled")
        globalShortcut = d.bool(forKey: "globalShortcut")
        showClaudeCode = d.bool(forKey: "showClaudeCode")
        awakeWhileClaudeWorks = d.bool(forKey: "awakeWhileClaudeWorks")
        lidClosedWhileClaudeWorks = d.bool(forKey: "lidClosedWhileClaudeWorks")
        lidOnlyOnPower = d.bool(forKey: "lidOnlyOnPower")
        lidBatteryFloor = d.integer(forKey: "lidBatteryFloor")
        lidMaxHours = max(1, d.integer(forKey: "lidMaxHours"))
    }

    /// "80, 95" -> [80, 95]; invalid entries dropped, clamped to 1…100.
    var thresholds: [Double] {
        thresholdsText.split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0) }.filter { $0 > 0 && $0 <= 100 }.sorted()
    }

    var refreshInterval: TimeInterval { TimeInterval(max(60, refreshSeconds)) }
}

enum AppPaths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var configOverride: URL { support.appendingPathComponent("endpoints.json") }
    static var configDefaultCopy: URL { support.appendingPathComponent("endpoints.default.json") }
    static var samples: URL {
        let u = support.appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: n % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(n) / 1e6) }
        if n >= 10_000 { return String(format: "%.0fK", Double(n) / 1e3) }
        return tokens(n)
    }

    static func percent(_ p: Double) -> String { String(format: p < 10 && p != floor(p) ? "%.1f%%" : "%.0f%%", p) }

    static func countdown(to date: Date?, now: Date) -> String {
        guard let date else { return "–" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "Resetting…" }
        let m = Int((s / 60).rounded(.up))
        if m < 1 { return "<1m" }
        let h = m / 60, mm = m % 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    static func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

extension UsageLevel {
    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
    var nsColor: NSColor {
        switch self {
        case .low: return .systemGreen
        case .medium: return .systemYellow
        case .high: return .systemRed
        }
    }
}

// MARK: Start at login


/// Registers the app as a login item via SMAppService (shows up in System Settings → General → Login Items).
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    private init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    /// On the very first launch, turn start-at-login on (the user asked for it as the default).
    /// After that the user's choice in Settings wins.
    func enableOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { refresh(); return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
            DebugLog.shared.add(on ? "Start at login: on" : "Start at login: off")
        } catch {
            lastError = error.localizedDescription
            DebugLog.shared.add("Start at login: couldn't \(on ? "enable" : "disable"): \(error.localizedDescription)")
        }
        refresh()
    }
}
