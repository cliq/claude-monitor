import XCTest
@testable import ClaudeMonitor

final class PiExtensionInstallerTests: XCTestCase {
    private var agentDir: URL!
    private var bundle: Bundle { Bundle(for: Self.self) }
    private var file: URL { PiExtensionInstaller.extensionFile(in: agentDir) }

    override func setUpWithError() throws {
        agentDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: agentDir)
    }

    private func write(_ body: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: file, atomically: true, encoding: .utf8)
    }

    func test_inspectWithoutFileIsNotInstalled() {
        XCTAssertEqual(PiExtensionInstaller.inspect(agentDir: agentDir).status, .notInstalled)
    }

    func test_installWritesBundledExtensionIntoExtensionsFolder() throws {
        try PiExtensionInstaller.install(agentDir: agentDir, bundle: bundle)

        XCTAssertEqual(file.path, agentDir.appendingPathComponent("extensions/claude-monitor.ts").path)
        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(PiExtensionInstaller.version(in: body), PiExtensionInstaller.currentVersion,
                       "the bundled header must match currentVersion")
        let status = PiExtensionInstaller.inspect(agentDir: agentDir)
        XCTAssertEqual(status.status, .installed)
        XCTAssertEqual(status.installedVersion, PiExtensionInstaller.currentVersion)
    }

    func test_olderHeaderIsOutdated() throws {
        try write("// claude-monitor pi-extension v0\nexport default () => {}\n")
        XCTAssertEqual(PiExtensionInstaller.inspect(agentDir: agentDir).status, .outdated)
    }

    func test_fileWithoutHeaderIsModifiedExternallyAndSurvivesUninstall() throws {
        try write("export default () => {}\n")
        XCTAssertEqual(PiExtensionInstaller.inspect(agentDir: agentDir).status, .modifiedExternally)

        XCTAssertThrowsError(try PiExtensionInstaller.uninstall(agentDir: agentDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_uninstallRemovesOurFileAndLeavesOtherExtensions() throws {
        try PiExtensionInstaller.install(agentDir: agentDir, bundle: bundle)
        let other = file.deletingLastPathComponent().appendingPathComponent("other.ts")
        try "export default () => {}\n".write(to: other, atomically: true, encoding: .utf8)

        try PiExtensionInstaller.uninstall(agentDir: agentDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(PiExtensionInstaller.inspect(agentDir: agentDir).status, .notInstalled)
    }

    func test_uninstallWithoutFileIsANoOp() throws {
        XCTAssertNoThrow(try PiExtensionInstaller.uninstall(agentDir: agentDir))
    }

    func test_refreshInstalledRewritesOnlyOurCopies() throws {
        let stale = agentDir.appendingPathComponent("stale")
        let foreign = agentDir.appendingPathComponent("foreign")
        let missing = agentDir.appendingPathComponent("missing")
        for (dir, body) in [(stale, "// claude-monitor pi-extension v1\nstale\n"),
                            (foreign, "mine\n")] {
            let f = PiExtensionInstaller.extensionFile(in: dir)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: f, atomically: true, encoding: .utf8)
        }

        let refreshed = PiExtensionInstaller.refreshInstalled(agentDirs: [stale, foreign, missing],
                                                              bundle: bundle)

        XCTAssertEqual(refreshed, [stale])
        let staleBody = try String(contentsOf: PiExtensionInstaller.extensionFile(in: stale), encoding: .utf8)
        XCTAssertTrue(staleBody.contains("pi.on("), "same-version copies are refreshed with the bundled body")
        XCTAssertEqual(try String(contentsOf: PiExtensionInstaller.extensionFile(in: foreign), encoding: .utf8),
                       "mine\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PiExtensionInstaller.extensionFile(in: missing).path))
    }
}
