import XCTest
@testable import ClaudeMonitor

final class PortFileWriterTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-portwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_writesPortAtomicallyToGivenPath() throws {
        let portFile = tmpDir.appendingPathComponent("port")
        let writer = PortFileWriter(destination: portFile)
        try writer.write(port: 52341)

        let contents = try String(contentsOf: portFile, encoding: .utf8)
        XCTAssertEqual(contents, "52341\n")
    }

    func test_writesOverwriteExistingFile() throws {
        let portFile = tmpDir.appendingPathComponent("port")
        try "99999\n".write(to: portFile, atomically: true, encoding: .utf8)

        let writer = PortFileWriter(destination: portFile)
        try writer.write(port: 42)

        let contents = try String(contentsOf: portFile, encoding: .utf8)
        XCTAssertEqual(contents, "42\n")
    }

    func test_createsParentDirectoryIfMissing() throws {
        let portFile = tmpDir.appendingPathComponent("nested/dir/port")
        let writer = PortFileWriter(destination: portFile)
        try writer.write(port: 1)
        let contents = try String(contentsOf: portFile, encoding: .utf8)
        XCTAssertEqual(contents, "1\n")
    }
}
