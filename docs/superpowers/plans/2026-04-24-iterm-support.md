# iTerm2 Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude Monitor focus Claude Code sessions hosted in iTerm2 in addition to Terminal.app, via a small plug-in seam so more terminals can be added later.

**Architecture:** Extract a narrow `TerminalProvider` protocol and a `CompositeTerminalBridge` that probes enabled providers in registry order and returns on the first `.focused`. Ship two providers: `AppleTerminalProvider` (renamed existing bridge) and `ITerm2Provider`. Auto-detect by click-time probing; Settings exposes per-terminal enable toggles via a `disabledTerminalBundleIDs` set in `Preferences`.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, NSAppleScript, xcodegen, XCTest.

**Spec:** `docs/superpowers/specs/2026-04-24-iterm-support-design.md` (commit `59c6bf2`).

**Working directory:** `.worktrees/iterm-support` on branch `feature/iterm-support`.

**Regenerate Xcode project** after every file move / add / delete: `make gen`.

---

## File Structure

### New files
- `App/Core/Terminal/TerminalProvider.swift` — provider protocol + `FakeTerminalProvider` test double.
- `App/Core/Terminal/CompositeTerminalBridge.swift` — dispatches `focus(...)` across providers; conforms to `TerminalBridgeProtocol`.
- `App/Core/Terminal/AppleTerminalProvider.swift` — Terminal.app provider (body moved from existing `TerminalBridge.swift`, guards removed).
- `App/Core/Terminal/ITerm2Provider.swift` — iTerm2 provider.
- `App/Core/Terminal/TerminalRegistry.swift` — static supported list + `installed()` filter.
- `Tests/CompositeTerminalBridgeTests.swift` — unit tests for dispatch.
- `Tests/PreferencesTests.swift` — unit test for `disabledTerminalBundleIDs` round-trip.
- `IntegrationTests/ITerm2ProviderIntegrationTests.swift` — iTerm2 AppleScript integration test (skipped if iTerm2 not installed).

