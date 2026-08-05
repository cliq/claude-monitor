import XCTest
@testable import ClaudeMonitor

final class UsageSnapshotStoreTests: XCTestCase {
    // Fresh temp dir per test, not created ahead of time — `write` must
    // create it.
    private func freshDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func sampleSnapshot() -> UsageSnapshot {
        var a = AccountUsage(name: "personal", status: "ok")
        a.plan = "MAX"
        a.sessionPct = 43
        a.sessionResets = "23:50"
        a.sessionResetsAt = "2026-07-19T23:50:00Z"
        var b = AccountUsage(name: "work", status: "ok")
        b.plan = "PRO"
        b.weeklyPct = 12
        b.weeklyResets = "Fri 12:00"
        b.weeklyResetsAt = "2026-07-24T12:00:00Z"
        return UsageSnapshot(updatedAt: "2026-07-19T12:00:00Z", accounts: [a, b])
    }

    func test_write_thenRead_roundTrips() {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = sampleSnapshot()

        UsageSnapshotStore.write(snapshot, to: dir)
        let read = UsageSnapshotStore.read(from: dir)

        XCTAssertEqual(read?.accounts, snapshot.accounts)
        XCTAssertEqual(read?.updatedAt, snapshot.updatedAt)
        XCTAssertEqual(read?.schemaVersion, snapshot.schemaVersion)
    }

    func test_read_corruptFile_returnsNil() throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(UsageSnapshotStore.fileName))

        XCTAssertNil(UsageSnapshotStore.read(from: dir))
    }

    func test_read_missingFile_returnsNil() throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertNil(UsageSnapshotStore.read(from: dir))
    }

    func test_read_missingDir_returnsNil() {
        let dir = freshDir()
        XCTAssertNil(UsageSnapshotStore.read(from: dir))
    }

    func test_clear_removesFile() {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        UsageSnapshotStore.write(sampleSnapshot(), to: dir)
        XCTAssertNotNil(UsageSnapshotStore.read(from: dir))

        UsageSnapshotStore.clear(in: dir)

        XCTAssertNil(UsageSnapshotStore.read(from: dir))
    }

    func test_clear_missingFile_doesNotCrash() {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        UsageSnapshotStore.clear(in: dir)
    }

    func test_write_leavesNoTmpArtifact() throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        UsageSnapshotStore.write(sampleSnapshot(), to: dir)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".tmp") },
                       "expected no .tmp file, found \(contents)")
    }

    // MARK: - containerURL nil-safety

    func test_containerURL_emptyGroupID_returnsNil() {
        XCTAssertNil(UsageSnapshotStore.containerURL(groupID: ""))
    }

    func test_containerURL_leadingDotGroupID_returnsNil() {
        XCTAssertNil(UsageSnapshotStore.containerURL(groupID: ".com.foo"))
    }
}
