// IntegrationTests/ChauffeurProviderIntegrationTests.swift
import XCTest
import AppKit
@testable import ClaudeMonitor

/// Drives the real `ChauffeurProvider` (real `ps eww`, real Launch Services)
/// against a live Chauffeur-hosted agent process. Chauffeur must be installed
/// and hosting at least one Claude/Codex session started after it began
/// exporting `CHAUFFEUR_SESSION_URL`. Set `CHAUFFEUR_TEST_PID` to target a
/// specific process; otherwise the first matching process is used.
final class ChauffeurProviderIntegrationTests: XCTestCase {
    private let provider = ChauffeurProvider()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["RUN_TERMINAL_INTEGRATION"] != "1" {
            throw XCTSkip("Set RUN_TERMINAL_INTEGRATION=1 to enable.")
        }
        guard provider.isInstalled else {
            throw XCTSkip("Chauffeur is not installed on this machine.")
        }
    }

    func test_focusOpensLiveSessionAndActivatesChauffeur() throws {
        let pid = try XCTUnwrap(targetPid(), "No live process exports CHAUFFEUR_SESSION_URL; start a session inside Chauffeur.")

        // Put another app in front so activation is observable.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        Thread.sleep(forTimeInterval: 1.0)

        let result = provider.focus(tty: "", expectedPid: pid)
        XCTAssertEqual(result, .focused)

        // A cold launch (app closed, runtime handshake, window restore) can take
        // well over ten seconds; a warm switch is near-instant.
        let deadline = Date().addingTimeInterval(30)
        var frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        while Date() < deadline, frontmost?.hasPrefix(provider.bundleID) != true {
            Thread.sleep(forTimeInterval: 0.25)
            frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        XCTAssertTrue(frontmost?.hasPrefix(provider.bundleID) == true,
                      "Chauffeur did not come to the front (frontmost: \(frontmost ?? "nil"))")
    }

    /// The same path a tile click takes: the real registry, in probe order, behind
    /// the composite. Chauffeur must claim the session even though its tty also
    /// exists inside tmux and Chauffeur may not be running.
    func test_compositeBridgeWithRealRegistryFocusesChauffeurSession() throws {
        let pid = try XCTUnwrap(targetPid(), "No live process exports CHAUFFEUR_SESSION_URL; start a session inside Chauffeur.")
        let tty = OrcaProvider.runProcess("/bin/ps", ["-o", "tty=", "-p", String(pid)])?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bridge = CompositeTerminalBridge(providers: TerminalRegistry.installed(), isDisabled: { _ in false })

        XCTAssertEqual(bridge.focus(tty: "/dev/" + tty, expectedPid: pid), .focused)
    }

    private func targetPid() -> Int32? {
        if let raw = ProcessInfo.processInfo.environment["CHAUFFEUR_TEST_PID"], let pid = Int32(raw) {
            return pid
        }
        guard let dump = OrcaProvider.runProcess("/bin/ps", ["eww", "-A", "-o", "pid=,command="]),
              dump.status == 0 else { return nil }
        for line in dump.stdout.split(separator: "\n") {
            guard line.contains(ChauffeurProvider.environmentKey + "=chauffeur"),
                  !line.contains("/bin/ps ") else { continue }
            let pidField = line.drop { $0 == " " }.prefix { $0.isNumber }
            if let pid = Int32(pidField) { return pid }
        }
        return nil
    }
}