### Moved files
- `App/Core/TerminalBridgeProtocol.swift` → `App/Core/Terminal/TerminalBridgeProtocol.swift` (same content minus the stale `FakeTerminalBridge` class, which isn't referenced).

### Deleted files
- `App/Core/TerminalBridge.swift` — replaced by `AppleTerminalProvider` + `CompositeTerminalBridge`.

### Modified files
- `App/AppDelegate.swift` — instantiate `CompositeTerminalBridge` instead of `TerminalBridge`.
- `App/Settings/Preferences.swift` — add `disabledTerminalBundleIDs` property.
- `App/UI/SettingsView.swift` — new "Terminal applications" section.
- `project.yml` — update `NSAppleEventsUsageDescription`.
- `IntegrationTests/TerminalBridgeIntegrationTests.swift` — retarget to `AppleTerminalProvider`.
- `CLAUDE.md` — update terminal-support language and `TerminalBridge` architecture section.
- `docs/superpowers/specs/2026-04-23-claude-monitor-design.md` — spot-update the terminal-integration section.

---

## Testing notes

**Unit tests:**
```bash
make gen
make test
```
Default destination is `platform=macOS`. A connected iOS device with a passcode can make `xcodebuild` fail to bootstrap; if so, disconnect it (this is an environmental issue, not a code issue).

**Single unit test:**
```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/CompositeTerminalBridgeTests/test_singleProviderFocused
```

**Integration tests** (real AppleScript):
```bash
make test-integration
# Tests skip themselves unless this env var is set:
RUN_TERMINAL_INTEGRATION=1 make test-integration
```

---

## Task 1: Create `App/Core/Terminal/` and move `TerminalBridgeProtocol`

No behavior change. Sets up the cluster folder.

**Files:**
- Create dir: `App/Core/Terminal/`
- Move: `App/Core/TerminalBridgeProtocol.swift` → `App/Core/Terminal/TerminalBridgeProtocol.swift`
- Delete from moved file: the unused `FakeTerminalBridge` class (no callers — confirmed via grep).

- [ ] **Step 1: Move the protocol file**

```bash
mkdir -p App/Core/Terminal
git mv App/Core/TerminalBridgeProtocol.swift App/Core/Terminal/TerminalBridgeProtocol.swift
```

- [ ] **Step 2: Strip the unused FakeTerminalBridge**

Edit `App/Core/Terminal/TerminalBridgeProtocol.swift` so its full contents become:

```swift
import Foundation

enum FocusResult: Equatable {
    case focused
    case noSuchTab
    case terminalNotRunning
    case scriptError(String)
}

protocol TerminalBridgeProtocol {
    /// Focus the terminal tab whose `tty` matches. `expectedPid` is used by
    /// the implementation as part of a TTY-reuse guard (see CompositeTerminalBridge).
    func focus(tty: String, expectedPid: Int32) -> FocusResult
}
```

- [ ] **Step 3: Regenerate and build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the existing unit tests**

```bash
make test
```

Expected: existing tests pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add App/Core/Terminal/TerminalBridgeProtocol.swift
git commit -m "$(cat <<'EOF'
Move `TerminalBridgeProtocol` into `App/Core/Terminal/`

- regroups terminal-integration code into its own cluster ahead of adding multiple providers
- drops unused `FakeTerminalBridge` test double (no call sites)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Define `TerminalProvider` protocol + `FakeTerminalProvider`

No behavior change yet. Defines the seam the composite will use.

**Files:**
- Create: `App/Core/Terminal/TerminalProvider.swift`

- [ ] **Step 1: Create the file**

```swift
// App/Core/Terminal/TerminalProvider.swift
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
```

- [ ] **Step 2: Regenerate and build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add App/Core/Terminal/TerminalProvider.swift
git commit -m "$(cat <<'EOF'
Add `TerminalProvider` protocol and fake double

- introduces the per-terminal seam that `CompositeTerminalBridge` will fan out across
- ships a `FakeTerminalProvider` with scripted behavior for upcoming composite tests

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: TDD `CompositeTerminalBridge`

Test first. This is the only piece with real dispatch logic.

**Files:**
- Create: `Tests/CompositeTerminalBridgeTests.swift`
- Create: `App/Core/Terminal/CompositeTerminalBridge.swift`

- [ ] **Step 1: Write the failing test file**

Create `Tests/CompositeTerminalBridgeTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run tests — they must fail with compilation error**

```bash
make gen
make test 2>&1 | tail -10
```

Expected: compilation error, "cannot find 'CompositeTerminalBridge'".

- [ ] **Step 3: Implement `CompositeTerminalBridge`**

Create `App/Core/Terminal/CompositeTerminalBridge.swift`:

```swift
// App/Core/Terminal/CompositeTerminalBridge.swift
import Foundation
import Darwin

/// Fans `focus(tty:expectedPid:)` out across a list of `TerminalProvider`s
/// and returns on the first `.focused`. Non-running providers are skipped.
final class CompositeTerminalBridge: TerminalBridgeProtocol {
    private let providers: [TerminalProvider]

    init(providers: [TerminalProvider]) {
        self.providers = providers
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        if providers.isEmpty { return .terminalNotRunning }

        // `kill(pid, 0)` returns 0 if the process exists. ESRCH means really gone;
        // EPERM means alive but owned elsewhere. Only ESRCH is a stale session.
        if kill(expectedPid, 0) != 0 && errno == ESRCH { return .noSuchTab }

        let running = providers.filter { $0.isRunning() }
        if running.isEmpty { return .terminalNotRunning }

        var lastError: FocusResult?
        for provider in running {
            let result = provider.focus(tty: tty, expectedPid: expectedPid)
            switch result {
            case .focused:
                return .focused
            case .scriptError:
                lastError = result
            case .noSuchTab, .terminalNotRunning:
                continue
            }
        }
        return lastError ?? .noSuchTab
    }
}
```

- [ ] **Step 4: Run tests — must pass**

```bash
make gen
make test 2>&1 | tail -15
```

Expected: all `CompositeTerminalBridgeTests` pass; existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/CompositeTerminalBridgeTests.swift App/Core/Terminal/CompositeTerminalBridge.swift
git commit -m "$(cat <<'EOF'
Add `CompositeTerminalBridge` to dispatch focus across providers

- probes enabled providers in order and short-circuits on the first `.focused`
- filters out non-running providers so dormant apps don't burn an AppleScript round-trip
- runs the Swift-side `kill(pid, 0)` ESRCH guard once before any provider call
- surfaces the last `.scriptError` when no provider matches and at least one errored

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Extract `AppleTerminalProvider` from `TerminalBridge`

Move today's Terminal.app logic to a `TerminalProvider`. Slim it: the composite owns the NSWorkspace check and ESRCH guard now.

**Files:**
- Create: `App/Core/Terminal/AppleTerminalProvider.swift`

- [ ] **Step 1: Create the provider**

```swift
// App/Core/Terminal/AppleTerminalProvider.swift
import Foundation

#if canImport(AppKit)
import AppKit
#endif

final class AppleTerminalProvider: TerminalProvider {
    let displayName = "Terminal"
    let bundleID = "com.apple.Terminal"

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        let script = Self.buildScript(tty: tty)
        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let descriptor = appleScript?.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "unknown"
            return .scriptError(msg)
        }
        guard let result = descriptor?.stringValue else {
            return .scriptError("no result string")
        }
        switch result {
        case "focused":     return .focused
        case "no-such-tab": return .noSuchTab
        default:            return .scriptError(result)
        }
    }

    private static func buildScript(tty: String) -> String {
        let safeTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            if not running then return "no-such-tab"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(safeTty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "focused"
                    end if
                end repeat
            end repeat
            return "no-such-tab"
        end tell
        """
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. Old `TerminalBridge.swift` still coexists — we haven't cut over yet.

- [ ] **Step 3: Run tests**

```bash
make test 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add App/Core/Terminal/AppleTerminalProvider.swift
git commit -m "$(cat <<'EOF'
Add `AppleTerminalProvider` conforming to `TerminalProvider`

- lifts today's Terminal.app AppleScript into a provider implementation
- removes the running-app and ESRCH guards (both now owned by `CompositeTerminalBridge`)
- old `TerminalBridge` still in place; cutover follows in a later commit

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `ITerm2Provider` + integration test

No unit test — the provider is a thin AppleScript wrapper, same pattern as `AppleTerminalProvider`. Integration test mirrors the existing Terminal.app one.

**Files:**
- Create: `App/Core/Terminal/ITerm2Provider.swift`
- Create: `IntegrationTests/ITerm2ProviderIntegrationTests.swift`

- [ ] **Step 1: Create the provider**

```swift
// App/Core/Terminal/ITerm2Provider.swift
import Foundation

#if canImport(AppKit)
import AppKit
#endif

final class ITerm2Provider: TerminalProvider {
    let displayName = "iTerm2"
    let bundleID = "com.googlecode.iterm2"

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        let script = Self.buildScript(tty: tty)
        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let descriptor = appleScript?.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "unknown"
            return .scriptError(msg)
        }
        guard let result = descriptor?.stringValue else {
            return .scriptError("no result string")
        }
        switch result {
        case "focused":     return .focused
        case "no-such-tab": return .noSuchTab
        default:            return .scriptError(result)
        }
    }

    private static func buildScript(tty: String) -> String {
        let safeTty = tty.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "iTerm"
            if not running then return "no-such-tab"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(safeTty)" then
                            select s
                            tell t to select
                            set index of w to 1
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
            return "no-such-tab"
        end tell
        """
    }
}
```

- [ ] **Step 2: Create the integration test**

```swift
// IntegrationTests/ITerm2ProviderIntegrationTests.swift
import XCTest
import AppKit
@testable import ClaudeMonitor

