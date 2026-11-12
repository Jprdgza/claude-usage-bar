import Foundation
import UserNotifications
import UsageCore

/// Native notifications: threshold warnings (once per window per reset period per threshold) and a
/// scheduled "5-hour limit reset" alert at the window's reset time, so it fires even if polling is
/// paused or the Mac was asleep.
@MainActor final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// nil = unknown/unavailable, true = allowed, false = blocked in System Settings.
    @Published private(set) var allowed: Bool?
    private let log: DebugLog
    private let d = UserDefaults.standard
    private let resetId = "session-reset"

    /// UNUserNotificationCenter crashes in an unbundled binary (`swift run`), so only use it from the .app.
    var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(log: DebugLog) {
        self.log = log
        super.init()
        guard available else { log.add("Notifications unavailable (not running from the .app bundle)"); return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                log.add("Notification permission: \(granted ? "granted" : "denied")\(error.map { " (\($0.localizedDescription))" } ?? "")")
                self.refreshPermission()
            }
        }
    }

    func refreshPermission() {
        guard available else { allowed = nil; return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in self.allowed = ok }
        }
    }

    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func evaluate(_ usage: UsageSnapshot, settings: SettingsStore, now: Date = Date()) {
        guard available else { return }
        var notified = d.dictionary(forKey: "notifiedThresholds") as? [String: Double] ?? [:]
        notified = notified.filter { now.timeIntervalSince1970 - $0.value < 9 * 86400 }
        let thresholds = settings.thresholds

        if settings.thresholdNotifications {
            for w in usage.windows {
                let period = Int(w.resetsAt?.timeIntervalSince1970 ?? 0)
                guard let crossed = thresholds.filter({ w.percent >= $0 }).max() else { continue }
                let key = "\(w.id)|\(period)|\(Int(crossed))"
                if notified[key] != nil { continue }
                // Mark this and every lower threshold so a jump 70 → 96 sends one alert, not two.
                for t in thresholds where t <= crossed { notified["\(w.id)|\(period)|\(Int(t))"] = now.timeIntervalSince1970 }
                let resets = w.resetsAt.map { " Resets in \(Fmt.countdown(to: $0, now: now)) (\(Fmt.clock($0)))." } ?? ""
                post(id: "threshold-\(key)", title: "Claude usage at \(Fmt.percent(w.percent))",
                     body: "\(w.label) passed your \(Int(crossed))% warning.\(resets)")
            }
        }
        d.set(notified, forKey: "notifiedThresholds")

        // Track the session window's peak per reset period, for "only after a warning".
        guard let session = usage.session, let reset = session.resetsAt, reset > now else { return }
        let peakKey = "sessionPeak|\(Int(reset.timeIntervalSince1970))"
        let peak = max(d.double(forKey: peakKey), session.percent)
        d.set(peak, forKey: peakKey)
        let minWarning = thresholds.first ?? 80
        let want = settings.notifyReset && (!settings.resetOnlyAfterWarning || peak >= minWarning)
        scheduleReset(at: reset, enabled: want, now: now)
    }

    private func scheduleReset(at reset: Date, enabled: Bool, now: Date) {
        let center = UNUserNotificationCenter.current()
        let stamp = reset.timeIntervalSince1970
        guard enabled else {
            if d.double(forKey: "scheduledResetAt") != 0 {
                center.removePendingNotificationRequests(withIdentifiers: [resetId])
                d.set(0, forKey: "scheduledResetAt")
            }
            return
        }
        if abs(d.double(forKey: "scheduledResetAt") - stamp) < 30 { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude usage reset"
        content.body = "Your 5-hour limit has reset."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reset.timeIntervalSince(now)), repeats: false)
        center.add(UNNotificationRequest(identifier: resetId, content: content, trigger: trigger))
        d.set(stamp, forKey: "scheduledResetAt")
        log.add("Scheduled reset notification for \(Fmt.clock(reset))")
    }

    func cancelAll() {
        guard available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [resetId])
        d.set(0, forKey: "scheduledResetAt")
    }

    func post(id: String, title: String, body: String) {
        guard available else { log.add("(notification) \(title): \(body)"); return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        log.add("Notified: \(title)")
    }
}

/// After every Claude Desktop update, re-runs the Phase 1 check (FEASIBILITY.md §5) against an
/// isolated throwaway profile: stock Claude should refuse to start with a debugging switch. If it
/// doesn't refuse any more, the CDP overlay approach may have become possible, so say so.
enum DesktopWatcher {
    static let appPath = "/Applications/Claude.app"

    static func installedVersion() -> String? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let d = try? Data(contentsOf: plist),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleShortVersionString"] as? String
    }

    enum Result: Equatable { case stillBlocked, mayBeOpen(String), couldNotRun(String) }

    /// Runs off the main thread. Never touches the user's running Claude or its profile.
    static func probe() async -> Result {
        await Task.detached {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cub-probe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: appPath + "/Contents/MacOS/Claude")
            p.arguments = ["--user-data-dir=\(tmp.path)", "--remote-debugging-port=0", "--remote-address=127.0.0.1"]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return .couldNotRun(error.localizedDescription) }
            for _ in 0..<60 where p.isRunning { usleep(100_000) }
            if p.isRunning {
                p.terminate(); usleep(1_500_000)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                return .mayBeOpen("Claude started with --remote-debugging-port instead of refusing.")
            }
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if p.terminationStatus == 1, stderr.contains("refusing to start") { return .stillBlocked }
            return .mayBeOpen("Exited \(p.terminationStatus) without the usual refusal: \(stderr.prefix(160))")
        }.value
    }
}
