import Foundation

/// Backups go into a folder that a cloud provider's own Mac app already syncs (Google Drive, Dropbox,
/// OneDrive, Box, iCloud Drive) or any folder you pick. The provider's app does the uploading, so this
/// app needs no cloud accounts or tokens and still talks only to claude.ai and api.anthropic.com.
/// Secrets (the claude.ai session and the API key) live in the Keychain and are never backed up.
public enum Backup {
    public struct Destination: Identifiable, Equatable, Sendable {
        public var id: String { path }
        public var name: String     // "Google Drive", "Dropbox", …
        public var path: String     // the folder backups go into (a "Claude Usage Backup" folder is made inside)
        public init(name: String, path: String) { self.name = name; self.path = path }
    }

    public static let folderName = "Claude Usage Backup"
    public static let keepSnapshots = 14

    /// Files copied from the app's data folder (each optional).
    public static let dataFiles = ["history.jsonl", "efficiency.jsonl", "endpoints.json"]
    public static let queueFile = "scheduled.json"
    public static let settingsFile = "settings.json"
    public static let manifestFile = "manifest.json"

    /// Synced folders found on this Mac. `cloudStorageEntries` are the names inside
    /// ~/Library/CloudStorage (e.g. "GoogleDrive-me@example.com", "Dropbox", "OneDrive-Personal").
    public static func destinations(home: String, cloudStorageEntries: [String], iCloudDriveExists: Bool,
                                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Destination] {
        var out: [Destination] = []
        let cs = home + "/Library/CloudStorage/"
        for entry in cloudStorageEntries.sorted() {
            let (provider, account) = splitEntry(entry)
            var path = cs + entry
            if provider == "Google Drive" {
                // Google Drive puts your files under "My Drive" (Shared drives sit next to it).
                if exists(path + "/My Drive") { path += "/My Drive" }
            }
            out.append(Destination(name: account.map { "\(provider) (\($0))" } ?? provider, path: path))
        }
        if iCloudDriveExists {
            out.append(Destination(name: "iCloud Drive", path: home + "/Library/Mobile Documents/com~apple~CloudDocs"))
        }
        return out
    }

    static func splitEntry(_ entry: String) -> (String, String?) {
        let known: [(String, String)] = [("GoogleDrive", "Google Drive"), ("Dropbox", "Dropbox"), ("OneDrive", "OneDrive"),
                                         ("Box", "Box"), ("pCloud", "pCloud"), ("ProtonDrive", "Proton Drive")]
        for (prefix, name) in known where entry.hasPrefix(prefix) {
            let rest = entry.dropFirst(prefix.count)
            let account = rest.hasPrefix("-") ? String(rest.dropFirst()) : nil
            // "Box-Box" and "Dropbox" carry no useful account; "OneDrive-Personal" does.
            return (name, (account?.isEmpty ?? true) || account == name ? nil : account)
        }
        return (entry, nil)
    }

    /// Snapshot folders are named by day, so one backup a day is kept per day: "2026-11-11".
    public static func snapshotName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Which snapshot folders to delete so only the newest `keep` remain. Ignores anything that
    /// isn't a snapshot name, so nothing else in the folder is ever touched.
    public static func snapshotsToDelete(_ names: [String], keep: Int = keepSnapshots) -> [String] {
        let snaps = names.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }.sorted()
        return snaps.count > keep ? Array(snaps.prefix(snaps.count - keep)) : []
    }

    /// Writes today's snapshot folder and prunes old ones. Returns the snapshot name.
    public static func writeSnapshot(to path: String, support: URL, settings: [String: Any], includeQueue: Bool, now: Date,
                                     appVersion: String = "dev") throws -> String {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path).appendingPathComponent(Backup.folderName, isDirectory: true)
        let name = Backup.snapshotName(for: now)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String] = []
        for f in Backup.dataFiles + (includeQueue ? [Backup.queueFile] : []) {
            let src = support.appendingPathComponent(f)
            guard let data = try? Data(contentsOf: src) else { continue }
            try data.write(to: dir.appendingPathComponent(f), options: .atomic)
            files.append(f)
        }
        if !includeQueue { try? fm.removeItem(at: dir.appendingPathComponent(Backup.queueFile)) }
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try settingsData.write(to: dir.appendingPathComponent(Backup.settingsFile), options: .atomic)
        files.append(Backup.settingsFile)
        let manifest: [String: Any] = ["app": "Claude Usage", "version": appVersion, "created": ISO8601DateFormatter().string(from: now),
                                       "files": files, "note": "No passwords, session cookies or API keys are included."]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent(Backup.manifestFile), options: .atomic)
        let existing = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for old in Backup.snapshotsToDelete(existing) { try? fm.removeItem(at: root.appendingPathComponent(old)) }
        return name
    }

    // MARK: Restore (merge, never just overwrite)

    /// Union of both histories by time; on the same timestamp the local reading wins.
    public static func mergeHistory(local: [HistoryPoint], backup: [HistoryPoint]) -> [HistoryPoint] {
        var byTime: [Date: HistoryPoint] = [:]
        for p in backup { byTime[p.t] = p }
        for p in local { byTime[p.t] = p }
        return byTime.values.sorted { $0.t < $1.t }
    }

    /// Restored queue entries are added as cancelled (never re-sent automatically on a new Mac or
    /// after time has passed); existing entries are kept as they are.
    public static func mergeQueue(local: [ScheduledMessage], backup: [ScheduledMessage]) -> [ScheduledMessage] {
        let have = Set(local.map(\.id))
        let restored = backup.filter { !have.contains($0.id) }.map { j -> ScheduledMessage in
            var j = j
            if j.state.isActive {
                j.state = .cancelled
                j.detail = "Restored from a backup and not sent. Re-queue it if you still need it."
            }
            return j
        }
        return local + restored
    }
}