final class ITerm2ProviderIntegrationTests: XCTestCase {
    private let provider = ITerm2Provider()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["RUN_TERMINAL_INTEGRATION"] != "1" {
            throw XCTSkip("Set RUN_TERMINAL_INTEGRATION=1 to enable. Requires Automation permission.")
        }
        guard provider.isInstalled else {
            throw XCTSkip("iTerm2 is not installed on this machine.")
        }
    }

    func test_focusSessionByTTY() throws {
        // Open an iTerm2 window running a long-lived command, then read its tty.
        let open = """
        tell application "iTerm"
            activate
            create window with default profile
            delay 0.6
            tell current session of current window
                write text "echo READY; exec sleep 30"
                delay 0.3
                return tty
            end tell
        end tell
        """
        var err: NSDictionary?
        let descriptor = NSAppleScript(source: open)?.executeAndReturnError(&err)
        XCTAssertNil(err, "setup AppleScript failed: \(String(describing: err))")
        let tty = try XCTUnwrap(descriptor?.stringValue)

        // Open a second window so the first isn't frontmost.
        let openSecond = """
        tell application "iTerm"
            create window with default profile
            delay 0.3
            tell current session of current window to write text "echo other"
        end tell
        """
        _ = NSAppleScript(source: openSecond)?.executeAndReturnError(nil)

        let result = provider.focus(tty: tty, expectedPid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(result, .focused)

        // Cleanup: close any window whose current session matches the tty.
        let cleanup = """
        tell application "iTerm"
            repeat with w in windows
                if tty of current session of w is "\(tty)" then close w
            end repeat
        end tell
        """
        _ = NSAppleScript(source: cleanup)?.executeAndReturnError(nil)
    }

    func test_focusReturnsNoSuchTabForUnknownTTY() {
        let result = provider.focus(tty: "/dev/ttys999", expectedPid: ProcessInfo.processInfo.processIdentifier)
        let isAcceptable: Bool = {
            if result == .noSuchTab { return true }
            if case .scriptError = result { return true }
            return false
        }()
        XCTAssertTrue(isAcceptable,
                      "expected noSuchTab (or scriptError if iTerm2 isn't running), got \(result)")
    }
}
```

- [ ] **Step 3: Regenerate and build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -5
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build-for-testing 2>&1 | tail -5
```

