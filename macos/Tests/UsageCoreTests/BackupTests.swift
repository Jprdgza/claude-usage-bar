import XCTest
@testable import UsageCore

final class BackupTests: XCTestCase {
    func testDestinationsFromCloudStorage() {
        let home = "/Users/x"
        let d = Backup.destinations(home: home,
                                    cloudStorageEntries: ["GoogleDrive-me@example.com", "Dropbox", "OneDrive-Personal", "Box-Box"],
                                    iCloudDriveExists: true,
                                    exists: { $0.hasSuffix("/My Drive") })
        XCTAssertEqual(d.map(\.name), ["Box", "Dropbox", "Google Drive (me@example.com)", "OneDrive (Personal)", "iCloud Drive"])
        XCTAssertEqual(d[2].path, "/Users/x/Library/CloudStorage/GoogleDrive-me@example.com/My Drive")
        XCTAssertEqual(d[4].path, "/Users/x/Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertTrue(Backup.destinations(home: home, cloudStorageEntries: [], iCloudDriveExists: false).isEmpty)
    }

    func testPruneKeepsNewestAndIgnoresOtherFiles() {
        let names = (1...16).map { String(format: "2026-11-%02d", $0) } + ["notes.txt", ".DS_Store"]
        let del = Backup.snapshotsToDelete(names, keep: 14)
        XCTAssertEqual(del, ["2026-11-01", "2026-11-02"])
        XCTAssertTrue(Backup.snapshotsToDelete(["2026-11-01"], keep: 14).isEmpty)
        XCTAssertEqual(Backup.snapshotName(for: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!), "2027-01-15")
    }

    func testMergeHistoryAndQueue() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let local = [HistoryPoint(t: t0, v: ["session": 10]), HistoryPoint(t: t0.addingTimeInterval(60), v: ["session": 20])]
        let backup = [HistoryPoint(t: t0.addingTimeInterval(-60), v: ["session": 5]), HistoryPoint(t: t0, v: ["session": 99])]
        let merged = Backup.mergeHistory(local: local, backup: backup)
        XCTAssertEqual(merged.map { $0.v["session"]! }, [5, 10, 20], "union by time; local wins on ties")

        let keep = ScheduledMessage(conversationId: nil, conversationName: "A", text: "a", trigger: .at(t0))
        var waiting = ScheduledMessage(conversationId: nil, conversationName: "B", text: "b", trigger: .at(t0))
        waiting.fireAt = t0
        let q = Backup.mergeQueue(local: [keep], backup: [keep, waiting])
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q[1].state, .cancelled, "restored jobs are never re-sent automatically")
        XCTAssertFalse(q[1].isDue(now: t0.addingTimeInterval(10)))
    }

    func testWriteSnapshotRoundTrip() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("backup-test-\(UUID())")
        let support = base.appendingPathComponent("support"), dest = base.appendingPathComponent("Drive")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "{\"t\":\"2026-11-11T00:00:00Z\",\"v\":{\"session\":5}}\n".write(to: support.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
        try "[]".write(to: support.appendingPathComponent("scheduled.json"), atomically: true, encoding: .utf8)
        // Old snapshots beyond the limit get pruned; unrelated files are left alone.
        let root = dest.appendingPathComponent(Backup.folderName)
        for d in (1...14).map({ String(format: "2026-10-%02d", $0) }) { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        try "keep me".write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let now = JSON.parseISODate("2026-11-11T12:00:00Z")!
        let name = try Backup.writeSnapshot(to: dest.path, support: support, settings: ["refreshSeconds": 120], includeQueue: false, now: now)
        let snap = root.appendingPathComponent(name)
        XCTAssertTrue(fm.fileExists(atPath: snap.appendingPathComponent("history.jsonl").path))
        XCTAssertFalse(fm.fileExists(atPath: snap.appendingPathComponent("scheduled.json").path), "queue left out when asked")
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: snap.appendingPathComponent("settings.json"))) as? [String: Any]
        XCTAssertEqual(settings?["refreshSeconds"] as? Int, 120)
        let manifest = try String(contentsOf: snap.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("history.jsonl"))
        let left = try fm.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(left.filter { $0.hasPrefix("2026-") }.count, 14)
        XCTAssertFalse(left.contains("2026-10-01"))
        XCTAssertTrue(left.contains("README.txt"))
    }
}

final class BackupSyncAppTests: XCTestCase {
    func testSyncAppForPath() {
        XCTAssertEqual(Backup.syncApp(forPath: "/Users/x/Library/CloudStorage/GoogleDrive-me@example.com/My Drive")?.bundleIds, ["com.google.drivefs"])
        XCTAssertEqual(Backup.syncApp(forPath: "/Users/x/Library/CloudStorage/Dropbox")?.name, "Dropbox")
        XCTAssertEqual(Backup.syncApp(forPath: "/Users/x/Library/CloudStorage/OneDrive-Personal")?.name, "OneDrive")
        XCTAssertNil(Backup.syncApp(forPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs"), "iCloud Drive syncs by itself")
        XCTAssertNil(Backup.syncApp(forPath: "/Users/x/Documents/Backups"))
    }
}
