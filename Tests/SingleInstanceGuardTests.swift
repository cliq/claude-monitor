import XCTest
@testable import ClaudeMonitor

final class SingleInstanceGuardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_acquireWritesCurrentPid() throws {
        let guardPath = dir.appendingPathComponent("pid")
        let result = SingleInstanceGuard.acquire(at: guardPath)
        XCTAssertEqual(result, .acquired)
        let body = try String(contentsOf: guardPath, encoding: .utf8)
        XCTAssertEqual(Int32(body.trimmingCharacters(in: .whitespacesAndNewlines)),
                       ProcessInfo.processInfo.processIdentifier)
    }

    func test_acquireOverwritesStalePid() throws {
        let guardPath = dir.appendingPathComponent("pid")
        try "999999\n".write(to: guardPath, atomically: true, encoding: .utf8)  // non-existent pid
        let result = SingleInstanceGuard.acquire(at: guardPath)
        XCTAssertEqual(result, .acquired)
    }

    func test_acquireReportsLivePid() throws {
        // Write *our own* pid. It's live. We should see .alreadyRunning.
        let guardPath = dir.appendingPathComponent("pid")
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: guardPath, atomically: true, encoding: .utf8)
        let result = SingleInstanceGuard.acquire(at: guardPath)
        if case .alreadyRunning(let pid) = result {
            XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
        } else {
            XCTFail("expected alreadyRunning, got \(result)")
        }
    }
}