Expected: both succeed.

- [ ] **Step 4: Run the unit tests (integration test stays skipped without env var)**

```bash
make test 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add App/Core/Terminal/ITerm2Provider.swift IntegrationTests/ITerm2ProviderIntegrationTests.swift
git commit -m "$(cat <<'EOF'
Add `ITerm2Provider` with focus-by-tty AppleScript

- walks iTerm2's windows → tabs → sessions and matches on session `tty`
- selects session, selects enclosing tab, brings window forward, activates app
- integration test mirrors the Terminal.app one; skips when iTerm2 isn't installed

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add `TerminalRegistry`

Hardcoded list of supported providers + install filter.

**Files:**
- Create: `App/Core/Terminal/TerminalRegistry.swift`

- [ ] **Step 1: Create the file**

```swift
// App/Core/Terminal/TerminalRegistry.swift
import Foundation

/// The hardcoded list of terminal apps Claude Monitor knows how to drive.
/// Order is probe order in `CompositeTerminalBridge`.
///
/// To add another terminal: implement a `TerminalProvider` and add it to `all`.
enum TerminalRegistry {
    static func all() -> [TerminalProvider] {
        [
            AppleTerminalProvider(),
            ITerm2Provider(),
        ]
    }

    static func installed() -> [TerminalProvider] {
        all().filter { $0.isInstalled }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add App/Core/Terminal/TerminalRegistry.swift
git commit -m "$(cat <<'EOF'
Add `TerminalRegistry` listing Terminal.app and iTerm2 providers

- `all()` returns every known provider in probe order
- `installed()` filters to apps present on the current machine via `NSWorkspace`
- adding a new terminal is a one-line change here plus a provider file

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Cut over `AppDelegate` to `CompositeTerminalBridge` and delete old bridge

Wires everything together. After this step the app uses the new bridge.

**Files:**
- Modify: `App/AppDelegate.swift`
- Delete: `App/Core/TerminalBridge.swift`
- Modify: `IntegrationTests/TerminalBridgeIntegrationTests.swift` (use `AppleTerminalProvider`)

- [ ] **Step 1: Update `AppDelegate`**

Edit `App/AppDelegate.swift`. Replace the line:

```swift
private var bridge: TerminalBridgeProtocol = TerminalBridge()
```

with:

```swift
private var bridge: TerminalBridgeProtocol = CompositeTerminalBridge(
    providers: TerminalRegistry.installed()
)
```

- [ ] **Step 2: Retarget the Terminal.app integration test**

Edit `IntegrationTests/TerminalBridgeIntegrationTests.swift` so every `TerminalBridge()` becomes `AppleTerminalProvider()`. The full updated file:

```swift
import XCTest
@testable import ClaudeMonitor

final class TerminalBridgeIntegrationTests: XCTestCase {
    private let provider = AppleTerminalProvider()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["RUN_TERMINAL_INTEGRATION"] != "1" {
            throw XCTSkip("Set RUN_TERMINAL_INTEGRATION=1 to enable. Requires Automation permission.")
        }
    }

    func test_focusTabByTTY() throws {
        let open = """
        tell application "Terminal"
            activate
            set newTab to do script "echo READY; exec sleep 30"
            delay 0.6
            return tty of newTab
        end tell
        """
        var err: NSDictionary?
        let descriptor = NSAppleScript(source: open)?.executeAndReturnError(&err)
        XCTAssertNil(err, "setup AppleScript failed: \(String(describing: err))")
        let tty = try XCTUnwrap(descriptor?.stringValue)

        let openSecond = #"tell application "Terminal" to do script "echo other""#
        _ = NSAppleScript(source: openSecond)?.executeAndReturnError(nil)

        let result = provider.focus(tty: tty, expectedPid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(result, .focused)

        let cleanup = """
        tell application "Terminal"
            close (every window whose tty of selected tab is "\(tty)")
        end tell
        """
        _ = NSAppleScript(source: cleanup)?.executeAndReturnError(nil)
    }

    func test_focusReturnsNoSuchTabForUnknownTTY() {
        let result = AppleTerminalProvider().focus(tty: "/dev/ttys999",
                                                    expectedPid: ProcessInfo.processInfo.processIdentifier)
        let isAcceptable: Bool = {
            if result == .noSuchTab { return true }
            if case .scriptError = result { return true }
            return false
        }()
        XCTAssertTrue(isAcceptable,
                      "expected noSuchTab (or scriptError if Terminal isn't running), got \(result)")
    }
}
```

- [ ] **Step 3: Delete the old bridge**

```bash
git rm App/Core/TerminalBridge.swift
```

- [ ] **Step 4: Regenerate and build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Run unit tests**

```bash
make test 2>&1 | tail -15
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
Wire `CompositeTerminalBridge` and delete the old `TerminalBridge`

- `AppDelegate` now focuses tiles through the composite over installed providers
- deletes the original monolithic bridge in favor of the provider cluster
- retargets the Terminal.app integration test at `AppleTerminalProvider` directly

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Add `disabledTerminalBundleIDs` to `Preferences`

TDD the round-trip through `UserDefaults`.

**Files:**
- Create: `Tests/PreferencesTests.swift`
- Modify: `App/Settings/Preferences.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/PreferencesTests.swift`:

```swift
import XCTest
@testable import ClaudeMonitor

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ClaudeMonitorPreferencesTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func test_disabledTerminalBundleIDs_defaultsToEmpty() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.disabledTerminalBundleIDs, [])
    }

    func test_disabledTerminalBundleIDs_roundTrips() {
        let prefs = Preferences(defaults: defaults)
        prefs.disabledTerminalBundleIDs = ["com.googlecode.iterm2"]
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.disabledTerminalBundleIDs, ["com.googlecode.iterm2"])
    }

    func test_disabledTerminalBundleIDs_cleared() {
        let prefs = Preferences(defaults: defaults)
        prefs.disabledTerminalBundleIDs = ["com.apple.Terminal", "com.googlecode.iterm2"]
        prefs.disabledTerminalBundleIDs = []
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.disabledTerminalBundleIDs, [])
    }
}
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
make gen
make test 2>&1 | tail -10
```

Expected: "value of type 'Preferences' has no member 'disabledTerminalBundleIDs'".

- [ ] **Step 3: Add the property**

Edit `App/Settings/Preferences.swift` so its full contents become:

```swift
// App/Settings/Preferences.swift
import Foundation
import SwiftUI

