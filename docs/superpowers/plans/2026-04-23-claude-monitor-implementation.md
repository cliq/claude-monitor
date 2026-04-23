# Claude Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS app that monitors every Claude Code CLI session on the machine via hooks and shows each session as a live, colored tile in a vertical-first grid, with click-to-focus into the hosting Terminal.app tab.

**Architecture:** SwiftUI app on macOS 14+. A single bash hook script is registered into one or more Claude config directories (`~/.claude`, `~/.claudewho-*`) and POSTs JSON events to a local HTTP server embedded in the app. Events flow through a pure `StateMachine` into an observable `SessionStore`, which drives a custom-`Layout` grid of `TileView`s. A `TerminalBridge` uses AppleScript to focus the Terminal.app tab whose `tty` was recorded at session start.

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit (NSStatusItem, NSWindow), Network.framework (HTTP), Foundation, XCTest. XcodeGen for project generation. bash + curl for the hook script. AppleScript via `NSAppleScript` for Terminal.app control.

**Reference:** `docs/superpowers/specs/2026-04-23-claude-monitor-design.md`

---

## File Structure

```
claude-monitor/
├── .gitignore                                  # already exists
├── project.yml                                 # XcodeGen spec
├── Makefile                                    # convenience: make gen / make test
├── scripts/
│   └── hook.sh                                 # template copied to ~/.claude-monitor/hook.sh at install time
├── App/
│   ├── ClaudeMonitorApp.swift                  # @main
│   ├── AppDelegate.swift                       # NSApplicationDelegate
│   ├── Models/
│   │   ├── SessionState.swift                  # enum: working/waiting/needsYou/finished
│   │   ├── Session.swift                       # struct: id, cwd, tty, pid, state, enteredStateAt, lastPrompt
│   │   ├── HookEvent.swift                     # struct decoded from POST body
│   │   └── ManagedConfigDirectory.swift        # struct: path, installStatus, installedVersion
│   ├── Core/
│   │   ├── StateMachine.swift                  # pure (SessionState, HookEvent) -> SessionState
│   │   ├── SessionStore.swift                  # ObservableObject; owns sessions + order
│   │   ├── Clock.swift                         # protocol Clock + SystemClock / FakeClock
│   │   ├── EventServer.swift                   # HTTP via Network.framework
│   │   ├── PortFileWriter.swift                # atomic write of ~/.claude-monitor/port
│   │   ├── HookInstaller.swift                 # merges managed block into <dir>/settings.json
│   │   ├── ConfigDirectoryDiscovery.swift      # finds ~/.claude and ~/.claudewho-*
│   │   ├── TerminalBridgeProtocol.swift        # protocol + FocusResult enum
│   │   ├── TerminalBridge.swift                # real impl via NSAppleScript
│   │   ├── StaleSessionSweeper.swift           # every 60s: kill(pid,0) check
│   │   └── SingleInstanceGuard.swift           # pidfile at ~/.claude-monitor/pid
│   ├── UI/
│   │   ├── DashboardWindow.swift               # NSWindow wrapper + frame autosave
│   │   ├── DashboardView.swift                 # SwiftUI grid root
│   │   ├── TileView.swift                      # 160x80 tile
│   │   ├── VerticalFirstGridLayout.swift       # custom Layout protocol impl
│   │   ├── FlashModifier.swift                 # ViewModifier
│   │   ├── MenuBarController.swift             # NSStatusItem
│   │   ├── OnboardingView.swift                # first-run sheet
│   │   └── SettingsView.swift                  # Settings scene
│   └── Settings/
│       └── Preferences.swift                   # @AppStorage-backed wrapper
├── Tests/
│   ├── StateMachineTests.swift
│   ├── SessionStoreTests.swift
│   ├── EventServerTests.swift
│   ├── HookInstallerTests.swift
│   ├── ConfigDirectoryDiscoveryTests.swift
│   ├── VerticalFirstGridLayoutTests.swift
│   ├── StaleSessionSweeperTests.swift
│   ├── HookScriptTests.swift                   # XCTest that spawns hook.sh
│   └── Fixtures/
│       └── settings-*.json                     # installer fixtures
└── IntegrationTests/
    └── TerminalBridgeIntegrationTests.swift    # real Terminal.app, gated by env var
```

Each file has a single responsibility. No file in `Core/` imports SwiftUI. No file in `UI/` talks directly to `EventServer` or the filesystem — it goes through `SessionStore` and `Preferences`.

---

## Task 1: Scaffold Xcode project with XcodeGen

**Files:**
- Create: `project.yml`
- Create: `Makefile`
- Create: `App/ClaudeMonitorApp.swift` (placeholder)
- Create: `Tests/PlaceholderTests.swift` (temporary — removed in Task 3)

- [ ] **Step 1: Write `project.yml`**

```yaml
name: ClaudeMonitor
options:
  bundleIdPrefix: com.leolobato.claudemonitor
  deploymentTarget:
    macOS: "14.0"
  developmentLanguage: en
settings:
  base:
    SWIFT_VERSION: "5.10"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    CODE_SIGN_STYLE: Automatic
    ENABLE_HARDENED_RUNTIME: NO
targets:
  ClaudeMonitor:
    type: application
    platform: macOS
    sources:
      - path: App
    resources:
      - path: scripts/hook.sh
    info:
      path: App/Info.plist
      properties:
        LSUIElement: false
        NSAppleEventsUsageDescription: "Claude Monitor uses Apple events to focus the Terminal.app tab of a selected Claude Code session."
    settings:
      base:
        PRODUCT_NAME: ClaudeMonitor
        PRODUCT_BUNDLE_IDENTIFIER: com.leolobato.claudemonitor
  ClaudeMonitorTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
    dependencies:
      - target: ClaudeMonitor
  ClaudeMonitorIntegrationTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: IntegrationTests
    dependencies:
      - target: ClaudeMonitor
```

- [ ] **Step 2: Write `Makefile`**

```makefile
.PHONY: gen test test-integration clean open

gen:
	xcodegen generate

test:
	set -o pipefail && xcodebuild test \
	  -project ClaudeMonitor.xcodeproj \
	  -scheme ClaudeMonitor \
	  -destination 'platform=macOS' \
	  -only-testing:ClaudeMonitorTests \
	  | xcpretty

test-integration:
	set -o pipefail && xcodebuild test \
	  -project ClaudeMonitor.xcodeproj \
	  -scheme ClaudeMonitor \
	  -destination 'platform=macOS' \
	  -only-testing:ClaudeMonitorIntegrationTests \
	  | xcpretty

clean:
	rm -rf ClaudeMonitor.xcodeproj
	xcodebuild -project ClaudeMonitor.xcodeproj clean 2>/dev/null || true

open: gen
	open ClaudeMonitor.xcodeproj
```

- [ ] **Step 3: Write placeholder `App/ClaudeMonitorApp.swift`**

```swift
import SwiftUI

@main
struct ClaudeMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Claude Monitor — scaffolding")
                .frame(minWidth: 300, minHeight: 200)
        }
    }
}
```

- [ ] **Step 4: Write placeholder `Tests/PlaceholderTests.swift`**

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func test_buildSystemCompiles() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 5: Generate and build**

Run: `brew list xcodegen >/dev/null 2>&1 || brew install xcodegen`
Run: `make gen`
Run: `xcodebuild build -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Run the placeholder test**

Run: `make test`
Expected: `** TEST SUCCEEDED **` with `PlaceholderTests.test_buildSystemCompiles` green.

- [ ] **Step 7: Commit**

Add `ClaudeMonitor.xcodeproj/` to `.gitignore` (it's a generated artifact — XcodeGen re-creates it from `project.yml`).

```bash
printf '\nClaudeMonitor.xcodeproj/\n' >> .gitignore
git add .gitignore project.yml Makefile App/ClaudeMonitorApp.swift Tests/PlaceholderTests.swift
git commit -m "Scaffold Xcode project with XcodeGen"
```

---

## Task 2: `SessionState` enum

**Files:**
- Create: `App/Models/SessionState.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

enum SessionState: String, Codable, Equatable, CaseIterable {
    case working
    case waiting
    case needsYou
    case finished
}

extension SessionState {
    /// Tile background color. Keep values in sync with the spec.
    var tileColor: Color {
        switch self {
        case .working:  return Color(red: 0x3B/255, green: 0x82/255, blue: 0xF6/255)
        case .waiting:  return Color(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255)
        case .needsYou: return Color(red: 0xEF/255, green: 0x44/255, blue: 0x44/255)
        case .finished: return Color(red: 0x6B/255, green: 0x72/255, blue: 0x80/255)
        }
    }

