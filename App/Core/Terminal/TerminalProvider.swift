import Foundation

/// A single terminal application's focus-by-tty implementation.
/// `CompositeTerminalBridge` fans out across registered providers.
protocol TerminalProvider {
    var displayName: String { get }
    var bundleID: String { get }
    var isInstalled: Bool { get }
    func isRunning() -> Bool
    func focus(tty: String, expectedPid: Int32) -> FocusResult
}

/// Test double. Behavior is scripted via closures.
final class FakeTerminalProvider: TerminalProvider {
    let displayName: String
    let bundleID: String
    var isInstalled: Bool
    var runningHandler: () -> Bool
    var focusHandler: (String, Int32) -> FocusResult
    private(set) var focusCallCount: Int = 0
    private(set) var lastFocusTty: String?

    init(displayName: String,
         bundleID: String,
         isInstalled: Bool = true,
         runningHandler: @escaping () -> Bool = { true },
         focusHandler: @escaping (String, Int32) -> FocusResult = { _, _ in .noSuchTab }) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.isInstalled = isInstalled
        self.runningHandler = runningHandler
        self.focusHandler = focusHandler
    }

    func isRunning() -> Bool { runningHandler() }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        focusCallCount += 1
        lastFocusTty = tty
        return focusHandler(tty, expectedPid)
    }
}