/// Central access to persisted user preferences.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var managedConfigDirectoryPaths: [String] {
        didSet { defaults.set(managedConfigDirectoryPaths, forKey: Self.configDirsKey) }
    }

    @Published var manualTileOrder: [String] {
        didSet { defaults.set(manualTileOrder, forKey: Self.tileOrderKey) }
    }

    @Published var disabledTerminalBundleIDs: Set<String> {
        didSet { defaults.set(Array(disabledTerminalBundleIDs), forKey: Self.disabledTerminalsKey) }
    }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Self.onboardedKey) }
        set { defaults.set(newValue, forKey: Self.onboardedKey) }
    }

    static let windowFrameAutosaveName = "ClaudeMonitorDashboardWindow"
    private static let configDirsKey = "managedConfigDirectories"
    private static let tileOrderKey = "manualTileOrder"
    private static let onboardedKey = "onboarded"
    private static let disabledTerminalsKey = "disabledTerminals"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.managedConfigDirectoryPaths = defaults.stringArray(forKey: Self.configDirsKey) ?? []
        self.manualTileOrder = defaults.stringArray(forKey: Self.tileOrderKey) ?? []
        self.disabledTerminalBundleIDs = Set(defaults.stringArray(forKey: Self.disabledTerminalsKey) ?? [])
    }
}
```

- [ ] **Step 4: Run — expect passes**

```bash
make test 2>&1 | tail -10
```

Expected: `PreferencesTests` green; all others still green.

- [ ] **Step 5: Commit**

```bash
git add Tests/PreferencesTests.swift App/Settings/Preferences.swift
git commit -m "$(cat <<'EOF'
Persist `disabledTerminalBundleIDs` in Preferences

