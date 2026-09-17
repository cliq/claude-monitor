import XCTest
@testable import ClaudeMonitor

final class ChauffeurProviderTests: XCTestCase {

    private let sessionURL = "chauffeur://session/1D0D1EE9-2C6D-4C1E-9D9C-2E0A0C1F1B11/9B8E7D6C-5B4A-4F3E-8D2C-1B0A9F8E7D6C"
    private let debugSessionURL = "chauffeur-debug://session/1D0D1EE9-2C6D-4C1E-9D9C-2E0A0C1F1B11/9B8E7D6C-5B4A-4F3E-8D2C-1B0A9F8E7D6C"

    private func psDump(url: String) -> String {
        "claude TERM=tmux-256color TERM_PROGRAM=tmux CHAUFFEUR_SESSION_ID=9B8E7D6C-5B4A-4F3E-8D2C-1B0A9F8E7D6C "
            + "CHAUFFEUR_SESSION_URL=\(url) TMUX=/tmp/tmux-501/chauffeur,123,0"
    }

    // MARK: - sessionURLString(fromEnvironmentDump:)

    func testExtractsURLFromEnvironment() {
        XCTAssertEqual(ChauffeurProvider.sessionURLString(fromEnvironmentDump: psDump(url: sessionURL)),
                       sessionURL)
    }

    func testExtractsURLWhenLastTokenInDump() {
        let dump = "claude TERM_PROGRAM=tmux CHAUFFEUR_SESSION_URL=\(sessionURL)"
        XCTAssertEqual(ChauffeurProvider.sessionURLString(fromEnvironmentDump: dump), sessionURL)
    }

    func testReturnsNilWithoutVariable() {
        // Sessions started before Chauffeur exported the URL only carry the id.
        let dump = "claude TERM_PROGRAM=tmux CHAUFFEUR_SESSION_ID=9B8E7D6C-5B4A-4F3E-8D2C-1B0A9F8E7D6C"
        XCTAssertNil(ChauffeurProvider.sessionURLString(fromEnvironmentDump: dump))
    }

    func testReturnsNilForEmptyValue() {
        let dump = "claude CHAUFFEUR_SESSION_URL= TERM_PROGRAM=tmux"
        XCTAssertNil(ChauffeurProvider.sessionURLString(fromEnvironmentDump: dump))
    }

    // MARK: - validatedSessionURL(_:)

    func testValidatesReleaseAndDebugSchemes() {
        XCTAssertEqual(ChauffeurProvider.validatedSessionURL(sessionURL)?.absoluteString, sessionURL)
        XCTAssertEqual(ChauffeurProvider.validatedSessionURL(debugSessionURL)?.absoluteString, debugSessionURL)
    }

    func testRejectsForeignSchemesAndHosts() {
        XCTAssertNil(ChauffeurProvider.validatedSessionURL("https://example.com/session/a/b"))
        XCTAssertNil(ChauffeurProvider.validatedSessionURL("file:///etc/passwd"))
        XCTAssertNil(ChauffeurProvider.validatedSessionURL("chauffeur://settings/a/b"))
        XCTAssertNil(ChauffeurProvider.validatedSessionURL("chauffeur-prod://session/a/b"))
        XCTAssertNil(ChauffeurProvider.validatedSessionURL("not a url"))
        XCTAssertNil(ChauffeurProvider.validatedSessionURL(""))
    }

    // MARK: - focus(tty:expectedPid:)

    private final class Recorder {
        var invocations: [[String]] = []
        var opened: [URL] = []
    }

    private func makeProvider(psResult: (status: Int32, stdout: String)?,
                              openSucceeds: Bool = true,
                              recorder: Recorder) -> ChauffeurProvider {
        ChauffeurProvider(
            runCommand: { executable, arguments in
                recorder.invocations.append([executable] + arguments)
                return psResult
            },
            openURL: { url in
                recorder.opened.append(url)
                return openSucceeds
            }
        )
    }

    func testFocusOpensSessionURLVerbatim() {
        let recorder = Recorder()
        let provider = makeProvider(psResult: (0, psDump(url: sessionURL)), recorder: recorder)

        let result = provider.focus(tty: "/dev/ttys004", expectedPid: 4242)

        XCTAssertEqual(result, .focused)
        XCTAssertEqual(recorder.invocations, [["/bin/ps", "eww", "-o", "command=", "-p", "4242"]])
        XCTAssertEqual(recorder.opened.map(\.absoluteString), [sessionURL])
    }

    func testFocusAcceptsDebugScheme() {
        // Debug builds register chauffeur-debug://; the URL must be used as-is,
        // never rebuilt from the session id.
        let recorder = Recorder()
        let provider = makeProvider(psResult: (0, psDump(url: debugSessionURL)), recorder: recorder)

        XCTAssertEqual(provider.focus(tty: "/dev/ttys004", expectedPid: 1), .focused)
        XCTAssertEqual(recorder.opened.map(\.absoluteString), [debugSessionURL])
    }

    func testFocusReturnsNoSuchTabForNonChauffeurSession() {
        let recorder = Recorder()
        let provider = makeProvider(psResult: (0, "claude TERM_PROGRAM=iTerm.app"), recorder: recorder)

        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1), .noSuchTab)
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    func testFocusDoesNotOpenForeignURL() {
        let recorder = Recorder()
        let provider = makeProvider(psResult: (0, psDump(url: "https://example.com/session/a/b")),
                                    recorder: recorder)

        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1),
                       .scriptError("Unrecognized Chauffeur session URL"))
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    func testFocusDoesNotOpenURLWithWrongHost() {
        let recorder = Recorder()
        let provider = makeProvider(psResult: (0, psDump(url: "chauffeur://project/a")), recorder: recorder)

        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1),
                       .scriptError("Unrecognized Chauffeur session URL"))
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    func testFocusReportsScriptErrorWhenPsFails() {
        let recorder = Recorder()
        let provider = makeProvider(psResult: (1, ""), recorder: recorder)

        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1),
                       .scriptError("Could not read the session's environment"))
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    func testFocusReportsScriptErrorWhenRunnerCannotLaunch() {
        let recorder = Recorder()
        let provider = makeProvider(psResult: nil, recorder: recorder)

        XCTAssertEqual(provider.focus(tty: "/dev/ttys001", expectedPid: 1),
                       .scriptError("Could not read the session's environment"))
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    func testFocusReportsScriptErrorWhenOpenIsRefused() {
        let recorder = Recorder()
        let provider = makeProvider(psResult: (0, psDump(url: sessionURL)), openSucceeds: false,
                                    recorder: recorder)

        XCTAssertEqual(provider.focus(tty: "/dev/ttys004", expectedPid: 1),
                       .scriptError("Chauffeur refused to open the session"))
    }

    func testProviderLaunchesOnFocus() {
        // The bridge must consult Chauffeur while it is closed: opening the URL launches it.
        XCTAssertTrue(ChauffeurProvider(runCommand: { _, _ in nil }, openURL: { _ in false }).launchesOnFocus)
    }
}
