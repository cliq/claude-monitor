import XCTest
@testable import ClaudeMonitor

final class HookScriptDeployerTests: XCTestCase {
    private var tmpHome: URL!

    override func setUpWithError() throws {
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-deployer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpHome)
    }

    func test_deployCopiesBundledScriptAndMakesItExecutable() throws {
        try HookScriptDeployer.deploy(home: tmpHome, bundle: Bundle(for: Self.self))
        let dest = tmpHome.appendingPathComponent(".claude-monitor/hook.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))

        let body = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("#!/bin/bash"))
    }

    func test_deployOverwritesOlderScript() throws {
        let dest = tmpHome.appendingPathComponent(".claude-monitor/hook.sh")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "stale".write(to: dest, atomically: true, encoding: .utf8)

        try HookScriptDeployer.deploy(home: tmpHome, bundle: Bundle(for: Self.self))
        let body = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("#!/bin/bash"))
    }
}
