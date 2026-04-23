import XCTest
@testable import ClaudeMonitor

final class CompositeTerminalBridgeTests: XCTestCase {
    // Use the current process pid so the ESRCH guard always passes unless
    // explicitly overridden.
    private var livePid: Int32 { ProcessInfo.processInfo.processIdentifier }

    func test_emptyProviders_returnsTerminalNotRunning() {
        let bridge = CompositeTerminalBridge(providers: [])
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid), .terminalNotRunning)
    }

    func test_singleProviderFocused() {
        let p = FakeTerminalProvider(displayName: "X", bundleID: "x",
                                     focusHandler: { _, _ in .focused })
        let bridge = CompositeTerminalBridge(providers: [p])
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid), .focused)
        XCTAssertEqual(p.focusCallCount, 1)
    }

    func test_firstNoSuchTabSecondFocused_returnsFocused_inOrder() {
        let p1 = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                      focusHandler: { _, _ in .noSuchTab })
        let p2 = FakeTerminalProvider(displayName: "B", bundleID: "b",
                                      focusHandler: { _, _ in .focused })
        let bridge = CompositeTerminalBridge(providers: [p1, p2])
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid), .focused)
        XCTAssertEqual(p1.focusCallCount, 1)
        XCTAssertEqual(p2.focusCallCount, 1)
    }

    func test_allNoSuchTab_returnsNoSuchTab() {
        let p1 = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                      focusHandler: { _, _ in .noSuchTab })
        let p2 = FakeTerminalProvider(displayName: "B", bundleID: "b",
                                      focusHandler: { _, _ in .noSuchTab })
        let bridge = CompositeTerminalBridge(providers: [p1, p2])
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid), .noSuchTab)
    }

    func test_allScriptError_returnsLastScriptError() {
        let p1 = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                      focusHandler: { _, _ in .scriptError("first") })
        let p2 = FakeTerminalProvider(displayName: "B", bundleID: "b",
                                      focusHandler: { _, _ in .scriptError("second") })
        let bridge = CompositeTerminalBridge(providers: [p1, p2])
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid),
                       .scriptError("second"))
    }

    func test_focusedShortCircuits_laterProvidersNotCalled() {
        let p1 = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                      focusHandler: { _, _ in .focused })
        let p2 = FakeTerminalProvider(displayName: "B", bundleID: "b",
                                      focusHandler: { _, _ in .focused })
        let bridge = CompositeTerminalBridge(providers: [p1, p2])
        _ = bridge.focus(tty: "/dev/ttys001", expectedPid: livePid)
        XCTAssertEqual(p1.focusCallCount, 1)
        XCTAssertEqual(p2.focusCallCount, 0)
    }

    func test_notRunningProvider_isSkipped() {
        let skipped = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                           runningHandler: { false },
                                           focusHandler: { _, _ in
            XCTFail("should not call focus on non-running provider")
            return .focused
        })
        let active = FakeTerminalProvider(displayName: "B", bundleID: "b",
                                          focusHandler: { _, _ in .focused })
        let bridge = CompositeTerminalBridge(providers: [skipped, active])
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid), .focused)
    }

    func test_allProvidersNotRunning_returnsTerminalNotRunning() {
        let p = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                     runningHandler: { false })
        let bridge = CompositeTerminalBridge(providers: [p])
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid),
                       .terminalNotRunning)
    }

    func test_deadPid_shortCircuitsBeforeProviderCall() {
        let provider = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                            focusHandler: { _, _ in
            XCTFail("should not call focus when pid is dead (ESRCH)")
            return .focused
        })
        let bridge = CompositeTerminalBridge(providers: [provider])
        // An int32 near max is astronomically unlikely to be a live pid.
        let result = bridge.focus(tty: "/dev/ttys001", expectedPid: 2_147_483_000)
        XCTAssertEqual(result, .noSuchTab)
        XCTAssertEqual(provider.focusCallCount, 0)
    }

    func test_disabledBundleID_filtersProvider() {
        let off = FakeTerminalProvider(displayName: "A", bundleID: "off",
                                       focusHandler: { _, _ in
            XCTFail("disabled provider must not be called")
            return .focused
        })
        let on = FakeTerminalProvider(displayName: "B", bundleID: "on",
                                      focusHandler: { _, _ in .focused })
        let bridge = CompositeTerminalBridge(
            providers: [off, on],
            isDisabled: { $0 == "off" }
        )
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid), .focused)
    }

    func test_allDisabled_returnsTerminalNotRunning() {
        let p = FakeTerminalProvider(displayName: "A", bundleID: "a",
                                     focusHandler: { _, _ in .focused })
        let bridge = CompositeTerminalBridge(
            providers: [p],
            isDisabled: { _ in true }
        )
        XCTAssertEqual(bridge.focus(tty: "/dev/ttys001", expectedPid: livePid),
                       .terminalNotRunning)
    }
}