- stores the set of terminals the user has explicitly turned off
- default empty means every installed terminal is active — no migration for existing users
- round-trips through UserDefaults with test coverage

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Thread disabled set into `CompositeTerminalBridge`

Extend the bridge to filter out disabled providers. TDD the filter first.

**Files:**
- Modify: `Tests/CompositeTerminalBridgeTests.swift`
- Modify: `App/Core/Terminal/CompositeTerminalBridge.swift`
- Modify: `App/AppDelegate.swift`

- [ ] **Step 1: Add the failing test**

Append to `Tests/CompositeTerminalBridgeTests.swift` (before the closing brace of the class):

```swift
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
```

- [ ] **Step 2: Run — expect compilation failure**

```bash
make test 2>&1 | tail -10
```

Expected: extra-argument-in-call error for `isDisabled:`.

- [ ] **Step 3: Extend `CompositeTerminalBridge`**

Replace the full body of `App/Core/Terminal/CompositeTerminalBridge.swift` with:

```swift
// App/Core/Terminal/CompositeTerminalBridge.swift
import Foundation
import Darwin

final class CompositeTerminalBridge: TerminalBridgeProtocol {
    private let providers: [TerminalProvider]
    private let isDisabled: (String) -> Bool

    /// - Parameters:
    ///   - providers: Ordered list. First `.focused` wins.
    ///   - isDisabled: Given a bundle ID, returns true if the user has opted it out.
    init(providers: [TerminalProvider],
         isDisabled: @escaping (String) -> Bool = { _ in false }) {
        self.providers = providers
        self.isDisabled = isDisabled
    }

    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        let enabled = providers.filter { !isDisabled($0.bundleID) }
        if enabled.isEmpty { return .terminalNotRunning }

        if kill(expectedPid, 0) != 0 && errno == ESRCH { return .noSuchTab }

        let running = enabled.filter { $0.isRunning() }
        if running.isEmpty { return .terminalNotRunning }

        var lastError: FocusResult?
        for provider in running {
            let result = provider.focus(tty: tty, expectedPid: expectedPid)
            switch result {
            case .focused:
                return .focused
            case .scriptError:
                lastError = result
            case .noSuchTab, .terminalNotRunning:
                continue
            }
        }
        return lastError ?? .noSuchTab
    }
}
```

- [ ] **Step 4: Update `AppDelegate` to pass the closure**

Edit `App/AppDelegate.swift`. Change:

```swift
private var bridge: TerminalBridgeProtocol = CompositeTerminalBridge(
    providers: TerminalRegistry.installed()
)
```

to use a stored closure that reads from `preferences` lazily. Because `bridge` initializes before `self` is available, switch to `lazy var`:

```swift
private lazy var bridge: TerminalBridgeProtocol = CompositeTerminalBridge(
    providers: TerminalRegistry.installed(),
    isDisabled: { [weak self] bundleID in
        self?.preferences.disabledTerminalBundleIDs.contains(bundleID) ?? false
    }
)
```

- [ ] **Step 5: Run — expect passes**

```bash
make gen
make test 2>&1 | tail -15
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Tests/CompositeTerminalBridgeTests.swift App/Core/Terminal/CompositeTerminalBridge.swift App/AppDelegate.swift
git commit -m "$(cat <<'EOF'
Filter disabled terminals in `CompositeTerminalBridge`

- bridge now takes an `isDisabled(bundleID)` closure so the Preferences toggle takes effect
- disabled-everywhere case short-circuits to `terminalNotRunning` before hitting AppleScript
- `AppDelegate` wires the closure to read `preferences.disabledTerminalBundleIDs` at call time

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Add "Terminal applications" section to `SettingsView`

Toggle row per installed provider. Writes to `preferences.disabledTerminalBundleIDs`.

**Files:**
- Modify: `App/UI/SettingsView.swift`

- [ ] **Step 1: Read the current `SettingsView.swift`**

The file starts with a `VStack(alignment: .leading, spacing: 12)` containing the managed-directories section. We'll append a divider + the new section inside the same VStack. Also widen the window frame to accommodate the extra rows.

- [ ] **Step 2: Add helper state and the terminals section**

Edit `App/UI/SettingsView.swift`. Add a new `@State` near the existing one:

```swift
@State private var installedTerminals: [TerminalProvider] = []
```

Inside the `body`'s `VStack`, immediately **after** the `HStack` that holds "Add Directory…" / "Redetect" and **before** the `if let errorMessage` block, insert:

```swift
Divider().padding(.vertical, 6)

