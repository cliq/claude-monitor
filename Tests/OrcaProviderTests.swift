import XCTest
@testable import ClaudeMonitor

final class OrcaProviderTests: XCTestCase {

    // MARK: - terminalHandle(fromEnvironmentDump:)

    func testExtractsHandleFromOrcaEnvironment() {
        let dump = "claude TERM=xterm-256color TERM_PROGRAM=Orca TERM_PROGRAM_VERSION=1.4.184 "
            + "ORCA_TERMINAL_HANDLE=term_2f4b6763-c11e-4abe-9c42-a0a6d3138863 ORCA_TAB_ID=d839fa89"
        XCTAssertEqual(OrcaProvider.terminalHandle(fromEnvironmentDump: dump),
                       "term_2f4b6763-c11e-4abe-9c42-a0a6d3138863")
    }

    func testExtractsHandleWhenLastTokenInDump() {
        let dump = "claude TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_abc"
        XCTAssertEqual(OrcaProvider.terminalHandle(fromEnvironmentDump: dump), "term_abc")
    }

    func testReturnsNilWithoutOrcaTermProgram() {
        // A session with a leaked ORCA_ var but hosted elsewhere must not match.
        let dump = "claude TERM_PROGRAM=iTerm.app ORCA_TERMINAL_HANDLE=term_abc"
        XCTAssertNil(OrcaProvider.terminalHandle(fromEnvironmentDump: dump))
    }

    func testReturnsNilWithoutHandle() {
        let dump = "claude TERM_PROGRAM=Orca TERM_PROGRAM_VERSION=1.4.184"
        XCTAssertNil(OrcaProvider.terminalHandle(fromEnvironmentDump: dump))
    }

    func testReturnsNilForEmptyHandleValue() {
        let dump = "claude TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE= ORCA_TAB_ID=x"
        XCTAssertNil(OrcaProvider.terminalHandle(fromEnvironmentDump: dump))
    }

    // MARK: - focus(tty:expectedPid:)

    private let orcaPsDump = "claude TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=term_abc"

    private func makeProvider(
        runCommand: @escaping OrcaProvider.CommandRunner,
        cliPath: String? = "/fake/bin/orca",
        onActivate: @escaping () -> Void = {}
    ) -> OrcaProvider {
        OrcaProvider(runCommand: runCommand,
                     cliPathResolver: { cliPath },
                     activateApp: onActivate)
    }

    func testFocusSwitchesTerminalAndActivates() {
        var invocations: [[String]] = []
        var activated = false
        let provider = makeProvider(
            runCommand: { executable, arguments in
                invocations.append([executable] + arguments)
                if executable == "/bin/ps" { return (0, self.orcaPsDump) }
                return (0, "{\"ok\":true}")
            },
            onActivate: { activated = true }
        )

        let result = provider.focus(tty: "/dev/ttys004", expectedPid: 4242)

        XCTAssertEqual(result, .focused)
        XCTAssertTrue(activated)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0], ["/bin/ps", "eww", "-o", "command=", "-p", "4242"])
        XCTAssertEqual(invocations[1], ["/fake/bin/orca", "terminal", "switch",
                                        "--terminal", "term_abc", "--json"])
    }

    func testFocusReturnsNoSuchTabForNonOrcaSession() {
        var activated = false
        let provider = makeProvider(
            runCommand: { _, _ in (0, "claude TERM_PROGRAM=Apple_Terminal") },
            onActivate: { activated = true }
        )
        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1), .noSuchTab)
        XCTAssertFalse(activated)
    }

    func testFocusReturnsNoSuchTabWhenPsFails() {
        let provider = makeProvider(runCommand: { _, _ in (1, "") })
        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1), .noSuchTab)
    }

    func testFocusReturnsNoSuchTabWhenRunnerCannotLaunch() {
        let provider = makeProvider(runCommand: { _, _ in nil })
        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1), .noSuchTab)
    }

    func testFocusReportsMissingCLI() {
        let provider = makeProvider(
            runCommand: { _, _ in (0, self.orcaPsDump) },
            cliPath: nil
        )
        XCTAssertEqual(provider.focus(tty: "/dev/ttys004", expectedPid: 1),
                       .scriptError("Orca CLI not found"))
    }

    func testFocusStillActivatesWhenSwitchFailsOnStaleHandle() {
        // Env proved the session lives in Orca; no other provider can match,
        // so best effort is: raise the app anyway and stop the probe chain.
        var activated = false
        let provider = makeProvider(
            runCommand: { executable, _ in
                executable == "/bin/ps" ? (0, self.orcaPsDump) : (1, "terminal_handle_stale")
            },
            onActivate: { activated = true }
        )
        XCTAssertEqual(provider.focus(tty: "/dev/ttys004", expectedPid: 1), .focused)
        XCTAssertTrue(activated)
    }
}
