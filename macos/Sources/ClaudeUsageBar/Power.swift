import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac running while Claude Code is working, optionally even with the lid closed.
///
/// - "Claude Code is working" = a Claude Code session log was written in the last 2 minutes, or a
///   scheduled Claude Code job is running.
/// - Awake: a normal "prevent idle sleep" power assertion (no permissions needed).
/// - Lid closed: macOS ignores app power assertions when the lid closes. The only switch is
///   `pmset -a disablesleep 1`, which needs root. The user installs a one-line sudoers rule (with their
///   admin password, once) that allows exactly `pmset -a disablesleep 0` and `… 1`, nothing else. The
///   app turns it on only while Claude Code is working and turns it back off when it stops, when the
///   app quits or launches, on low battery, and after a maximum time.
@MainActor final class PowerManager: ObservableObject {
    static let shared = PowerManager()

    @Published private(set) var claudeWorking = false
    @Published private(set) var lidModeActive = false
    @Published private(set) var helperInstalled = false
    @Published private(set) var lastNote: String?

    weak var model: AppModel?
    private let log = DebugLog.shared
    private var assertion: IOPMAssertionID = 0
    private var loop: Task<Void, Never>?
    private var lidSince: Date?
    private var lastActive: Date?
    /// After pmset fails, don't retry every tick; try again when the helper or the setting changes.
    private var lidFailedKey: String?

    static let sudoersPath = "/etc/sudoers.d/claude-usage-bar"
    static let pmset = "/usr/bin/pmset"
    private let flagKey = "lidModeWeDisabledSleep"

