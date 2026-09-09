import AppKit
import XCTest
@testable import ClaudeMonitor

/// The unit-test bundle is hosted inside the real app binary. These tests
/// pin down that the hosted copy does not behave like the product — running
/// `make test` must never disturb a production ClaudeMonitor instance.
final class AppDelegateTestHostTests: XCTestCase {
    func test_processIsRecognizedAsUnitTestHost() {
        XCTAssertTrue(AppDelegate.isUnitTestHost)
    }

    func test_hostedAppSkippedItsLaunchSequence() {
        XCTAssertFalse(AppDelegate.didLaunch, "the launch sequence must not run inside the test host")
    }

    func test_hostedAppDidNotRewriteTheProductionPortFile() throws {
        // If the port file exists it belongs to a production instance; it must
        // not have been written by this process.
        let portFile = PortFileWriter.defaultLocation
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: portFile.path),
              let modified = attrs[.modificationDate] as? Date else { return }
        XCTAssertLessThan(modified, Self.processStart,
                          "~/.claude-monitor/port was rewritten while the test host was running")
    }

    /// Process start time from the kernel's process table (`kinfo_proc`).
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return .distantFuture }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }()
}