Text("Terminal applications").font(.headline)
Text("Claude Monitor auto-detects which app hosts each Claude session. Uncheck to skip a terminal when focusing tabs.")
    .font(.caption)
    .foregroundStyle(.secondary)

if installedTerminals.isEmpty {
    Text("No supported terminal applications installed.")
        .font(.caption)
        .foregroundStyle(.secondary)
} else {
    ForEach(installedTerminals, id: \.bundleID) { provider in
        Toggle(isOn: terminalBinding(for: provider.bundleID)) {
            HStack {
                Text(provider.displayName)
                Text("(\(provider.bundleID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    if allTerminalsDisabled {
        Text("No terminal enabled — clicking a tile won't focus anything.")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}
```

Extend the existing `.onAppear { refresh() }` so it also loads terminals:

```swift
.onAppear {
    refresh()
    installedTerminals = TerminalRegistry.installed()
}
```

And widen the frame to give the new section room. Change:

```swift
.frame(width: 560, height: 420)
```

to:

```swift
.frame(width: 560, height: 560)
```

Add these helpers at the bottom of the `SettingsView` struct (alongside `refresh()` etc.):

```swift
private var allTerminalsDisabled: Bool {
    guard !installedTerminals.isEmpty else { return false }
    return installedTerminals.allSatisfy { preferences.disabledTerminalBundleIDs.contains($0.bundleID) }
}

private func terminalBinding(for bundleID: String) -> Binding<Bool> {
    Binding(
        get: { !preferences.disabledTerminalBundleIDs.contains(bundleID) },
        set: { newValue in
            if newValue {
                preferences.disabledTerminalBundleIDs.remove(bundleID)
            } else {
                preferences.disabledTerminalBundleIDs.insert(bundleID)
            }
        }
    )
}
```

- [ ] **Step 3: Build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run tests**

```bash
make test 2>&1 | tail -10
```

Expected: all green (this step has no new unit tests; SettingsView is SwiftUI UI code).

- [ ] **Step 5: Commit**

```bash
git add App/UI/SettingsView.swift
git commit -m "$(cat <<'EOF'
Add Terminal applications toggles to Settings

- lists installed terminal providers with a checkbox each, disabled ones opt out of focus dispatch
- warns when every terminal is unchecked so the user knows clicks won't focus anything
- widens the settings window to fit the new section

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Update `NSAppleEventsUsageDescription`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Edit the value**

In `project.yml`, change:

```yaml
        NSAppleEventsUsageDescription: "Claude Monitor uses Apple events to focus the Terminal.app tab of a selected Claude Code session."
```

to:

```yaml
        NSAppleEventsUsageDescription: "Claude Monitor uses Apple events to focus the Terminal.app or iTerm2 tab of a selected Claude Code session."
```

- [ ] **Step 2: Regenerate and build**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "$(cat <<'EOF'
Mention iTerm2 in `NSAppleEventsUsageDescription`

- the TCC prompt now reflects both Terminal.app and iTerm2 as automation targets

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Update docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-04-23-claude-monitor-design.md`
- Modify: `README.md` (if it mentions supported terminals — grep first)

- [ ] **Step 1: Update `CLAUDE.md` — project line**

Change the line:

> `ClaudeMonitor` is a native macOS 14+ SwiftUI app that shows the live state of every local Claude Code CLI session as colored tiles. Each session reports transitions through Claude Code hooks; clicking a tile focuses the hosting Terminal.app tab. Only Terminal.app is supported — not iTerm, not VS Code terminals.

to:

> `ClaudeMonitor` is a native macOS 14+ SwiftUI app that shows the live state of every local Claude Code CLI session as colored tiles. Each session reports transitions through Claude Code hooks; clicking a tile focuses the hosting terminal tab. Terminal.app and iTerm2 are supported; other terminals (Ghostty, WezTerm, VS Code's integrated terminal) are not.

- [ ] **Step 2: Update `CLAUDE.md` — TerminalBridge architecture section**

Replace the existing `### TerminalBridge` section with:

```markdown
### Terminal dispatch

Click handling goes through `App/Core/Terminal/CompositeTerminalBridge.swift`,
which fans `focus(tty:expectedPid:)` out across a list of `TerminalProvider`s
in registry order (`TerminalRegistry.all()`). The first provider whose
AppleScript reports `.focused` wins.

The composite owns two guards that used to live in `TerminalBridge`:

1. `NSWorkspace.runningApplications` — skip providers whose app isn't running.
2. `kill(expectedPid, 0)` with ESRCH — short-circuit when the Claude process is
   truly gone (macOS recycles `/dev/ttysNNN` when tabs close).

Providers themselves (`AppleTerminalProvider`, `ITerm2Provider`) are thin
AppleScript wrappers. The third guard — matching on `tty` inside the AppleScript
— is per-provider because Terminal.app puts `tty` on tabs while iTerm2 puts it
on sessions.

User-disabled terminals come from `preferences.disabledTerminalBundleIDs`
(Settings: "Terminal applications" section). Disabled-list semantics mean the
default empty set opts every installed terminal in.

Unit tests drive the composite with `FakeTerminalProvider`. Real AppleScript
integration tests for each provider run only under `make test-integration`.
```

- [ ] **Step 3: Update the design spec spot**

In `docs/superpowers/specs/2026-04-23-claude-monitor-design.md`, find the section that describes `TerminalBridge` (search for "TerminalBridge" or "Terminal.app"). Update the prose to match the new provider-based architecture. Keep edits minimal — one paragraph rewrite, not a full overhaul. If the original spec's wording still describes behavior accurately (e.g., the three-guard model), add a short sentence pointing readers to the newer iTerm2 spec (`docs/superpowers/specs/2026-04-24-iterm-support-design.md`).

- [ ] **Step 4: Check README**

```bash
grep -n "Terminal\.app\|iTerm\|supported terminals" README.md 2>/dev/null
```

If matches exist and they claim Terminal.app-only, update them to "Terminal.app and iTerm2". If no matches, skip this edit.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-04-23-claude-monitor-design.md README.md 2>/dev/null
git commit -m "$(cat <<'EOF'
Document Terminal.app + iTerm2 support and provider dispatch

- `CLAUDE.md` now lists both supported terminals and explains the composite/provider split
- design spec cross-links the newer iTerm2 spec so future readers find the current model
- README (if it lists terminals) reflects both apps

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Manual smoke verification

Final check. No code, no commit — just eyeball the behavior.

- [ ] **Step 1: Build and install a fresh app**

```bash
make gen
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -5
```

Run the app from Xcode (Cmd-R in Xcode or `open` the built `.app`).

- [ ] **Step 2: Terminal.app smoke**

With Claude Monitor running and at least one Terminal.app tab hosting a Claude session:
- Confirm the tile appears.
- Click the tile → Terminal.app comes forward and the right tab is focused.

- [ ] **Step 3: iTerm2 smoke**

Open a Claude session in iTerm2:
- Confirm the tile appears in the dashboard.
- Click it → macOS may prompt for Automation permission the first time; grant it. iTerm2 comes forward, the right session is focused.

- [ ] **Step 4: Settings toggles**

Open Settings:
- Verify both "Terminal" and "iTerm2" rows appear.
- Uncheck Terminal. Click a Terminal-hosted tile. Confirm nothing happens (and a beep fires).
- Recheck Terminal. Uncheck iTerm2. Click an iTerm-hosted tile. Confirm nothing happens.
- Uncheck both. Confirm the orange "No terminal enabled" caption appears.

- [ ] **Step 5: Record the result**

If all four pass, report back. If any fail, open an issue and decide whether to patch forward or revert.

---

## Plan self-review notes

Spec coverage check passed against `docs/superpowers/specs/2026-04-24-iterm-support-design.md`:

- Auto-detection by click-time probe → Task 3 (composite) + Task 7 (wiring)
- `TerminalProvider` protocol and composite → Tasks 2, 3
- Folder layout under `App/Core/Terminal/` → Tasks 1–6
- `AppleTerminalProvider` extracted → Task 4
- `ITerm2Provider` with session-level `tty` → Task 5
- `TerminalRegistry` with install filter → Task 6
- `disabledTerminalBundleIDs` in Preferences with disabled-list semantics → Task 8
- Settings section with per-provider toggle + all-disabled caption → Task 10
- `NSAppleEventsUsageDescription` updated → Task 11
- Unit test coverage (composite + preferences) → Tasks 3, 8, 9
- Integration test for iTerm2 → Task 5
- Docs updated → Task 12
- Out-of-scope items (Ghostty/hardened runtime/tmux-CC) explicitly documented in spec.

No open placeholders. Method signatures consistent across tasks.