    private init() {
        helperInstalled = FileManager.default.fileExists(atPath: Self.sudoersPath)
        // If the app crashed or was killed while lid mode was on, undo it now.
        if UserDefaults.standard.bool(forKey: flagKey) {
            log.add("Lid mode was left on by a previous run; turning sleep back on")
            setDisableSleep(false)
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    // MARK: Detection

    /// Any session log under ~/.claude/projects written within `window` seconds.
    nonisolated static func recentClaudeActivity(window: TimeInterval = 120) -> Bool {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-window)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return false }
        for dir in dirs {
            // A directory's mtime changes when files are added, not when they're appended to, so check the files.
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > cutoff { return true }
            }
        }
        return false
    }

    struct Battery { var onAC: Bool; var percent: Int? }

    nonisolated static func battery() -> Battery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return Battery(onAC: true, percent: nil) }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var pct: Int?
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                pct = cur * 100 / max
            }
        }
        return Battery(onAC: type == kIOPMACPowerKey, percent: pct)
    }

    // MARK: Loop

    func tick() async {
        guard let model else { return }
        let s = model.settings
        let scheduledCodeRunning = model.scheduler.jobs.contains { $0.isClaudeCode && ($0.state == .sending || $0.state == .waitingForReply) }
        let logsActive = (s.awakeWhileClaudeWorks || s.lidClosedWhileClaudeWorks)
            ? await Task.detached(priority: .utility) { PowerManager.recentClaudeActivity() }.value : false
        let working = scheduledCodeRunning || logsActive
        if working { lastActive = Date() }
        // Grace period so a pause between tool calls doesn't flip things off and on.
        let effective = working || (lastActive.map { Date().timeIntervalSince($0) < 3 * 60 } ?? false)
        if effective != claudeWorking { log.add(effective ? "Claude Code is working" : "Claude Code went idle") }
        claudeWorking = effective

        // Awake (idle sleep only).
        setAssertion(effective && (s.awakeWhileClaudeWorks || s.lidClosedWhileClaudeWorks))

        // Lid closed.
        var wantLid = effective && s.lidClosedWhileClaudeWorks && helperInstalled
        let bat = Self.battery()
        if wantLid, s.lidOnlyOnPower, !bat.onAC { wantLid = false; note("Lid mode paused: on battery (Settings allows it only on the power adapter).") }
        if wantLid, !bat.onAC, let p = bat.percent, p < s.lidBatteryFloor { wantLid = false; note("Lid mode off: battery at \(p)%.") }
        if wantLid, let since = lidSince, Date().timeIntervalSince(since) > Double(s.lidMaxHours) * 3600 {
            wantLid = false; note("Lid mode off: reached the \(s.lidMaxHours)-hour maximum.")
        }
        let attemptKey = "\(wantLid)-\(helperInstalled)-\(s.lidClosedWhileClaudeWorks)"
        if wantLid != lidModeActive, lidFailedKey != attemptKey {
            if setDisableSleep(wantLid) {
                lidModeActive = wantLid
                lidFailedKey = nil
                // Keep the start time when turning off for battery/time limits, so the time limit
                // can't switch it straight back on. It resets only once Claude Code goes idle.
                if wantLid, lidSince == nil { lidSince = Date() }
            } else {
                lidFailedKey = attemptKey
                if !wantLid { note("Couldn't turn sleep back on automatically. Run: sudo pmset -a disablesleep 0") }
            }
        }
        if !effective { lidSince = nil }
    }

    private func note(_ s: String) {
        if lastNote != s { log.add(s) }
        lastNote = s
    }

    private func setAssertion(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Claude Code is working" as CFString, &assertion)
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion); assertion = 0
        }
    }

    // MARK: pmset via the sudoers rule

    /// Runs `sudo -n pmset -a disablesleep 0|1`. `-n` = never prompt: without the rule it just fails.
    @discardableResult
    func setDisableSleep(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", Self.pmset, "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let ok = p.terminationStatus == 0
        if ok {
            UserDefaults.standard.set(on, forKey: flagKey)
            log.add(on ? "Lid mode on: the Mac keeps running with the lid closed while Claude Code works" : "Lid mode off: closing the lid sleeps the Mac again")
        } else {
            log.add("Couldn't run pmset (is the lid-mode helper installed?)")
        }
        return ok
    }

    /// Called from applicationWillTerminate: never leave sleep disabled behind.
    func shutdown() {
        if UserDefaults.standard.bool(forKey: flagKey) { setDisableSleep(false) }
        setAssertion(false)
    }

    // MARK: Install / remove the rule (asks for the admin password via macOS)

    func installHelper() -> String {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return "Unusual user name; install it by hand (see README)." }
        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmset) -a disablesleep 0, \(Self.pmset) -a disablesleep 1"
        // Everything happens as root inside /etc/sudoers.d, so no user-writable file is ever installed
        // (a user-owned temp file could be swapped between the check and the install). sudo ignores
        // file names containing a dot, so the staging file is inert until the final rename.
        let staging = "/etc/sudoers.d/.claude-usage-bar.tmp"
        let script = "umask 0337 && /bin/rm -f '\(staging)' && /usr/bin/printf '%s\\n' '\(rule)' > '\(staging)' && " +
            "/usr/sbin/chown root:wheel '\(staging)' && /bin/chmod 0440 '\(staging)' && /usr/sbin/visudo -cf '\(staging)' && " +
            "/bin/mv -f '\(staging)' '\(Self.sudoersPath)' || { /bin/rm -f '\(staging)'; exit 1; }"
        let result = runAdmin(script)
        helperInstalled = FileManager.default.fileExists(atPath: Self.sudoersPath)
        lidFailedKey = nil
        if helperInstalled { log.add("Lid-mode helper installed (\(Self.sudoersPath))") }
        return helperInstalled ? "Installed. The app can now turn lid mode on and off by itself." : (result ?? "Not installed.")
    }

    func removeHelper() -> String {
        setDisableSleep(false)
        let result = runAdmin("/bin/rm -f '\(Self.sudoersPath)' && \(Self.pmset) -a disablesleep 0")
        lidFailedKey = nil
        helperInstalled = FileManager.default.fileExists(atPath: Self.sudoersPath)
        lidModeActive = false
        if !helperInstalled { log.add("Lid-mode helper removed") }
        return helperInstalled ? (result ?? "Not removed.") : "Removed. Closing the lid always sleeps the Mac again."
    }

    /// macOS's own admin password dialog; returns an error message, or nil on success.
    private func runAdmin(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        if let err { return (err[NSAppleScript.errorMessage] as? String) ?? "Cancelled." }
        return nil
    }
}