    var displayLabel: String {
        switch self {
        case .working:  return "Working"
        case .waiting:  return "Waiting"
        case .needsYou: return "Needs you"
        case .finished: return "Finished"
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild build -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Models/SessionState.swift
git commit -m "Add SessionState enum with tile colors"
```

---

## Task 3: `HookEvent` and `HookName` models

**Files:**
- Create: `App/Models/HookEvent.swift`
- Create: `Tests/HookEventTests.swift`
- Delete: `Tests/PlaceholderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/HookEventTests.swift
import XCTest
@testable import ClaudeMonitor

final class HookEventTests: XCTestCase {
    func test_decodesUserPromptSubmitPayload() throws {
        let json = """
        {
          "hook": "UserPromptSubmit",
          "session_id": "abc123",
          "tty": "/dev/ttys005",
          "pid": 78412,
          "cwd": "/Users/leo/Projects/foo",
          "ts": 1745438400,
          "prompt_preview": "Refactor the hook registrar…"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        XCTAssertEqual(event.hook, .userPromptSubmit)
        XCTAssertEqual(event.sessionId, "abc123")
        XCTAssertEqual(event.tty, "/dev/ttys005")
        XCTAssertEqual(event.pid, 78412)
        XCTAssertEqual(event.cwd, "/Users/leo/Projects/foo")
        XCTAssertEqual(event.ts, 1745438400)
        XCTAssertEqual(event.promptPreview, "Refactor the hook registrar…")
    }

    func test_decodesSessionStartWithNoPromptPreview() throws {
        let json = """
        {"hook":"SessionStart","session_id":"x","tty":"/dev/ttys001","pid":1,"cwd":"/","ts":1}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.hook, .sessionStart)
        XCTAssertNil(event.promptPreview)
    }

    func test_rejectsUnknownHookName() {
        let json = """
        {"hook":"Bogus","session_id":"x","tty":"/","pid":1,"cwd":"/","ts":1}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(HookEvent.self, from: json))
    }
}
```

- [ ] **Step 2: Delete the placeholder test**

```bash
rm Tests/PlaceholderTests.swift
```

Re-run: `make gen` (so the new file is picked up)

- [ ] **Step 3: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `HookEvent` type not defined.

- [ ] **Step 4: Create `HookEvent.swift`**

```swift
// App/Models/HookEvent.swift
import Foundation

enum HookName: String, Codable {
    case sessionStart     = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case stop             = "Stop"
    case notification     = "Notification"
    case sessionEnd       = "SessionEnd"
}

struct HookEvent: Codable, Equatable {
    let hook: HookName
    let sessionId: String
    let tty: String
    let pid: Int32
    let cwd: String
    let ts: Int
    let promptPreview: String?
    let toolName: String?

    enum CodingKeys: String, CodingKey {
        case hook
        case sessionId      = "session_id"
        case tty
        case pid
        case cwd
        case ts
        case promptPreview  = "prompt_preview"
        case toolName       = "tool_name"
    }
}
```

- [ ] **Step 5: Re-gen project, run test**

```bash
make gen && make test
```

Expected: PASS (3 tests in `HookEventTests`).

- [ ] **Step 6: Commit**

```bash
git add App/Models/HookEvent.swift Tests/HookEventTests.swift
git rm Tests/PlaceholderTests.swift
git commit -m "Add HookEvent and HookName decodable models"
```

---

## Task 4: `Session` model

**Files:**
- Create: `App/Models/Session.swift`

- [ ] **Step 1: Create the file**

```swift
// App/Models/Session.swift
import Foundation

struct Session: Identifiable, Equatable {
    let id: String                  // session_id from Claude Code
    var cwd: String
    var tty: String
    var pid: Int32
    var state: SessionState
    var enteredStateAt: Date        // when the current state was entered (drives elapsed time)
    var lastPromptPreview: String?  // sticks between UserPromptSubmit events

    /// Human-readable project name = last path component of cwd.
    var projectName: String {
        (cwd as NSString).lastPathComponent
    }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Models/Session.swift
git commit -m "Add Session model"
```

---

## Task 5: `Clock` protocol

**Files:**
- Create: `App/Core/Clock.swift`

We need an injectable clock so timer-driven behavior (elapsed time, 10s removal) is unit-testable.

- [ ] **Step 1: Create the file**

```swift
// App/Core/Clock.swift
import Foundation

protocol Clock {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

/// Test double: advances only when `advance(by:)` is called.
final class FakeClock: Clock {
    private var current: Date
    init(start: Date = Date(timeIntervalSince1970: 1_745_438_400)) {
        self.current = start
    }
    func now() -> Date { current }
    func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Core/Clock.swift
git commit -m "Add Clock protocol with SystemClock and FakeClock"
```

---

## Task 6: `StateMachine` pure function

The whole state transition table lives here. Pure, trivially testable.

**Files:**
- Create: `App/Core/StateMachine.swift`
- Create: `Tests/StateMachineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/StateMachineTests.swift
import XCTest
@testable import ClaudeMonitor

final class StateMachineTests: XCTestCase {
    func test_sessionStartCreatesWaiting() {
        XCTAssertEqual(StateMachine.transition(from: nil, for: .sessionStart), .waiting)
    }

    func test_userPromptSubmitGoesToWorking() {
        XCTAssertEqual(StateMachine.transition(from: .waiting, for: .userPromptSubmit), .working)
        XCTAssertEqual(StateMachine.transition(from: .needsYou, for: .userPromptSubmit), .working)
    }

    func test_stopGoesToWaiting() {
        XCTAssertEqual(StateMachine.transition(from: .working, for: .stop), .waiting)
    }

    func test_notificationGoesToNeedsYou() {
        XCTAssertEqual(StateMachine.transition(from: .working, for: .notification), .needsYou)
        XCTAssertEqual(StateMachine.transition(from: .waiting, for: .notification), .needsYou)
    }

    func test_sessionEndGoesToFinished() {
        for state in [SessionState.working, .waiting, .needsYou] {
            XCTAssertEqual(StateMachine.transition(from: state, for: .sessionEnd), .finished,
                           "from \(state) on sessionEnd should be finished")
        }
    }

    func test_finishedIsTerminal() {
        for hook in [HookName.userPromptSubmit, .stop, .notification, .sessionEnd] {
            XCTAssertEqual(StateMachine.transition(from: .finished, for: hook), .finished,
                           "finished should not transition on \(hook)")
        }
    }

    func test_unknownSessionWithNonStartEventSynthesizesStartThenApplies() {
        // A UserPromptSubmit from unknown session: create as waiting, then apply -> working.
        XCTAssertEqual(StateMachine.transition(from: nil, for: .userPromptSubmit), .working)
        XCTAssertEqual(StateMachine.transition(from: nil, for: .stop), .waiting)
        XCTAssertEqual(StateMachine.transition(from: nil, for: .notification), .needsYou)
        XCTAssertEqual(StateMachine.transition(from: nil, for: .sessionEnd), .finished)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make gen && make test`
Expected: FAIL — `StateMachine` undefined.

- [ ] **Step 3: Implement `StateMachine`**

```swift
// App/Core/StateMachine.swift
import Foundation

enum StateMachine {
    /// Compute the new state given the current state (nil if unknown session) and incoming hook.
    /// Unknown sessions are synthesized as if a SessionStart had fired first.
    static func transition(from current: SessionState?, for hook: HookName) -> SessionState {
        let base = current ?? applyFromNil()
        return apply(base, hook)
    }

    private static func applyFromNil() -> SessionState {
        .waiting  // synthesized SessionStart
    }

    private static func apply(_ state: SessionState, _ hook: HookName) -> SessionState {
        if state == .finished { return .finished }
        switch hook {
        case .sessionStart:     return .waiting
        case .userPromptSubmit: return .working
        case .stop:             return .waiting
        case .notification:     return .needsYou
        case .sessionEnd:       return .finished
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS (7 tests green).

- [ ] **Step 5: Commit**

```bash
git add App/Core/StateMachine.swift Tests/StateMachineTests.swift
git commit -m "Add pure StateMachine with full transition table"
```

---

## Task 7: `SessionStore` — apply events + ordered list

`SessionStore` owns sessions in insertion order. This task covers creation, update-on-event, and exposing an ordered list. Drag-reorder and auto-removal come later.

**Files:**
- Create: `App/Core/SessionStore.swift`
- Create: `Tests/SessionStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SessionStoreTests.swift
import XCTest
@testable import ClaudeMonitor

final class SessionStoreTests: XCTestCase {
    private func event(_ hook: HookName,
                       session: String = "s1",
                       tty: String = "/dev/ttys001",
                       pid: Int32 = 100,
                       cwd: String = "/Users/leo/Projects/foo",
                       ts: Int = 0,
                       promptPreview: String? = nil) -> HookEvent {
        HookEvent(hook: hook, sessionId: session, tty: tty, pid: pid, cwd: cwd,
                  ts: ts, promptPreview: promptPreview, toolName: nil)
    }

    func test_sessionStartCreatesSessionInWaiting() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        XCTAssertEqual(store.orderedSessions.count, 1)
        XCTAssertEqual(store.orderedSessions[0].id, "s1")
        XCTAssertEqual(store.orderedSessions[0].state, .waiting)
        XCTAssertEqual(store.orderedSessions[0].projectName, "foo")
    }

    func test_userPromptSubmitMovesToWorkingAndStoresPreview() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        store.apply(event(.userPromptSubmit, promptPreview: "Hello world"))

        XCTAssertEqual(store.orderedSessions[0].state, .working)
        XCTAssertEqual(store.orderedSessions[0].lastPromptPreview, "Hello world")
    }

    func test_promptPreviewSticksBetweenPrompts() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart))
        store.apply(event(.userPromptSubmit, promptPreview: "First"))
        store.apply(event(.stop)) // no preview on Stop
        XCTAssertEqual(store.orderedSessions[0].lastPromptPreview, "First")
    }

    func test_unknownSessionOnNonStartEventIsSynthesized() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.userPromptSubmit, promptPreview: "p"))
        XCTAssertEqual(store.orderedSessions.count, 1)
        XCTAssertEqual(store.orderedSessions[0].state, .working)
    }

    func test_multipleSessionsInsertInOrder() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart, session: "a", tty: "/dev/ttys001", cwd: "/p/alpha"))
        store.apply(event(.sessionStart, session: "b", tty: "/dev/ttys002", cwd: "/p/beta"))
        store.apply(event(.sessionStart, session: "c", tty: "/dev/ttys003", cwd: "/p/gamma"))
        XCTAssertEqual(store.orderedSessions.map(\.id), ["a", "b", "c"])
    }

    func test_stateChangeUpdatesEnteredStateAt() {
        let clock = FakeClock()
        let store = SessionStore(clock: clock)
        store.apply(event(.sessionStart))
        let t0 = store.orderedSessions[0].enteredStateAt
        clock.advance(by: 5)
        store.apply(event(.userPromptSubmit))
        let t1 = store.orderedSessions[0].enteredStateAt
        XCTAssertEqual(t1.timeIntervalSince(t0), 5, accuracy: 0.001)
    }

    func test_repeatedSameStateEventDoesNotResetTimer() {
        // Two Stop events in a row (shouldn't happen normally, but guard against it).
        let clock = FakeClock()
        let store = SessionStore(clock: clock)
        store.apply(event(.sessionStart))
        store.apply(event(.userPromptSubmit))
        store.apply(event(.stop))
        let t1 = store.orderedSessions[0].enteredStateAt
        clock.advance(by: 3)
        store.apply(event(.stop))
        XCTAssertEqual(store.orderedSessions[0].enteredStateAt, t1,
                       "enteredStateAt must only reset when the state actually changes")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make gen && make test`
Expected: FAIL — `SessionStore` undefined.

- [ ] **Step 3: Implement `SessionStore`**

```swift
// App/Core/SessionStore.swift
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var orderedSessions: [Session] = []

    private let clock: Clock

    init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    func apply(_ event: HookEvent) {
        let existing = orderedSessions.firstIndex { $0.id == event.sessionId }

        if let idx = existing {
            var session = orderedSessions[idx]
            let previousState = session.state
            let newState = StateMachine.transition(from: previousState, for: event.hook)

            if newState != previousState {
                session.state = newState
                session.enteredStateAt = clock.now()
            }
            // Always refresh identity fields; they may have been captured mid-lifecycle.
            session.tty = event.tty
            session.pid = event.pid
            session.cwd = event.cwd
            if let preview = event.promptPreview {
                session.lastPromptPreview = preview
            }
            orderedSessions[idx] = session
        } else {
            let newState = StateMachine.transition(from: nil, for: event.hook)
            let session = Session(
                id: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                pid: event.pid,
                state: newState,
                enteredStateAt: clock.now(),
                lastPromptPreview: event.promptPreview
            )
            orderedSessions.append(session)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS (7 tests green).

- [ ] **Step 5: Commit**

```bash
git add App/Core/SessionStore.swift Tests/SessionStoreTests.swift
git commit -m "Add SessionStore with insertion-order session list"
```

---

## Task 8: `SessionStore` — 10s auto-removal of finished sessions

**Files:**
- Modify: `App/Core/SessionStore.swift`
- Modify: `Tests/SessionStoreTests.swift`

- [ ] **Step 1: Add the failing test to `SessionStoreTests.swift`**

Append to the class:

```swift
    func test_finishedSessionIsRemovedAfter10Seconds() {
        let clock = FakeClock()
        let store = SessionStore(clock: clock, finishedRemovalDelay: 10)
        store.apply(event(.sessionStart))
        store.apply(event(.sessionEnd))

        XCTAssertEqual(store.orderedSessions.count, 1)
        XCTAssertEqual(store.orderedSessions[0].state, .finished)

        clock.advance(by: 9)
        store.tickRemovalTimer()
        XCTAssertEqual(store.orderedSessions.count, 1, "still within 10s window")

        clock.advance(by: 2)  // now 11s after finished
        store.tickRemovalTimer()
        XCTAssertEqual(store.orderedSessions.count, 0, "should be removed past 10s")
    }

    func test_finishedSessionCanBeRevivedBeforeRemoval() {
        // Edge case: an event arrives for a finished session before the removal timer fires.
        // Once finished is terminal per the state machine, we stay finished. But the timer
        // still runs from the original finished moment — document this.
        let clock = FakeClock()
        let store = SessionStore(clock: clock, finishedRemovalDelay: 10)
        store.apply(event(.sessionStart))
        store.apply(event(.sessionEnd))
        clock.advance(by: 3)
        store.apply(event(.userPromptSubmit))  // should be ignored (finished is terminal)
        XCTAssertEqual(store.orderedSessions[0].state, .finished)
        clock.advance(by: 8)
        store.tickRemovalTimer()
        XCTAssertEqual(store.orderedSessions.count, 0)
    }
```

- [ ] **Step 2: Run — expected to fail**

Run: `make test`
Expected: FAIL — compile error: `finishedRemovalDelay` initializer argument and `tickRemovalTimer` method don't exist.

- [ ] **Step 3: Extend `SessionStore`**

```swift
// App/Core/SessionStore.swift — replace entire file
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var orderedSessions: [Session] = []

    private let clock: Clock
    private let finishedRemovalDelay: TimeInterval

    init(clock: Clock = SystemClock(), finishedRemovalDelay: TimeInterval = 10) {
        self.clock = clock
        self.finishedRemovalDelay = finishedRemovalDelay
    }

    func apply(_ event: HookEvent) {
        let existing = orderedSessions.firstIndex { $0.id == event.sessionId }

        if let idx = existing {
            var session = orderedSessions[idx]
            let previousState = session.state
            let newState = StateMachine.transition(from: previousState, for: event.hook)

            if newState != previousState {
                session.state = newState
                session.enteredStateAt = clock.now()
            }
            session.tty = event.tty
            session.pid = event.pid
            session.cwd = event.cwd
            if let preview = event.promptPreview {
                session.lastPromptPreview = preview
            }
            orderedSessions[idx] = session
        } else {
            let newState = StateMachine.transition(from: nil, for: event.hook)
            let session = Session(
                id: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                pid: event.pid,
                state: newState,
                enteredStateAt: clock.now(),
                lastPromptPreview: event.promptPreview
            )
            orderedSessions.append(session)
        }
    }

    /// Called by the 1Hz tick timer (and by tests). Removes finished sessions
    /// whose `enteredStateAt + finishedRemovalDelay` has passed.
    func tickRemovalTimer() {
        let cutoff = clock.now().addingTimeInterval(-finishedRemovalDelay)
        orderedSessions.removeAll { $0.state == .finished && $0.enteredStateAt <= cutoff }
    }

    /// Mark a session finished immediately (used by the TerminalBridge stale-tab path
    /// and the StaleSessionSweeper). No-op if already finished or unknown.
    func markFinished(sessionId: String) {
        guard let idx = orderedSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard orderedSessions[idx].state != .finished else { return }
        orderedSessions[idx].state = .finished
        orderedSessions[idx].enteredStateAt = clock.now()
    }
}
```

- [ ] **Step 4: Run test to verify pass**

Run: `make test`
Expected: PASS (9 tests green).

- [ ] **Step 5: Commit**

```bash
git add App/Core/SessionStore.swift Tests/SessionStoreTests.swift
git commit -m "Auto-remove finished sessions after 10s via tick timer"
```

---

## Task 9: `SessionStore` — manual reorder + persistence key

**Files:**
- Modify: `App/Core/SessionStore.swift`
- Modify: `Tests/SessionStoreTests.swift`

- [ ] **Step 1: Add failing tests**

Append:

```swift
    func test_moveSessionReordersList() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart, session: "a"))
        store.apply(event(.sessionStart, session: "b"))
        store.apply(event(.sessionStart, session: "c"))

        store.move(sessionId: "c", toIndex: 0)
        XCTAssertEqual(store.orderedSessions.map(\.id), ["c", "a", "b"])

        store.move(sessionId: "a", toIndex: 2)
        XCTAssertEqual(store.orderedSessions.map(\.id), ["c", "b", "a"])
    }

    func test_moveClampsOutOfRange() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart, session: "a"))
        store.apply(event(.sessionStart, session: "b"))

        store.move(sessionId: "a", toIndex: 99)
        XCTAssertEqual(store.orderedSessions.map(\.id), ["b", "a"])

        store.move(sessionId: "a", toIndex: -5)
        XCTAssertEqual(store.orderedSessions.map(\.id), ["a", "b"])
    }

    func test_moveIgnoresUnknownId() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(.sessionStart, session: "a"))
        store.move(sessionId: "ghost", toIndex: 0)
        XCTAssertEqual(store.orderedSessions.map(\.id), ["a"])
    }
```

- [ ] **Step 2: Run test — expected to fail**

Run: `make test`
Expected: FAIL — `move(sessionId:toIndex:)` not defined.

- [ ] **Step 3: Add `move` to `SessionStore.swift`**

Append inside the `SessionStore` class:

```swift
    /// Reorder by id. Out-of-range indices are clamped. Unknown ids are ignored.
    func move(sessionId: String, toIndex requested: Int) {
        guard let from = orderedSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = orderedSessions.remove(at: from)
        let clamped = max(0, min(requested, orderedSessions.count))
        orderedSessions.insert(session, at: clamped)
    }
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add App/Core/SessionStore.swift Tests/SessionStoreTests.swift
git commit -m "Add manual reorder to SessionStore"
```

---

## Task 10: `PortFileWriter` — atomic port file

**Files:**
- Create: `App/Core/PortFileWriter.swift`
- Create: `Tests/PortFileWriterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PortFileWriterTests.swift
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
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `PortFileWriter` undefined.

- [ ] **Step 3: Implement**

```swift
// App/Core/PortFileWriter.swift
import Foundation

struct PortFileWriter {
    let destination: URL

    /// Writes `<port>\n` atomically by writing to a sibling `.tmp` and renaming.
    func write(port: UInt16) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = destination.appendingPathExtension("tmp")
        let data = "\(port)\n".data(using: .utf8)!
        try data.write(to: tmp, options: .atomic)

        // Posix rename is atomic on the same volume.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
    }

    /// Default location: `~/.claude-monitor/port`.
    static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/port")
    }
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add App/Core/PortFileWriter.swift Tests/PortFileWriterTests.swift
git commit -m "Add atomic PortFileWriter"
```

---

## Task 11: `EventServer` — HTTP receive over Network.framework

Local HTTP server on `127.0.0.1:<ephemeral>`. Accepts `POST /event` with a JSON `HookEvent` body, passes to a callback. Responds `204 No Content` on success, `400` on decode failure.

**Files:**
- Create: `App/Core/EventServer.swift`
- Create: `Tests/EventServerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/EventServerTests.swift
import XCTest
@testable import ClaudeMonitor

final class EventServerTests: XCTestCase {
    func test_serverReceivesPostedEvent() async throws {
        var received: [HookEvent] = []
        let expect = expectation(description: "event received")
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let body = """
        {"hook":"SessionStart","session_id":"abc","tty":"/dev/ttys001","pid":1,"cwd":"/","ts":1}
        """.data(using: .utf8)!

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 204)

        await fulfillment(of: [expect], timeout: 2)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sessionId, "abc")
    }

    func test_serverRejectsMalformedJsonWith400() async throws {
        let server = EventServer { _ in }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "not json".data(using: .utf8)!

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 400)
    }

    func test_serverRejectsNonPostWith405() async throws {
        let server = EventServer { _ in }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/event")!)

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 405)
    }
}
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `EventServer` undefined.

- [ ] **Step 3: Implement `EventServer`**

```swift
// App/Core/EventServer.swift
import Foundation
import Network

/// Minimal single-endpoint HTTP server for receiving hook events on localhost.
/// Accepts `POST /event` with a JSON `HookEvent` body.
final class EventServer {
    private let onEvent: (HookEvent) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.leolobato.claudemonitor.eventserver")

    /// Live port after `start()`. Nil before or on failure.
    private(set) var port: UInt16?

    init(onEvent: @escaping (HookEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue
                started.signal()
            } else if case .failed = state {
                started.signal()
            }
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 2)

        guard port != nil else {
            throw NSError(domain: "EventServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener failed to bind"])
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, accumulated: Data())
    }

    private func readRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data = data { buffer.append(data) }

            if let parsed = RawHTTPRequest.parse(buffer) {
                self.respond(to: parsed, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.readRequest(on: connection, accumulated: buffer)
        }
    }

    private func respond(to req: RawHTTPRequest, on connection: NWConnection) {
        defer { connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        }) }

        guard req.method == "POST", req.path == "/event" else {
            send(status: 405, message: "Method Not Allowed", connection: connection)
            return
        }
        guard let body = req.body else {
            send(status: 400, message: "Bad Request", connection: connection)
            return
        }
        do {
            let event = try JSONDecoder().decode(HookEvent.self, from: body)
            onEvent(event)
            send(status: 204, message: "No Content", connection: connection)
        } catch {
            send(status: 400, message: "Bad Request", connection: connection)
        }
    }

    private func send(status: Int, message: String, connection: NWConnection) {
        let line = "HTTP/1.1 \(status) \(message)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: line.data(using: .utf8), completion: .contentProcessed { _ in })
    }
}

/// Tiny HTTP/1.1 request parser — just enough for our single endpoint.
struct RawHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    static func parse(_ data: Data) -> RawHTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let available = data.count - bodyStart
        if contentLength > 0 && available < contentLength { return nil } // body incomplete

        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : nil

        return RawHTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS (all `EventServerTests` green). If tests hang on port binding in CI, that's a known flake — retry locally.

- [ ] **Step 5: Commit**

```bash
git add App/Core/EventServer.swift Tests/EventServerTests.swift
git commit -m "Add EventServer: loopback HTTP for hook event ingest"
```

---

## Task 12: Write `scripts/hook.sh`

The bash script installed to `~/.claude-monitor/hook.sh`. Reads hook JSON from stdin (Claude Code passes it on stdin), enriches with tty/pid/cwd/hook/ts, POSTs to `http://127.0.0.1:<port>/event`. Always exits 0.

**Files:**
- Create: `scripts/hook.sh`

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# claude-monitor hook — installed to ~/.claude-monitor/hook.sh
# Invoked by Claude Code for SessionStart, UserPromptSubmit, Stop, Notification, SessionEnd.
# Reads hook JSON on stdin, enriches, POSTs to the local Claude Monitor server.
# Always exits 0 so hook failures can never affect the Claude session.

set +e

HOOK_NAME="${1:-unknown}"
PORT_FILE="$HOME/.claude-monitor/port"
[ -f "$PORT_FILE" ] || exit 0
PORT="$(tr -d ' \n\r' < "$PORT_FILE")"
[ -n "$PORT" ] || exit 0

# Read stdin payload from Claude Code. May be empty (no JSON guaranteed).
STDIN_JSON="$(cat 2>/dev/null)"
[ -n "$STDIN_JSON" ] || STDIN_JSON="{}"

# Context capture
TTY_VAL="$(tty 2>/dev/null)"
[ -n "$TTY_VAL" ] && [ "$TTY_VAL" != "not a tty" ] || TTY_VAL=""
PID_VAL="$PPID"   # the claude process that invoked us
CWD_VAL="$(pwd)"
TS_VAL="$(date +%s)"

# Build JSON — use python for safe escaping if available, otherwise a minimal fallback.
if command -v python3 >/dev/null 2>&1; then
  PAYLOAD="$(PYTHONIOENCODING=utf-8 python3 - <<PY
import json, os, sys
try:
    src = json.loads(os.environ.get("STDIN_JSON") or "{}")
except Exception:
    src = {}
out = {
    "hook":            os.environ.get("HOOK_NAME", "unknown"),
    "session_id":      src.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", ""),
    "tty":             os.environ.get("TTY_VAL", ""),
    "pid":             int(os.environ.get("PID_VAL", "0")),
    "cwd":             os.environ.get("CWD_VAL", ""),
    "ts":              int(os.environ.get("TS_VAL", "0")),
}
preview = src.get("prompt") or src.get("user_prompt")
if isinstance(preview, str):
    out["prompt_preview"] = preview[:120]
tool = src.get("tool_name")
if isinstance(tool, str):
    out["tool_name"] = tool
print(json.dumps(out))
PY
)"
else
  # Minimal fallback: no prompt_preview, best-effort.
  SID="$(echo "$STDIN_JSON" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  PAYLOAD=$(cat <<EOF
{"hook":"$HOOK_NAME","session_id":"$SID","tty":"$TTY_VAL","pid":$PID_VAL,"cwd":"$CWD_VAL","ts":$TS_VAL}
EOF
)
fi

curl -s -m 2 -X POST -H "Content-Type: application/json" \
  --data-binary "$PAYLOAD" \
  "http://127.0.0.1:${PORT}/event" >/dev/null 2>&1

exit 0
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/hook.sh
```

- [ ] **Step 3: Smoke-test it by hand**

Run a trivial one-liner that pipes a fake event and checks the script doesn't crash:

```bash
HOOK_NAME=SessionStart scripts/hook.sh SessionStart < /dev/null; echo "exit=$?"
```

Expected: prints `exit=0` (even without a server running, because `curl` fails silently and we always exit 0).

- [ ] **Step 4: Commit**

```bash
git add scripts/hook.sh
git commit -m "Add hook.sh: enriches Claude hook payload and POSTs to local server"
```

---

## Task 13: Integration test — `hook.sh` → `EventServer`

**Files:**
- Create: `Tests/HookScriptTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/HookScriptTests.swift
import XCTest
@testable import ClaudeMonitor

final class HookScriptTests: XCTestCase {
    func test_hookScriptPostsEnrichedPayload() async throws {
        // Locate the script inside the app bundle (it's added as a resource in project.yml).
        let bundle = Bundle(for: Self.self)
        // During tests, the app bundle is a sibling — walk up.
        let scriptURL = try XCTUnwrap(findHookScript(searchingFrom: bundle.bundleURL),
                                      "could not find hook.sh under test bundle")

        var received: [HookEvent] = []
        let expect = expectation(description: "event")
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        // Write the port file where hook.sh expects it — use a temp dir via $HOME override.
        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        let portFile = tmpHome.appendingPathComponent(".claude-monitor/port")
        try "\(server.port!)\n".write(to: portFile, atomically: true, encoding: .utf8)

        // Run hook.sh with HOME pointing at our temp dir.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, "UserPromptSubmit"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env

        let inputPipe = Pipe()
        proc.standardInput = inputPipe
        try proc.run()
        inputPipe.fileHandleForWriting.write(#"""
        {"session_id":"sess-1","prompt":"Hello world from the test"}
        """#.data(using: .utf8)!)
        try inputPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        await fulfillment(of: [expect], timeout: 3)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sessionId, "sess-1")
        XCTAssertEqual(received[0].hook, .userPromptSubmit)
        XCTAssertEqual(received[0].promptPreview, "Hello world from the test")
    }

    private func findHookScript(searchingFrom start: URL) -> URL? {
        // Check bundle resources first.
        if let inBundle = Bundle(for: Self.self).url(forResource: "hook", withExtension: "sh") {
            return inBundle
        }
        // Fallback: walk up to the repo root and look under scripts/.
        var cursor = start
        for _ in 0..<8 {
            let candidate = cursor.appendingPathComponent("scripts/hook.sh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }
}
```

- [ ] **Step 2: Make the script available to the test bundle**

The script is listed under the app target's `resources`. Add it to the test target too — edit `project.yml` to put `scripts/hook.sh` under the test target's `resources`:

```yaml
  ClaudeMonitorTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
    resources:
      - path: scripts/hook.sh
    dependencies:
      - target: ClaudeMonitor
```

- [ ] **Step 3: Run — expected to pass**

Run: `make gen && make test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/HookScriptTests.swift project.yml
git commit -m "Add end-to-end hook.sh to EventServer integration test"
```

---

## Task 14: `ManagedConfigDirectory` model

**Files:**
- Create: `App/Models/ManagedConfigDirectory.swift`

- [ ] **Step 1: Create the file**

```swift
// App/Models/ManagedConfigDirectory.swift
import Foundation

enum HookInstallStatus: String, Codable, Equatable {
    case notInstalled
    case installed
    case outdated        // an older hook schema version is installed
    case modifiedExternally  // the managed block was hand-edited
}

struct ManagedConfigDirectory: Identifiable, Codable, Equatable {
    /// The path is the identity.
    var id: String { url.path }
    var url: URL
    var status: HookInstallStatus
    var installedVersion: Int   // 0 = none
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Models/ManagedConfigDirectory.swift
git commit -m "Add ManagedConfigDirectory and HookInstallStatus"
```

---

## Task 15: `ConfigDirectoryDiscovery`

Scans `$HOME` for `.claude` and `.claudewho-*` directories that contain a `settings.json`.

**Files:**
- Create: `App/Core/ConfigDirectoryDiscovery.swift`
- Create: `Tests/ConfigDirectoryDiscoveryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ConfigDirectoryDiscoveryTests.swift
import XCTest
@testable import ClaudeMonitor

final class ConfigDirectoryDiscoveryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeDir(_ name: String, withSettings: Bool) throws -> URL {
        let url = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if withSettings {
            try "{}".write(to: url.appendingPathComponent("settings.json"),
                           atomically: true, encoding: .utf8)
        }
        return url
    }

    func test_findsClaudeAndClaudewhoDirectories() throws {
        _ = try makeDir(".claude", withSettings: true)
        _ = try makeDir(".claudewho-work", withSettings: true)
        _ = try makeDir(".claudewho-personal", withSettings: true)
        _ = try makeDir(".unrelated", withSettings: true)        // not matched
        _ = try makeDir(".claudewho-broken", withSettings: false) // no settings -> skipped

        let found = ConfigDirectoryDiscovery.scan(home: home).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, [".claude", ".claudewho-personal", ".claudewho-work"])
    }

    func test_returnsEmptyWhenNoCandidates() throws {
        let found = ConfigDirectoryDiscovery.scan(home: home)
        XCTAssertEqual(found, [])
    }
}
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `ConfigDirectoryDiscovery` undefined.

- [ ] **Step 3: Implement**

```swift
// App/Core/ConfigDirectoryDiscovery.swift
import Foundation

enum ConfigDirectoryDiscovery {
    /// Returns all directories under `home` whose name is `.claude` or `.claudewho-*`
    /// AND which contain a `settings.json`.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }

        return entries
            .filter { $0 == ".claude" || $0.hasPrefix(".claudewho-") }
            .map { home.appendingPathComponent($0) }
            .filter { dir in
                var isDir: ObjCBool = false
                let settings = dir.appendingPathComponent("settings.json").path
                return fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
                    && fm.fileExists(atPath: settings)
            }
            .sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add App/Core/ConfigDirectoryDiscovery.swift Tests/ConfigDirectoryDiscoveryTests.swift
git commit -m "Add ConfigDirectoryDiscovery: find ~/.claude and ~/.claudewho-* dirs"
```

---

## Task 16: `HookInstaller` — read/write managed block in settings.json

The installer must preserve all non-managed hooks. The managed block is identified by `_managedBy: "claude-monitor"`. Hook version lives in the same block as `_version: 1`.

The target schema we write (example for a single config directory's `settings.json`):

```json
{
  "hooks": {
    "SessionStart":      [{ "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh SessionStart" }],
    "UserPromptSubmit":  [{ "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh UserPromptSubmit" }],
    "Stop":              [{ "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh Stop" }],
    "Notification":      [{ "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh Notification" }],
    "SessionEnd":        [{ "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh SessionEnd" }]
  }
}
```

Existing hooks in the file are preserved. On re-install we replace only the entries with the `_managedBy: "claude-monitor"` marker.

**Files:**
- Create: `App/Core/HookInstaller.swift`
- Create: `Tests/HookInstallerTests.swift`
- Create: `Tests/Fixtures/settings-empty.json`
- Create: `Tests/Fixtures/settings-with-other-hooks.json`
- Create: `Tests/Fixtures/settings-with-managed-v1.json`

- [ ] **Step 1: Create the fixture files**

```json
// Tests/Fixtures/settings-empty.json
{}
```

```json
// Tests/Fixtures/settings-with-other-hooks.json
{
  "hooks": {
    "SessionStart": [
      { "command": "echo user-owned-hook" }
    ],
    "Stop": [
      { "command": "custom-thing" }
    ]
  },
  "other_key": "preserve me"
}
```

```json
// Tests/Fixtures/settings-with-managed-v1.json
{
  "hooks": {
    "SessionStart": [
      { "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh SessionStart" }
    ],
    "UserPromptSubmit": [
      { "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh UserPromptSubmit" }
    ],
    "Stop": [
      { "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh Stop" }
    ],
    "Notification": [
      { "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh Notification" }
    ],
    "SessionEnd": [
      { "_managedBy": "claude-monitor", "_version": 1, "command": "$HOME/.claude-monitor/hook.sh SessionEnd" }
    ]
  }
}
```

Add fixtures to the test target's resources — edit `project.yml`:

```yaml
  ClaudeMonitorTests:
    ...
    resources:
      - path: scripts/hook.sh
      - path: Tests/Fixtures
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/HookInstallerTests.swift
import XCTest
@testable import ClaudeMonitor

final class HookInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    private func writeSettings(_ fixture: String) throws -> URL {
        let data = try loadFixture(fixture)
        let url = dir.appendingPathComponent("settings.json")
        try data.write(to: url)
        return url
    }

    func test_inspectReportsNotInstalledForEmptySettings() throws {
        _ = try writeSettings("settings-empty")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .notInstalled)
        XCTAssertEqual(status.installedVersion, 0)
    }

    func test_inspectReportsInstalledForCurrentVersionFixture() throws {
        _ = try writeSettings("settings-with-managed-v1")
        let status = try HookInstaller.inspect(configDir: dir)
        XCTAssertEqual(status.status, .installed)
        XCTAssertEqual(status.installedVersion, HookInstaller.currentVersion)
    }

    func test_installAddsAllFiveHooksToEmptySettings() throws {
        let path = try writeSettings("settings-empty")
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"])
        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(start.first?["_managedBy"] as? String, "claude-monitor")
        XCTAssertEqual(start.first?["_version"] as? Int, HookInstaller.currentVersion)
    }

    func test_installPreservesUserOwnedHooksAndOtherKeys() throws {
        let path = try writeSettings("settings-with-other-hooks")
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        XCTAssertEqual(after["other_key"] as? String, "preserve me")

        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        // One user-owned, one managed — both present.
        XCTAssertEqual(start.count, 2)
        XCTAssertTrue(start.contains { $0["command"] as? String == "echo user-owned-hook" })
        XCTAssertTrue(start.contains { $0["_managedBy"] as? String == "claude-monitor" })

        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertTrue(stop.contains { $0["command"] as? String == "custom-thing" })
    }

    func test_installIsIdempotent() throws {
        _ = try writeSettings("settings-empty")
        try HookInstaller.install(configDir: dir)
        try HookInstaller.install(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as! [String: Any]
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        for key in ["SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"] {
            let entries = hooks[key] as! [[String: Any]]
            XCTAssertEqual(entries.count, 1, "\(key) should have exactly one managed entry")
        }
    }

    func test_uninstallRemovesManagedBlocksOnly() throws {
        let path = try writeSettings("settings-with-other-hooks")
        try HookInstaller.install(configDir: dir)
        try HookInstaller.uninstall(configDir: dir)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])

        let start = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start.first?["command"] as? String, "echo user-owned-hook")
        XCTAssertNil(hooks["UserPromptSubmit"])   // was only managed — hook key removed
    }
}
```

- [ ] **Step 3: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `HookInstaller` undefined.

- [ ] **Step 4: Implement `HookInstaller`**

```swift
// App/Core/HookInstaller.swift
import Foundation

enum HookInstaller {
    static let currentVersion = 1
    private static let managedKey = "_managedBy"
    private static let managedValue = "claude-monitor"
    private static let versionKey = "_version"
    private static let allHooks = ["SessionStart","UserPromptSubmit","Stop","Notification","SessionEnd"]

    struct Status: Equatable {
        let status: HookInstallStatus
        let installedVersion: Int
    }

    // MARK: Inspect

    static func inspect(configDir: URL) throws -> Status {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        let json = try loadJson(settingsURL)
        let hooks = (json["hooks"] as? [String: Any]) ?? [:]

        var versions: [Int] = []
        var anyMissing = false
        var anyModified = false

        for hook in allHooks {
            let entries = (hooks[hook] as? [[String: Any]]) ?? []
            let managed = entries.filter { $0[managedKey] as? String == managedValue }
            if managed.isEmpty { anyMissing = true; continue }
            let expectedCmd = expectedCommand(for: hook)
            for entry in managed {
                if let v = entry[versionKey] as? Int { versions.append(v) }
                if (entry["command"] as? String) != expectedCmd { anyModified = true }
            }
        }

        if anyMissing && versions.isEmpty {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        if anyMissing || anyModified {
            return Status(status: .modifiedExternally, installedVersion: versions.max() ?? 0)
        }
        let maxV = versions.max() ?? 0
        if maxV < currentVersion {
            return Status(status: .outdated, installedVersion: maxV)
        }
        return Status(status: .installed, installedVersion: maxV)
    }

    // MARK: Install

    static func install(configDir: URL) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        var json = (try? loadJson(settingsURL)) ?? [:]
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]

        for hook in allHooks {
            var entries = (hooks[hook] as? [[String: Any]]) ?? []
            entries.removeAll { $0[managedKey] as? String == managedValue }
            let managed: [String: Any] = [
                managedKey: managedValue,
                versionKey: currentVersion,
                "command": expectedCommand(for: hook),
            ]
            entries.append(managed)
            hooks[hook] = entries
        }
        json["hooks"] = hooks
        try saveJson(json, to: settingsURL)
    }

    // MARK: Uninstall

    static func uninstall(configDir: URL) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var json = try loadJson(settingsURL)
        guard var hooks = json["hooks"] as? [String: Any] else { return }

        for (key, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { $0[managedKey] as? String == managedValue }
            if entries.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = entries
            }
        }
        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
        try saveJson(json, to: settingsURL)
    }

    // MARK: Helpers

    private static func expectedCommand(for hook: String) -> String {
        "$HOME/.claude-monitor/hook.sh \(hook)"
    }

    private static func loadJson(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    private static func saveJson(_ json: [String: Any], to url: URL) throws {
        // Write with sorted keys + pretty printing for stable diffs.
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
```

- [ ] **Step 5: Verify**

Run: `make gen && make test`
Expected: PASS. If fixture loading fails, ensure `project.yml` lists `Tests/Fixtures` as resources (step 1).

- [ ] **Step 6: Commit**

```bash
git add App/Core/HookInstaller.swift Tests/HookInstallerTests.swift Tests/Fixtures project.yml
git commit -m "Add HookInstaller: merge-preserving install/uninstall of managed block"
```

---

## Task 17: `HookScriptDeployer` — copy bundled hook.sh to `~/.claude-monitor/hook.sh`

The installer in Task 16 writes settings that *reference* `$HOME/.claude-monitor/hook.sh`. This task actually puts the file there.

**Files:**
- Create: `App/Core/HookScriptDeployer.swift`
- Create: `Tests/HookScriptDeployerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/HookScriptDeployerTests.swift
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
        try HookScriptDeployer.deploy(home: tmpHome)
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

        try HookScriptDeployer.deploy(home: tmpHome)
        let body = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("#!/bin/bash"))
    }
}
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `HookScriptDeployer` undefined.

- [ ] **Step 3: Implement**

```swift
// App/Core/HookScriptDeployer.swift
import Foundation

enum HookScriptDeployer {
    enum DeployError: Error { case bundleScriptMissing }

    /// Copy the bundled hook.sh into `<home>/.claude-monitor/hook.sh`, overwriting any existing file,
    /// and mark it executable.
    static func deploy(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let src = Bundle.main.url(forResource: "hook", withExtension: "sh")
                    ?? Bundle(for: Sentinel.self).url(forResource: "hook", withExtension: "sh")
        else { throw DeployError.bundleScriptMissing }

        let destDir = home.appendingPathComponent(".claude-monitor")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("hook.sh")

        let data = try Data(contentsOf: src)
        try data.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    /// Private marker class to locate the resource bundle in tests.
    private final class Sentinel {}
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add App/Core/HookScriptDeployer.swift Tests/HookScriptDeployerTests.swift
git commit -m "Add HookScriptDeployer: copy bundled hook.sh into ~/.claude-monitor/"
```

---

## Task 18: `TerminalBridgeProtocol` + `FakeTerminalBridge`

Protocol for focusing a Terminal.app tab by tty. Real impl comes in Task 19.

**Files:**
- Create: `App/Core/TerminalBridgeProtocol.swift`

- [ ] **Step 1: Create the file**

```swift
// App/Core/TerminalBridgeProtocol.swift
import Foundation

enum FocusResult: Equatable {
    case focused
    case noSuchTab
    case terminalNotRunning
    case scriptError(String)
}

protocol TerminalBridgeProtocol {
    /// Focus the Terminal.app tab whose `tty` matches the argument. Also verify that
    /// a process with `expectedPid` is listed under that tab (TTY-reuse guard).
    func focus(tty: String, expectedPid: Int32) -> FocusResult
}

/// Test double. Behavior is scripted via a closure.
final class FakeTerminalBridge: TerminalBridgeProtocol {
    var handler: (String, Int32) -> FocusResult = { _, _ in .focused }
    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        handler(tty, expectedPid)
    }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Core/TerminalBridgeProtocol.swift
git commit -m "Add TerminalBridgeProtocol with fake"
```

---

## Task 19: `TerminalBridge` — real AppleScript implementation

**Files:**
- Create: `App/Core/TerminalBridge.swift`

The real `focus` builds an `NSAppleScript` with the tty and expected pid substituted, runs it, and maps the result.

- [ ] **Step 1: Create the file**

```swift
// App/Core/TerminalBridge.swift
import Foundation
import Darwin

#if canImport(AppKit)
import AppKit
#endif

final class TerminalBridge: TerminalBridgeProtocol {
    func focus(tty: String, expectedPid: Int32) -> FocusResult {
        // 1. Is Terminal even running?
        let runningApps = NSWorkspace.shared.runningApplications
        guard runningApps.contains(where: { $0.bundleIdentifier == "com.apple.Terminal" }) else {
            return .terminalNotRunning
        }

        // 2. Swift-side pid liveness check (part of the TTY-reuse guard).
        //    If the recorded `claude` process is gone, the tty is stale — skip AppleScript.
        if kill(expectedPid, 0) != 0 {
            return .noSuchTab
        }

        // 3. Run AppleScript. Result strings: "focused" or "no-such-tab".
        //    Terminal.app's `processes of t` returns a list of process *names* (strings),
        //    not descriptors — so the second half of the TTY-reuse guard checks that
        //    "claude" appears in the tab's process list.
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
        case "focused":      return .focused
        case "no-such-tab":  return .noSuchTab
        default:
            return .scriptError(result)
        }
    }

    private static func buildScript(tty: String) -> String {
        // Escape double quotes in tty (unlikely, but be safe).
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

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Core/TerminalBridge.swift
git commit -m "Add TerminalBridge: focus Terminal.app tab by tty with pid guard"
```

> Note on the TTY-reuse guard (spec §5.4): the spec called for *both* a Swift-side pid check *and* matching the pid inside Terminal.app's `processes of t` list. Terminal.app's AppleScript `processes` property returns a list of strings (process names), not descriptors — so exact pid matching isn't possible via AppleScript. v1 relies on the Swift-side `kill(expectedPid, 0)` check alone, which catches the common case (Terminal tab force-closed → old claude pid is dead). The residual risk (tty recycled *while* the claude pid coincidentally stays alive elsewhere) is vanishingly rare and acceptable for v1.

---

## Task 20: `TerminalBridge` integration test (opt-in)

This test opens a real Terminal.app window and is gated by an env var so CI doesn't flail.

**Files:**
- Create: `IntegrationTests/TerminalBridgeIntegrationTests.swift`

- [ ] **Step 1: Add the test**

```swift
// IntegrationTests/TerminalBridgeIntegrationTests.swift
import XCTest
@testable import ClaudeMonitor

final class TerminalBridgeIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["RUN_TERMINAL_INTEGRATION"] != "1" {
            throw XCTSkip("Set RUN_TERMINAL_INTEGRATION=1 to enable. Requires Automation permission.")
        }
    }

    func test_focusTabByTTY() throws {
        // Open a Terminal tab running a long-lived command; capture its tty.
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

        // Open a second tab so the first isn't frontmost.
        let openSecond = #"tell application "Terminal" to do script "echo other""#
        _ = NSAppleScript(source: openSecond)?.executeAndReturnError(nil)

        // Exercise the bridge. Use the test-runner's own pid as `expectedPid` —
        // it's definitely alive, so the Swift-side kill(pid,0) guard passes.
        let bridge = TerminalBridge()
        let result = bridge.focus(tty: tty, expectedPid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(result, .focused)

        // Cleanup: close the tab by tty.
        let cleanup = """
        tell application "Terminal"
            close (every window whose tty of selected tab is "\(tty)")
        end tell
        """
        _ = NSAppleScript(source: cleanup)?.executeAndReturnError(nil)
    }

    func test_focusReturnsNoSuchTabWhenPidIsDead() {
        // Any pid that can't possibly be alive.
        let result = TerminalBridge().focus(tty: "/dev/ttys999", expectedPid: 2_147_483_000)
        // Either Terminal-not-running or noSuchTab is acceptable; both are "don't focus".
        XCTAssertTrue(result == .noSuchTab || result == .terminalNotRunning,
                      "expected noSuchTab or terminalNotRunning, got \(result)")
    }
}
```

- [ ] **Step 2: Run locally (optional)**

```bash
RUN_TERMINAL_INTEGRATION=1 make test-integration
```

Expected: PASS. First run will prompt for Automation permission — grant it. If the pid-match path fails, adjust `buildScript` in Task 19 per the note there.

- [ ] **Step 3: Commit**

```bash
git add IntegrationTests/TerminalBridgeIntegrationTests.swift
git commit -m "Add opt-in Terminal.app integration test for TerminalBridge"
```

---

## Task 21: `VerticalFirstGridLayout` — custom SwiftUI Layout

**Files:**
- Create: `App/UI/VerticalFirstGridLayout.swift`
- Create: `Tests/VerticalFirstGridLayoutTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/VerticalFirstGridLayoutTests.swift
import XCTest
@testable import ClaudeMonitor

final class VerticalFirstGridLayoutTests: XCTestCase {
    func test_singleColumnWhenAllTilesFitVertically() {
        // height=400 - padding(16) = 384; each tile slot is 80+8 = 88; floor(384/88) = 4 tiles per column
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let positions = layout.positions(tileCount: 4, containerHeight: 400)
        XCTAssertEqual(positions.map(\.x), [8, 8, 8, 8])
        XCTAssertEqual(positions.map(\.y), [8, 96, 184, 272])
    }

    func test_wrapsToSecondColumnWhenFirstIsFull() {
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let positions = layout.positions(tileCount: 5, containerHeight: 400)
        // 4 tiles in column 0 at x=8, 1 tile in column 1 at x = 8 + 160 + 8 = 176
        XCTAssertEqual(positions[0].x, 8)
        XCTAssertEqual(positions[3].x, 8)
        XCTAssertEqual(positions[4].x, 176)
        XCTAssertEqual(positions[4].y, 8)
    }

    func test_rejectsZeroColumnHeightGracefullyBySingleColumn() {
        // Container too short for even one tile — fall back to one-per-column.
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let positions = layout.positions(tileCount: 3, containerHeight: 40)
        XCTAssertEqual(positions.count, 3)
        // Each tile gets its own column.
        XCTAssertEqual(positions.map(\.x), [8, 176, 344])
    }

    func test_totalSizeReportsRequiredWidth() {
        let layout = VerticalFirstGridLayout(tileSize: CGSize(width: 160, height: 80), gutter: 8, padding: 8)
        let size = layout.requiredSize(tileCount: 5, containerHeight: 400)
        XCTAssertEqual(size.width, 8 + 160 + 8 + 160 + 8, "2 columns of 160 plus padding/gutter")
    }
}
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `VerticalFirstGridLayout` undefined.

- [ ] **Step 3: Implement**

```swift
// App/UI/VerticalFirstGridLayout.swift
import SwiftUI

/// Vertical-first flow layout. Fills column 0 top-to-bottom, then column 1, etc.
/// Implements both a `positions(tileCount:containerHeight:)` helper for unit testing
/// and the SwiftUI `Layout` protocol for live rendering.
struct VerticalFirstGridLayout: Layout {
    let tileSize: CGSize
    let gutter: CGFloat
    let padding: CGFloat

    init(tileSize: CGSize = CGSize(width: 160, height: 80),
         gutter: CGFloat = 8,
         padding: CGFloat = 8) {
        self.tileSize = tileSize
        self.gutter = gutter
        self.padding = padding
    }

    // MARK: Pure helpers (unit-testable)

    func tilesPerColumn(containerHeight: CGFloat) -> Int {
        let usable = containerHeight - 2 * padding
        let slot = tileSize.height + gutter
        let fit = Int(floor((usable + gutter) / slot))  // +gutter because last tile has no trailing gutter
        return max(1, fit)
    }

    func positions(tileCount: Int, containerHeight: CGFloat) -> [CGPoint] {
        let perCol = tilesPerColumn(containerHeight: containerHeight)
        return (0..<tileCount).map { i in
            let col = i / perCol
            let row = i % perCol
            let x = padding + CGFloat(col) * (tileSize.width + gutter)
            let y = padding + CGFloat(row) * (tileSize.height + gutter)
            return CGPoint(x: x, y: y)
        }
    }

    func requiredSize(tileCount: Int, containerHeight: CGFloat) -> CGSize {
        let perCol = tilesPerColumn(containerHeight: containerHeight)
        let cols = Int(ceil(Double(tileCount) / Double(perCol)))
        let width = 2 * padding + CGFloat(cols) * tileSize.width + CGFloat(max(0, cols - 1)) * gutter
        let height = containerHeight
        return CGSize(width: width, height: height)
    }

    // MARK: SwiftUI Layout conformance

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerHeight = proposal.height ?? 600
        return requiredSize(tileCount: subviews.count, containerHeight: containerHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = positions(tileCount: subviews.count, containerHeight: bounds.height)
        for (i, subview) in subviews.enumerated() {
            let p = positions[i]
            subview.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y),
                          proposal: ProposedViewSize(tileSize))
        }
    }
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add App/UI/VerticalFirstGridLayout.swift Tests/VerticalFirstGridLayoutTests.swift
git commit -m "Add VerticalFirstGridLayout: columns that fill top-to-bottom"
```

---

## Task 22: `TileView` — the 160×80 tile

**Files:**
- Create: `App/UI/TileView.swift`

No test — view rendering is covered by the smoke test later.

- [ ] **Step 1: Create the file**

```swift
// App/UI/TileView.swift
import SwiftUI

struct TileView: View {
    let session: Session
    let now: Date   // passed in so elapsed time ticks from a shared clock

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(session.state.tileColor)
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 8, height: 8)
                }
                Text("\(session.state.displayLabel) · \(elapsed)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .opacity(0.95)
                if let preview = session.lastPromptPreview {
                    Text(preview)
                        .font(.system(size: 9))
                        .lineLimit(3)
                        .opacity(0.85)
                        .padding(.top, 2)
                }
            }
            .padding(8)
            .foregroundColor(.white)
        }
        .frame(width: 160, height: 80)
        .contentShape(Rectangle())
    }

    private var elapsed: String {
        let secs = max(0, Int(now.timeIntervalSince(session.enteredStateAt)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/UI/TileView.swift
git commit -m "Add TileView: 160x80 tile with state color, elapsed time, prompt snippet"
```

---

## Task 23: `FlashModifier` — 2-pulse opacity animation

**Files:**
- Create: `App/UI/FlashModifier.swift`

The modifier is triggered by a `flashId: UUID` that changes each time the parent wants a flash. SwiftUI sees the id change and re-runs the animation.

- [ ] **Step 1: Create the file**

```swift
// App/UI/FlashModifier.swift
import SwiftUI

struct FlashModifier: ViewModifier {
    let flashId: UUID?
    @State private var phase: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .opacity(phase)
            .onChange(of: flashId) { _, _ in
                guard flashId != nil else { return }
                Task {
                    let steps: [(CGFloat, UInt64)] = [
                        (0.7, 150_000_000),
                        (1.0, 150_000_000),
                        (0.7, 150_000_000),
                        (1.0, 150_000_000),
                    ]
                    for (target, delay) in steps {
                        withAnimation(.easeInOut(duration: 0.15)) { phase = target }
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    phase = 1
                }
            }
    }
}

extension View {
    func flash(id: UUID?) -> some View { modifier(FlashModifier(flashId: id)) }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/UI/FlashModifier.swift
git commit -m "Add FlashModifier: 2-pulse opacity animation on id change"
```

---

## Task 24: `FlashCoordinator` — decides which tiles should flash

Pure logic unit: given the previous session list and the current session list, produce a `sessionId → flashId` map for tiles that just transitioned into `waiting` or `needsYou`, or `needsYou → working`.

**Files:**
- Create: `App/Core/FlashCoordinator.swift`
- Create: `Tests/FlashCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlashCoordinatorTests.swift
import XCTest
@testable import ClaudeMonitor

final class FlashCoordinatorTests: XCTestCase {
    private func session(_ id: String, _ state: SessionState) -> Session {
        Session(id: id, cwd: "/p/\(id)", tty: "/dev/ttys001", pid: 1,
                state: state, enteredStateAt: Date(timeIntervalSince1970: 0), lastPromptPreview: nil)
    }

    func test_transitionIntoWaitingProducesFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working)])
        let flashes = c.update(sessions: [session("a", .waiting)])
        XCTAssertNotNil(flashes["a"])
    }

    func test_transitionIntoNeedsYouProducesFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working)])
        let flashes = c.update(sessions: [session("a", .needsYou)])
        XCTAssertNotNil(flashes["a"])
    }

    func test_resolvingFromNeedsYouToWorkingProducesFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .needsYou)])
        let flashes = c.update(sessions: [session("a", .working)])
        XCTAssertNotNil(flashes["a"])
    }

    func test_sessionStartDoesNotFlash() {
        var c = FlashCoordinator()
        let flashes = c.update(sessions: [session("a", .waiting)])  // new session in waiting
        XCTAssertNil(flashes["a"])
    }

    func test_transitionIntoFinishedDoesNotFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working)])
        let flashes = c.update(sessions: [session("a", .finished)])
        XCTAssertNil(flashes["a"])
    }

    func test_sameStateNoFlash() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .waiting)])
        let flashes = c.update(sessions: [session("a", .waiting)])
        XCTAssertNil(flashes["a"])
    }

    func test_flashIdsAccumulateAcrossUpdates() {
        var c = FlashCoordinator()
        _ = c.update(sessions: [session("a", .working), session("b", .working)])
        let step2 = c.update(sessions: [session("a", .waiting), session("b", .working)])
        XCTAssertNotNil(step2["a"])
        let step3 = c.update(sessions: [session("a", .waiting), session("b", .needsYou)])
        XCTAssertEqual(step3["a"], step2["a"], "unchanged session keeps its last flash id")
        XCTAssertNotNil(step3["b"])
    }
}
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `FlashCoordinator` undefined.

- [ ] **Step 3: Implement**

```swift
// App/Core/FlashCoordinator.swift
import Foundation

struct FlashCoordinator {
    private var previousStates: [String: SessionState] = [:]
    private var flashIds: [String: UUID] = [:]

    /// Returns the current `sessionId → flashId` map. IDs only change on qualifying transitions.
    mutating func update(sessions: [Session]) -> [String: UUID] {
        for s in sessions {
            defer { previousStates[s.id] = s.state }
            guard let prev = previousStates[s.id] else { continue }  // first sighting = no flash
            if shouldFlash(from: prev, to: s.state) {
                flashIds[s.id] = UUID()
            }
        }
        // Drop entries for sessions that went away.
        let live = Set(sessions.map(\.id))
        previousStates = previousStates.filter { live.contains($0.key) }
        flashIds = flashIds.filter { live.contains($0.key) }
        return flashIds
    }

    private func shouldFlash(from old: SessionState, to new: SessionState) -> Bool {
        if old == new { return false }
        if new == .waiting  { return true }
        if new == .needsYou { return true }
        if old == .needsYou && new == .working { return true }
        return false
    }
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add App/Core/FlashCoordinator.swift Tests/FlashCoordinatorTests.swift
git commit -m "Add FlashCoordinator: compute tile flash IDs on state transitions"
```

---

## Task 25: `DashboardView` — compose grid + tiles + flash + click

**Files:**
- Create: `App/UI/DashboardView.swift`

- [ ] **Step 1: Create the file**

```swift
// App/UI/DashboardView.swift
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: SessionStore
    let onClickSession: (Session) -> Void

    @State private var flashIds: [String: UUID] = [:]
    @State private var flashCoordinator = FlashCoordinator()
    @State private var now: Date = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if store.orderedSessions.isEmpty {
                emptyState
            } else {
                VerticalFirstGridLayout {
                    ForEach(store.orderedSessions) { session in
                        TileView(session: session, now: now)
                            .flash(id: flashIds[session.id])
                            .onTapGesture { onClickSession(session) }
                            .draggable(DraggedSessionID(id: session.id)) {
                                TileView(session: session, now: now)
                                    .opacity(0.7)
                            }
                            .dropDestination(for: DraggedSessionID.self) { items, _ in
                                guard let source = items.first,
                                      let targetIdx = store.orderedSessions.firstIndex(where: { $0.id == session.id })
                                else { return false }
                                store.move(sessionId: source.id, toIndex: targetIdx)
                                return true
                            }
                    }
                }
                .padding(0)
            }
        }
        .frame(minWidth: 200, minHeight: 120)
        .onReceive(ticker) { now = $0 }
        .onChange(of: store.orderedSessions) { _, new in
            flashIds = flashCoordinator.update(sessions: new)
        }
        .onAppear {
            flashIds = flashCoordinator.update(sessions: store.orderedSessions)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.headline)
            Text("Start a Claude Code session in a terminal to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

/// Transferable wrapper used by drag-to-reorder.
struct DraggedSessionID: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/UI/DashboardView.swift
git commit -m "Add DashboardView: grid, flash, tick timer, drag-to-reorder"
```

---

## Task 26: `Preferences` — UserDefaults wrapper

**Files:**
- Create: `App/Settings/Preferences.swift`

- [ ] **Step 1: Create the file**

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

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Self.onboardedKey) }
        set { defaults.set(newValue, forKey: Self.onboardedKey) }
    }

    static let windowFrameAutosaveName = "ClaudeMonitorDashboardWindow"
    private static let configDirsKey = "managedConfigDirectories"
    private static let tileOrderKey = "manualTileOrder"
    private static let onboardedKey = "onboarded"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.managedConfigDirectoryPaths = defaults.stringArray(forKey: Self.configDirsKey) ?? []
        self.manualTileOrder = defaults.stringArray(forKey: Self.tileOrderKey) ?? []
    }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Settings/Preferences.swift
git commit -m "Add Preferences: UserDefaults-backed store"
```

---

## Task 27: `SingleInstanceGuard` — pidfile-based second-launch prevention

**Files:**
- Create: `App/Core/SingleInstanceGuard.swift`
- Create: `Tests/SingleInstanceGuardTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SingleInstanceGuardTests.swift
import XCTest
@testable import ClaudeMonitor

final class SingleInstanceGuardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_acquireWritesCurrentPid() throws {
        let guardPath = dir.appendingPathComponent("pid")
        let result = SingleInstanceGuard.acquire(at: guardPath)
        XCTAssertEqual(result, .acquired)
        let body = try String(contentsOf: guardPath, encoding: .utf8)
        XCTAssertEqual(Int32(body.trimmingCharacters(in: .whitespacesAndNewlines)),
                       ProcessInfo.processInfo.processIdentifier)
    }

    func test_acquireOverwritesStalePid() throws {
        let guardPath = dir.appendingPathComponent("pid")
        try "999999\n".write(to: guardPath, atomically: true, encoding: .utf8)  // non-existent pid
        let result = SingleInstanceGuard.acquire(at: guardPath)
        XCTAssertEqual(result, .acquired)
    }

    func test_acquireReportsLivePid() throws {
        // Write *our own* pid. It's live. We should see .alreadyRunning.
        let guardPath = dir.appendingPathComponent("pid")
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: guardPath, atomically: true, encoding: .utf8)
        let result = SingleInstanceGuard.acquire(at: guardPath)
        if case .alreadyRunning(let pid) = result {
            XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
        } else {
            XCTFail("expected alreadyRunning, got \(result)")
        }
    }
}
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `SingleInstanceGuard` undefined.

- [ ] **Step 3: Implement**

```swift
// App/Core/SingleInstanceGuard.swift
import Foundation
import Darwin

enum SingleInstanceGuardResult: Equatable {
    case acquired
    case alreadyRunning(pid_t)
}

enum SingleInstanceGuard {
    static func acquire(at path: URL) -> SingleInstanceGuardResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: path.path),
           let body = try? String(contentsOf: path, encoding: .utf8),
           let pid = pid_t(body.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           kill(pid, 0) == 0  // signal 0 = existence check
        {
            return .alreadyRunning(pid)
        }
        // Take ownership.
        let our = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try? our.write(to: path, atomically: true, encoding: .utf8)
        return .acquired
    }

    static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/pid")
    }
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add App/Core/SingleInstanceGuard.swift Tests/SingleInstanceGuardTests.swift
git commit -m "Add SingleInstanceGuard: pidfile-based second-launch detection"
```

---

## Task 28: `StaleSessionSweeper` — kill(pid, 0) sweep

**Files:**
- Create: `App/Core/StaleSessionSweeper.swift`
- Create: `Tests/StaleSessionSweeperTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/StaleSessionSweeperTests.swift
import XCTest
@testable import ClaudeMonitor

final class StaleSessionSweeperTests: XCTestCase {
    private func event(session: String, pid: Int32, hook: HookName = .sessionStart) -> HookEvent {
        HookEvent(hook: hook, sessionId: session, tty: "/dev/ttys001", pid: pid,
                  cwd: "/p/\(session)", ts: 0, promptPreview: nil, toolName: nil)
    }

    func test_sweepMarksDeadProcessSessionsFinished() {
        let store = SessionStore(clock: FakeClock())
        // My own PID = live.
        store.apply(event(session: "live", pid: ProcessInfo.processInfo.processIdentifier))
        // A pid that won't exist (32-bit max).
        store.apply(event(session: "dead", pid: 2_147_483_000))

        let sweeper = StaleSessionSweeper(store: store)
        sweeper.sweep()

        let byId = Dictionary(uniqueKeysWithValues: store.orderedSessions.map { ($0.id, $0.state) })
        XCTAssertEqual(byId["live"], .waiting)  // unchanged
        XCTAssertEqual(byId["dead"], .finished) // swept
    }

    func test_sweepIgnoresAlreadyFinishedSessions() {
        let store = SessionStore(clock: FakeClock())
        store.apply(event(session: "done", pid: 2_147_483_000, hook: .sessionStart))
        store.apply(event(session: "done", pid: 2_147_483_000, hook: .sessionEnd))
        let before = store.orderedSessions[0].enteredStateAt

        StaleSessionSweeper(store: store).sweep()
        XCTAssertEqual(store.orderedSessions[0].enteredStateAt, before,
                       "already-finished sessions must not have enteredStateAt bumped")
    }
}
```

- [ ] **Step 2: Run — expected to fail**

Run: `make gen && make test`
Expected: FAIL — `StaleSessionSweeper` undefined.

- [ ] **Step 3: Implement**

```swift
// App/Core/StaleSessionSweeper.swift
import Foundation
import Darwin

final class StaleSessionSweeper {
    private let store: SessionStore
    private var timer: Timer?
    private let interval: TimeInterval

    init(store: SessionStore, interval: TimeInterval = 60) {
        self.store = store
        self.interval = interval
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sweep()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sweep() {
        for session in store.orderedSessions {
            guard session.state != .finished else { continue }
            if kill(session.pid, 0) != 0 {   // process gone
                store.markFinished(sessionId: session.id)
            }
        }
    }
}
```

- [ ] **Step 4: Verify**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add App/Core/StaleSessionSweeper.swift Tests/StaleSessionSweeperTests.swift
git commit -m "Add StaleSessionSweeper: mark sessions with dead PIDs as finished"
```

---

## Task 29: `DashboardWindow` — `NSWindow` wrapper with frame autosave

**Files:**
- Create: `App/UI/DashboardWindow.swift`

- [ ] **Step 1: Create the file**

```swift
// App/UI/DashboardWindow.swift
import AppKit
import SwiftUI

final class DashboardWindow {
    private let window: NSWindow

    init<Content: View>(rootView: Content) {
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Claude Monitor"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setFrameAutosaveName(Preferences.windowFrameAutosaveName)
        window.isReleasedWhenClosed = false
        window.level = .normal
        self.window = window
    }

    func showAndBringToFront() {
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }

    var isVisible: Bool { window.isVisible }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/UI/DashboardWindow.swift
git commit -m "Add DashboardWindow: NSWindow wrapper with frame autosave"
```

---

## Task 30: `MenuBarController` — NSStatusItem with aggregate glyph + badge

**Files:**
- Create: `App/UI/MenuBarController.swift`

- [ ] **Step 1: Create the file**

```swift
// App/UI/MenuBarController.swift
import AppKit
import Combine
import SwiftUI

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let store: SessionStore
    private let onOpenDashboard: () -> Void
    private let onOpenSettings: () -> Void
    private var cancellable: AnyCancellable?

    init(store: SessionStore,
         onOpenDashboard: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureButton()
        buildMenu()

        cancellable = store.$orderedSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in self?.refresh(sessions) }
        refresh(store.orderedSessions)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Claude Monitor")
        button.image?.isTemplate = false
    }

    private func buildMenu() {
        let menu = NSMenu()

        let dashboard = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboard.target = self
        menu.addItem(dashboard)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Monitor",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func refresh(_ sessions: [Session]) {
        guard let button = statusItem.button else { return }
        let needsYou = sessions.filter { $0.state == .needsYou }.count
        let anyWaiting = sessions.contains { $0.state == .waiting }
        let anyWorking = sessions.contains { $0.state == .working }

        let color: NSColor
        if needsYou > 0      { color = NSColor(red: 0xEF/255, green: 0x44/255, blue: 0x44/255, alpha: 1) }
        else if anyWaiting   { color = NSColor(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255, alpha: 1) }
        else if anyWorking   { color = NSColor(red: 0x3B/255, green: 0x82/255, blue: 0xF6/255, alpha: 1) }
        else                 { color = NSColor(red: 0x6B/255, green: 0x72/255, blue: 0x80/255, alpha: 1) }

        let size = CGSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)).fill()
        img.unlockFocus()
        img.isTemplate = false
        button.image = img
        button.title = needsYou > 0 ? " \(needsYou)" : ""
    }

    @objc private func openDashboard() { onOpenDashboard() }
    @objc private func openSettings()  { onOpenSettings() }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/UI/MenuBarController.swift
git commit -m "Add MenuBarController: NSStatusItem with aggregate color + badge"
```

---

## Task 31: `OnboardingView` — first-run sheet

**Files:**
- Create: `App/UI/OnboardingView.swift`

- [ ] **Step 1: Create the file**

```swift
// App/UI/OnboardingView.swift
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var preferences: Preferences
    let onFinished: () -> Void

    @State private var discoveredDirs: [URL] = []
    @State private var selected: Set<URL> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Claude Code hooks")
                .font(.title2).bold()
            Text("Select the Claude config directories where Claude Monitor should install its hooks. You can change this later in Settings.")
                .font(.body)

            if discoveredDirs.isEmpty {
                Text("No config directories found under your home folder.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(discoveredDirs, id: \.self) { dir in
                        Toggle(isOn: binding(for: dir)) {
                            Text(dir.path).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                .frame(minHeight: 120)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }

            HStack {
                Button("Skip") { preferences.hasOnboarded = true; onFinished() }
                Spacer()
                Button("Install Selected") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            discoveredDirs = ConfigDirectoryDiscovery.scan()
            selected = Set(discoveredDirs)
        }
    }

    private func binding(for dir: URL) -> Binding<Bool> {
        Binding(
            get: { selected.contains(dir) },
            set: { isOn in
                if isOn { selected.insert(dir) } else { selected.remove(dir) }
            }
        )
    }

    private func install() {
        do {
            try HookScriptDeployer.deploy()
            for dir in selected {
                try HookInstaller.install(configDir: dir)
            }
            preferences.managedConfigDirectoryPaths = Array(selected.map(\.path)).sorted()
            preferences.hasOnboarded = true
            onFinished()
        } catch {
            errorMessage = "Install failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/UI/OnboardingView.swift
git commit -m "Add OnboardingView: first-run config-dir checklist"
```

---

## Task 32: `SettingsView` — managed directories + reinstall/uninstall

**Files:**
- Create: `App/UI/SettingsView.swift`

- [ ] **Step 1: Create the file**

```swift
// App/UI/SettingsView.swift
import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var directoriesWithStatus: [ManagedConfigDirectory] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Managed Claude config directories").font(.headline)
            Text("Claude Monitor installs its hook block into each directory's settings.json. Other hooks you've configured are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(directoriesWithStatus) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.url.path).font(.system(.body, design: .monospaced))
                            Text(statusLabel(entry.status))
                                .font(.caption)
                                .foregroundStyle(statusColor(entry.status))
                        }
                        Spacer()
                        if entry.status == .installed {
                            Button("Reinstall") { install(entry.url) }
                        } else if entry.status == .outdated || entry.status == .modifiedExternally {
                            Button("Reinstall") { install(entry.url) }
                                .tint(.orange)
                        } else {
                            Button("Install") { install(entry.url) }
                        }
                        Button("Remove", role: .destructive) { remove(entry) }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("Add Directory…") { addDirectory() }
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .onAppear { refresh() }
    }

    private func refresh() {
        directoriesWithStatus = preferences.managedConfigDirectoryPaths
            .map(URL.init(fileURLWithPath:))
            .map { url in
                let status = (try? HookInstaller.inspect(configDir: url))
                    ?? HookInstaller.Status(status: .notInstalled, installedVersion: 0)
                return ManagedConfigDirectory(url: url,
                                              status: status.status,
                                              installedVersion: status.installedVersion)
            }
    }

    private func install(_ dir: URL) {
        do {
            try HookScriptDeployer.deploy()
            try HookInstaller.install(configDir: dir)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ entry: ManagedConfigDirectory) {
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.url.lastPathComponent)?"
        alert.informativeText = "Also uninstall the hook block from its settings.json?"
        alert.addButton(withTitle: "Uninstall & Remove")
        alert.addButton(withTitle: "Remove from List Only")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? HookInstaller.uninstall(configDir: entry.url)
            preferences.managedConfigDirectoryPaths.removeAll { $0 == entry.url.path }
            refresh()
        case .alertSecondButtonReturn:
            preferences.managedConfigDirectoryPaths.removeAll { $0 == entry.url.path }
            refresh()
        default:
            break
        }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !preferences.managedConfigDirectoryPaths.contains(url.path) {
            preferences.managedConfigDirectoryPaths.append(url.path)
        }
        refresh()
    }

    private func statusLabel(_ s: HookInstallStatus) -> String {
        switch s {
        case .installed:          return "Installed"
        case .notInstalled:       return "Not installed"
        case .outdated:           return "Outdated — reinstall recommended"
        case .modifiedExternally: return "Modified externally"
        }
    }

    private func statusColor(_ s: HookInstallStatus) -> Color {
        switch s {
        case .installed:          return .green
        case .notInstalled:       return .secondary
        case .outdated:           return .orange
        case .modifiedExternally: return .orange
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/UI/SettingsView.swift
git commit -m "Add SettingsView: managed directory list with install/uninstall"
```

---

## Task 33: Wire everything together in `ClaudeMonitorApp`

**Files:**
- Modify: `App/ClaudeMonitorApp.swift`
- Create: `App/AppDelegate.swift`

- [ ] **Step 1: Replace `ClaudeMonitorApp.swift`**

```swift
// App/ClaudeMonitorApp.swift
import SwiftUI
import AppKit

@main
struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // A hidden window group satisfies the App protocol. All real windows are
        // constructed in AppDelegate so we control their lifetimes directly.
        Settings {
            SettingsView(preferences: delegate.preferences)
        }
    }
}
```

- [ ] **Step 2: Create `AppDelegate.swift`**

```swift
// App/AppDelegate.swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    private let store = SessionStore()
    private var server: EventServer!
    private var sweeper: StaleSessionSweeper!
    private var dashboard: DashboardWindow!
    private var menuBar: MenuBarController!
    private var bridge: TerminalBridgeProtocol = TerminalBridge()
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Single instance guard.
        if case .alreadyRunning = SingleInstanceGuard.acquire(at: SingleInstanceGuard.defaultLocation) {
            NSApp.terminate(nil)
            return
        }

        // 2. Start the HTTP server and publish its port.
        server = EventServer { [weak self] event in
            DispatchQueue.main.async { self?.store.apply(event) }
        }
        do {
            try server.start()
            if let port = server.port {
                try PortFileWriter(destination: PortFileWriter.defaultLocation).write(port: port)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Claude Monitor couldn't start its event server"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        // 3. 1Hz tick for tile timers + 60s stale sweep.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.store.tickRemovalTimer()
        }
        sweeper = StaleSessionSweeper(store: store)
        sweeper.start()

        // 4. Dashboard window.
        let content = DashboardView(store: store, onClickSession: { [weak self] session in
            self?.handleClick(on: session)
        })
        dashboard = DashboardWindow(rootView: content)

        // 5. Menu bar.
        menuBar = MenuBarController(
            store: store,
            onOpenDashboard: { [weak self] in self?.dashboard.showAndBringToFront() },
            onOpenSettings:  { [weak self] in self?.openSettings() }
        )

        // 6. First-run onboarding.
        if !preferences.hasOnboarded {
            presentOnboarding()
        } else {
            dashboard.showAndBringToFront()
        }
    }

    private func handleClick(on session: Session) {
        let result = bridge.focus(tty: session.tty, expectedPid: session.pid)
        switch result {
        case .focused:
            break
        case .noSuchTab, .terminalNotRunning:
            store.markFinished(sessionId: session.id)
        case .scriptError(let message):
            NSLog("TerminalBridge script error: \(message)")
        }
    }

    private func presentOnboarding() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Claude Monitor"
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(preferences: preferences) { [weak self, weak window] in
            window?.close()
            self?.dashboard.showAndBringToFront()
        })
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `make gen && xcodebuild build ...`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Launch the app manually**

```bash
xcodebuild -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -configuration Debug -derivedDataPath build
open build/Build/Products/Debug/ClaudeMonitor.app
```

Expected: onboarding sheet shows up, discovers `~/.claude` / `~/.claudewho-*`, installs on confirm, dashboard window appears (empty), menu bar icon appears.

- [ ] **Step 5: End-to-end smoke test by hand**

In a new Terminal.app tab:

```bash
export HOME="$HOME"   # sanity
cat > /tmp/fake-event.sh <<'EOF'
#!/bin/bash
curl -s -m 2 -X POST -H "Content-Type: application/json" \
  --data-binary "{\"hook\":\"SessionStart\",\"session_id\":\"demo-$$\",\"tty\":\"$(tty)\",\"pid\":$$,\"cwd\":\"$PWD\",\"ts\":$(date +%s)}" \
  "http://127.0.0.1:$(cat ~/.claude-monitor/port)/event"
EOF
chmod +x /tmp/fake-event.sh
/tmp/fake-event.sh
```

Expected: a waiting (amber) tile appears in the dashboard labeled with the parent directory.

Then:

```bash
# Simulate UserPromptSubmit -> working
curl -s -m 2 -X POST -H "Content-Type: application/json" \
  --data-binary "{\"hook\":\"UserPromptSubmit\",\"session_id\":\"demo-$$\",\"tty\":\"$(tty)\",\"pid\":$$,\"cwd\":\"$PWD\",\"ts\":$(date +%s),\"prompt_preview\":\"hello world\"}" \
  "http://127.0.0.1:$(cat ~/.claude-monitor/port)/event"
```

Expected: tile flips blue, shows "hello world" snippet.

Click the tile in the dashboard. Expected: that Terminal tab is brought to the front. (Grants Automation permission on first use.)

- [ ] **Step 6: Commit**

```bash
git add App/ClaudeMonitorApp.swift App/AppDelegate.swift
git commit -m "Wire app: AppDelegate composes server, store, window, menu bar, onboarding"
```

---

## Task 34: End-to-end XCUITest smoke

Launches the real app, POSTs an event sequence, asserts tiles appear/change/disappear.

**Files:**
- Create: `UITests/ClaudeMonitorUITests.swift`
- Modify: `project.yml` (add UITests target)

- [ ] **Step 1: Add UITest target to `project.yml`**

```yaml
  ClaudeMonitorUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: UITests
    dependencies:
      - target: ClaudeMonitor
```

- [ ] **Step 2: Write the UI test**

```swift
// UITests/ClaudeMonitorUITests.swift
import XCTest

final class ClaudeMonitorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_tileAppearsAndChangesOnHookEvents() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLAUDE_MONITOR_SKIP_ONBOARDING"] = "1"
        app.launch()

        // Give the app a moment to write the port file.
        let portFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-monitor/port")
        let exp = expectation(description: "port file present")
        DispatchQueue.global().async {
            for _ in 0..<20 {
                if FileManager.default.fileExists(atPath: portFile.path) { exp.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        wait(for: [exp], timeout: 6)

        let port = (try String(contentsOf: portFile, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Post SessionStart.
        postEvent(port: port, hook: "SessionStart", sessionId: "uitest-1",
                  cwd: "/Users/leo/Projects/smoke-target")
        // Expect a tile with project name "smoke-target" to appear.
        let tile = app.otherElements.containing(NSPredicate(format: "label CONTAINS 'smoke-target'"))
            .firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 3))
    }

    private func postEvent(port: String, hook: String, sessionId: String, cwd: String) {
        let url = URL(string: "http://127.0.0.1:\(port)/event")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = """
        {"hook":"\(hook)","session_id":"\(sessionId)","tty":"/dev/ttys001","pid":1,"cwd":"\(cwd)","ts":1}
        """.data(using: .utf8)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _,_,_ in sem.signal() }.resume()
        sem.wait()
    }
}
```

- [ ] **Step 3: Make the app respect `CLAUDE_MONITOR_SKIP_ONBOARDING`**

Edit `App/AppDelegate.swift`:

```swift
        if !preferences.hasOnboarded && ProcessInfo.processInfo.environment["CLAUDE_MONITOR_SKIP_ONBOARDING"] != "1" {
            presentOnboarding()
        } else {
            dashboard.showAndBringToFront()
        }
```

- [ ] **Step 4: Run**

```bash
make gen
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' -only-testing:ClaudeMonitorUITests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add UITests/ClaudeMonitorUITests.swift project.yml App/AppDelegate.swift
git commit -m "Add end-to-end UI test: POST events, assert tile appears"
```

---

## Task 35: Final check — full test run + manual regression

- [ ] **Step 1: Run full test suite**

```bash
make test
```

Expected: all unit test targets green.

- [ ] **Step 2: Optional integration test**

```bash
RUN_TERMINAL_INTEGRATION=1 make test-integration
```

Expected: PASS on a Mac where Automation permission has been granted.

- [ ] **Step 3: Manual regression checklist**

Walk through each of these; if any fail, file a task to fix before shipping.

- [ ] Cold launch → onboarding sheet → install hooks into `~/.claude` → sheet dismisses → dashboard visible (empty) → menu bar icon grey.
- [ ] Start a real `claude` session in Terminal — a waiting (amber) tile appears with the project name.
- [ ] Send a prompt in Claude — tile goes blue, shows prompt snippet, flashes when it next goes amber.
- [ ] Trigger a permission prompt (e.g. a tool Claude hasn't been allow-listed for) — tile goes red with flash, menu bar icon turns red with "1" badge.
- [ ] Approve in the Terminal — tile returns to blue with flash.
- [ ] Close the Terminal tab forcefully (without exiting Claude gracefully) — within 60s the tile turns grey and disappears 10s later.
- [ ] Click a tile while its Terminal tab is still live — Terminal comes to front with that tab selected.
- [ ] Close the dashboard window → menu bar click reopens it at the same position on the same monitor.
- [ ] Settings → add `~/.claudewho-foo` via picker → status shows Installed after install click.
- [ ] Quit app, relaunch — window reappears in the same frame; any live claude session re-registers its tile on the next event.
- [ ] Launch a second instance — it exits immediately and the first stays running.

- [ ] **Step 4: Tag v1**

```bash
git tag -a v1.0.0 -m "Claude Monitor v1.0.0"
```
