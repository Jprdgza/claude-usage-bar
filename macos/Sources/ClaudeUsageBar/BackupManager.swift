import AppKit
import Foundation
import UsageCore

/// Daily backups of the app's own data (history, efficiency, settings, optionally the message queue)
/// into a synced cloud folder or any folder. Never includes the claude.ai session or API key.
@MainActor final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    @Published private(set) var destinations: [Backup.Destination] = []
    @Published private(set) var lastBackup: Date? = UserDefaults.standard.object(forKey: "backupLast") as? Date
    @Published private(set) var status: String?
    @Published private(set) var working = false

    @Published var path: String? = UserDefaults.standard.string(forKey: "backupPath") {
        didSet { UserDefaults.standard.set(path, forKey: "backupPath") }
    }
    @Published var automatic: Bool = UserDefaults.standard.object(forKey: "backupAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "backupAuto") }
    }
    @Published var includeQueue: Bool = UserDefaults.standard.object(forKey: "backupQueue") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeQueue, forKey: "backupQueue") }
    }

    weak var model: AppModel?
    private let log = DebugLog.shared

    /// The cloud app that should upload the chosen folder, if it isn't running right now.
    var syncAppNotRunning: Backup.SyncApp? {
        guard let path, let app = Backup.syncApp(forPath: path) else { return nil }
        let running = app.bundleIds.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        return running ? nil : app
    }

    func openSyncApp() {
        guard let app = Backup.syncApp(forPath: path ?? ""),
              let url = app.bundleIds.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); objectWillChange.send() }
    }

    func refreshDestinations() {
        let home = NSHomeDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/CloudStorage"))?.filter { !$0.hasPrefix(".") } ?? []
        let icloud = FileManager.default.fileExists(atPath: home + "/Library/Mobile Documents/com~apple~CloudDocs")
        destinations = Backup.destinations(home: home, cloudStorageEntries: entries, iCloudDriveExists: icloud)
    }

    var destinationName: String? {
        guard let path else { return nil }
        return destinations.first { $0.path == path }?.name ?? (path as NSString).abbreviatingWithTildeInPath
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Back up here"
        panel.message = "Choose where backups go. A \"\(Backup.folderName)\" folder is created inside it."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    /// Called after each refresh: one backup a day when automatic backups are on.
    func backupIfDue() {
        guard automatic, path != nil, !working else { return }
        if let last = lastBackup, Date().timeIntervalSince(last) < 23 * 3600 { return }
        Task { await backupNow() }
    }

    func backupNow() async {
        guard let path, let model else { status = "Choose where to back up first."; return }
        working = true; defer { working = false }
        let support = AppPaths.support
        let settings = model.settings.exported()
        let includeQueue = self.includeQueue
        let now = Date()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let result: Result<String, Error> = await Task.detached(priority: .utility) {
            do { return .success(try Backup.writeSnapshot(to: path, support: support, settings: settings, includeQueue: includeQueue, now: now, appVersion: version)) }
            catch { return .failure(error) }
        }.value
        switch result {
        case .success(let folder):
            lastBackup = now
            UserDefaults.standard.set(now, forKey: "backupLast")
            if let app = syncAppNotRunning {
                status = "Saved to your \(app.name) folder at \(Fmt.clock(now)), but \(app.name) isn't running, so it hasn't uploaded yet. Open \(app.name) and it will upload."
                log.add("Backup written to \(destinationName ?? "folder") (\(folder)), but \(app.name) isn't running: not uploaded yet")
            } else {
                status = "Backed up at \(Fmt.clock(now))\(Backup.syncApp(forPath: path) != nil ? "; \(Backup.syncApp(forPath: path)!.name) will upload it shortly" : "")."
                log.add("Backup written to \(destinationName ?? "folder") (\(folder))")
            }
        case .failure(let e):
            status = "Backup failed: \(e.localizedDescription)"
            log.add("Backup failed: \(e.localizedDescription)")
        }
    }

    // MARK: Restore

    func restore() {
        guard let model else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Restore"
        panel.message = "Choose a dated backup folder (inside \"\(Backup.folderName)\")."
        if let path { panel.directoryURL = URL(fileURLWithPath: path).appendingPathComponent(Backup.folderName) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(Backup.manifestFile).path) else {
            status = "That folder isn't a Claude Usage backup (no manifest.json). Pick a dated folder like 2026-11-11."
            return
        }
        let support = AppPaths.support
        var restored: [String] = []

        // History: union with what's here.
        if let text = try? String(contentsOf: dir.appendingPathComponent("history.jsonl"), encoding: .utf8) {
            let merged = Backup.mergeHistory(local: model.history.points, backup: UsageHistory.parse(text))
            try? UsageHistory(points: merged).serialized().write(to: support.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
            restored.append("history")
        }
        // Efficiency: keep local windows, add the backup's.
        if let text = try? String(contentsOf: dir.appendingPathComponent("efficiency.jsonl"), encoding: .utf8) {
            let merged = EfficiencyAnalyzer.merge(stored: model.efficiency, fresh: EfficiencyAnalyzer.parse(text))
            try? EfficiencyAnalyzer.serialize(merged).write(to: support.appendingPathComponent("efficiency.jsonl"), atomically: true, encoding: .utf8)
            restored.append("efficiency")
        }
        // Queue: added as cancelled, never re-sent automatically.
        if let data = try? Data(contentsOf: dir.appendingPathComponent(Backup.queueFile)) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            if let jobs = try? d.decode([ScheduledMessage].self, from: data) {
                model.scheduler.restore(jobs); restored.append("queue")
            }
        }
        // Settings.
        if let data = try? Data(contentsOf: dir.appendingPathComponent(Backup.settingsFile)),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            model.settings.apply(dict); restored.append("settings")
        }
        // Endpoint override: only if there isn't one here already (takes effect after a restart).
        let override = support.appendingPathComponent("endpoints.json")
        if !FileManager.default.fileExists(atPath: override.path),
           let data = try? Data(contentsOf: dir.appendingPathComponent("endpoints.json")) {
            try? data.write(to: override, options: .atomic); restored.append("endpoints.json (after restart)")
        }
        model.reloadFromDisk()
        status = restored.isEmpty ? "Nothing to restore in that folder." : "Restored: \(restored.joined(separator: ", "))."
        log.add("Restored from backup \(dir.lastPathComponent): \(restored.joined(separator: ", "))")
    }
}
