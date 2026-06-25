# Background-Working Session State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop ClaudeMonitor from showing "Waiting" + firing a premature idle push when a session's main agent has stopped but background tasks are still running; show a distinct "Working · N tasks" state instead, and stop leaking raw `<task-notification>` XML onto tiles.

**Architecture:** Detection is stateless — the `Stop` hook payload (Claude Code 2.1.191) already carries a `background_tasks` array with each task's `status`. `hook.sh` reduces it to an integer `background_tasks_active` and forwards it. `StateMachine` maps a `Stop` with active tasks to a new `backgroundWorking` state; `PushNotifier` suppresses the push for that case. A separate `hook.sh` tweak drops the synthetic `<task-notification>` prompt so the tile keeps the last human prompt.

**Tech Stack:** Swift / SwiftUI (macOS 14+), XCTest, bash + python3 (`scripts/hook.sh`), XcodeGen.

## Global Constraints

- Target Claude Code hook payload is from version 2.1.191. Active-task rule: a background task is **active** unless its `status` (lowercased) is one of `completed`, `failed`, `cancelled` (treat unknown/missing as active).
- `scripts/hook.sh` is a **build resource**, not inlined into Swift — edit the file. It must always `exit 0`. `HookScriptDeployer` overwrites `~/.claude-monitor/hook.sh` on every launch, so no installer version bump and **no `HookInstaller` change** is needed (we reuse the already-installed `Stop` hook).
- No new source files are created (only edits to existing files + new tests in existing files), so `make gen` is NOT required. If you add a brand-new file for any reason, run `make gen` first.
- New state raw value: `backgroundWorking`. Tile label text: `Working` (count rendered separately as `· N task`/`· N tasks`).
- Dimmed-blue color is derived per-palette as `working.dimmed()` (a darker variant), so the default Vibrant palette yields a dimmed blue and every palette stays self-consistent. The separate menu-bar dot color (`SessionStateColor`) is a fixed dimmed blue `#255199` (= Vibrant `working.dimmed(0.62)`).
- Each task must end with a green build (`SessionState` is used in exhaustive `switch`es, so the case + all switches land together in Task 3).
- Test run commands:
  - All tests: `make test`
  - Single test: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/<Suite>/<test>`

---

### Task 1: `HookEvent` carries `backgroundTasksActive`

**Files:**
- Modify: `App/Models/HookEvent.swift`
- Test: `Tests/HookEventTests.swift`

**Interfaces:**
- Produces: `HookEvent.backgroundTasksActive: Int?` (coding key `background_tasks_active`); a memberwise `init(...)` whose last parameter is `backgroundTasksActive: Int? = nil` so all existing call sites keep compiling.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/HookEventTests.swift`:

```swift
func test_decodesStopWithBackgroundTasksActive() throws {
    let json = """
    {"hook":"Stop","session_id":"s","tty":"/","pid":1,"cwd":"/","ts":1,"background_tasks_active":2}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(HookEvent.self, from: json)
    XCTAssertEqual(event.backgroundTasksActive, 2)
}

func test_decodesStopWithoutBackgroundTasksActiveIsNil() throws {
    let json = """
    {"hook":"Stop","session_id":"s","tty":"/","pid":1,"cwd":"/","ts":1}
    """.data(using: .utf8)!
    let event = try JSONDecoder().decode(HookEvent.self, from: json)
    XCTAssertNil(event.backgroundTasksActive)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/HookEventTests/test_decodesStopWithBackgroundTasksActive`
Expected: FAIL — `value of type 'HookEvent' has no member 'backgroundTasksActive'` (compile error).

- [ ] **Step 3: Add the property, coding key, and a defaulted init**

In `App/Models/HookEvent.swift`, add the stored property (after `message`):

```swift
    let message: String?
    let backgroundTasksActive: Int?
```

Add the coding key (after `case message`):

```swift
        case message
        case backgroundTasksActive = "background_tasks_active"
```

Add an explicit memberwise init so existing constructors that omit the new field still compile (place it inside the struct, before `enum CodingKeys`):

```swift
    init(hook: HookName, sessionId: String, tty: String, pid: Int32, cwd: String,
         ts: Int, promptPreview: String?, toolName: String?,
         notificationType: String?, message: String?,
         backgroundTasksActive: Int? = nil) {
        self.hook = hook
        self.sessionId = sessionId
        self.tty = tty
        self.pid = pid
        self.cwd = cwd
        self.ts = ts
        self.promptPreview = promptPreview
        self.toolName = toolName
        self.notificationType = notificationType
        self.message = message
        self.backgroundTasksActive = backgroundTasksActive
    }
```

(Writing a plain `init` does not suppress synthesized `Codable`; `decodeIfPresent` for the optional is generated automatically.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/HookEventTests`
Expected: PASS (all HookEventTests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add App/Models/HookEvent.swift Tests/HookEventTests.swift
git commit -m "Add backgroundTasksActive to HookEvent"
```

---

### Task 2: `hook.sh` emits the count and drops synthetic previews

**Files:**
- Modify: `scripts/hook.sh`
- Test: `Tests/HookScriptTests.swift`

**Interfaces:**
- Consumes: `HookEvent.backgroundTasksActive` (Task 1) for assertions via the real `EventServer`.
- Produces: POST payload includes `"background_tasks_active": <int>` when the incoming JSON has a `background_tasks` array; omits `prompt_preview` when the prompt begins with `<task-notification>`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/HookScriptTests.swift` (reuse the existing `findHookScript()` helper in that file). These mirror the existing `test_hookScriptPostsEnrichedPayload` structure:

```swift
func test_hookScriptCountsActiveBackgroundTasks() async throws {
    let scriptURL = try XCTUnwrap(findHookScript(), "could not find hook.sh")
    var received: [HookEvent] = []
    let expect = expectation(description: "event")
    let server = EventServer { event in received.append(event); expect.fulfill() }
    try server.start(); defer { server.stop() }

    let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tmpHome.appendingPathComponent(".claude-monitor"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpHome) }
    try "\(server.port!)\n".write(to: tmpHome.appendingPathComponent(".claude-monitor/port"),
                                  atomically: true, encoding: .utf8)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [scriptURL.path, "Stop"]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = tmpHome.path
    proc.environment = env
    let inputPipe = Pipe()
    proc.standardInput = inputPipe
    try proc.run()
    inputPipe.fileHandleForWriting.write(#"""
    {"session_id":"s","background_tasks":[{"id":"a","status":"running"},{"id":"b","status":"completed"},{"id":"c","status":"in_progress"}]}
    """#.data(using: .utf8)!)
    try inputPipe.fileHandleForWriting.close()
    proc.waitUntilExit()
    XCTAssertEqual(proc.terminationStatus, 0)

    await fulfillment(of: [expect], timeout: 3)
    XCTAssertEqual(received.first?.backgroundTasksActive, 2)
}

func test_hookScriptOmitsSyntheticTaskNotificationPreview() async throws {
    let scriptURL = try XCTUnwrap(findHookScript(), "could not find hook.sh")
    var received: [HookEvent] = []
    let expect = expectation(description: "event")
    let server = EventServer { event in received.append(event); expect.fulfill() }
    try server.start(); defer { server.stop() }

    let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tmpHome.appendingPathComponent(".claude-monitor"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpHome) }
    try "\(server.port!)\n".write(to: tmpHome.appendingPathComponent(".claude-monitor/port"),
                                  atomically: true, encoding: .utf8)

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
    {"session_id":"s","prompt":"<task-notification>\n<task-id>abc</task-id>\n</task-notification>"}
    """#.data(using: .utf8)!)
    try inputPipe.fileHandleForWriting.close()
    proc.waitUntilExit()
    XCTAssertEqual(proc.terminationStatus, 0)

    await fulfillment(of: [expect], timeout: 3)
    XCTAssertEqual(received.count, 1)
    XCTAssertNil(received[0].promptPreview)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/HookScriptTests/test_hookScriptCountsActiveBackgroundTasks`
Expected: FAIL — `backgroundTasksActive` is `nil` (≠ 2).

- [ ] **Step 3: Update `scripts/hook.sh`**

In the `python3` heredoc block, replace the preview lines:

```python
preview = src.get("prompt") or src.get("user_prompt")
if isinstance(preview, str):
    out["prompt_preview"] = preview[:120]
```

with:

```python
preview = src.get("prompt") or src.get("user_prompt")
if isinstance(preview, str) and not preview.lstrip().startswith("<task-notification>"):
    out["prompt_preview"] = preview[:120]
```

Then, immediately before `print(json.dumps(out))`, add:

```python
bg = src.get("background_tasks")
if isinstance(bg, list):
    terminal = {"completed", "failed", "cancelled"}
    out["background_tasks_active"] = sum(
        1 for t in bg
        if isinstance(t, dict) and str(t.get("status", "")).lower() not in terminal
    )
```

Leave the minimal non-python `sed` fallback unchanged (it omits the field; absence decodes to `nil`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/HookScriptTests`
Expected: PASS (all four HookScriptTests).

- [ ] **Step 5: Commit**

```bash
git add scripts/hook.sh Tests/HookScriptTests.swift
git commit -m "Forward background-task count and drop synthetic preview in hook.sh"
```

---

### Task 3: Add `backgroundWorking` state + its colors

This task adds the enum case **and** every exhaustive `switch` that consumes it (label, tile palette, menu-bar dot) so the project stays compilable.

**Files:**
- Modify: `App/Models/SessionState.swift`
- Modify: `App/Models/RGB.swift`
- Modify: `App/Models/Palette.swift`
- Modify: `App/Models/SessionStateColor.swift`
- Test: `Tests/StateMachineTests.swift`, `Tests/PaletteTests.swift`, `Tests/SessionStateColorTests.swift`

**Interfaces:**
- Produces: `SessionState.backgroundWorking` (rawValue `"backgroundWorking"`), `displayLabel == "Working"`; `RGB.dimmed(by:) -> RGB`; `Palette.background(for: .backgroundWorking) == working.dimmed()`; `SessionStateColor.nsColor(for: .backgroundWorking) == #255199`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/StateMachineTests.swift`:

```swift
func test_backgroundWorkingLabelIsWorking() {
    XCTAssertEqual(SessionState.backgroundWorking.displayLabel, "Working")
}
```

Add to `Tests/PaletteTests.swift` (inside `PaletteTests`):

```swift
func test_backgroundWorkingIsDimmedWorking() {
    let p = Palette.resolve(.vibrant)
    XCTAssertEqual(p.background(for: .backgroundWorking), p.working.dimmed())
}

func test_dimmedDarkensChannels() {
    let dimmed = RGB(0x3B82F6).dimmed(by: 0.5)
    XCTAssertEqual(dimmed.red,   Double(0x3B) / 255.0 * 0.5, accuracy: 1e-9)
    XCTAssertEqual(dimmed.green, Double(0x82) / 255.0 * 0.5, accuracy: 1e-9)
    XCTAssertEqual(dimmed.blue,  Double(0xF6) / 255.0 * 0.5, accuracy: 1e-9)
}
```

In `Tests/SessionStateColorTests.swift`, extend the distinctness list and add a hex assertion. Replace the `states` array in `testEachStateMapsToDistinctColor`:

```swift
        let states: [SessionState] = [.needsYou, .waiting, .working, .backgroundWorking, .finished]
```

and add:

```swift
    func testBackgroundWorkingHex() {
        XCTAssertEqual(SessionStateColor.nsColor(for: .backgroundWorking).hexString, "#255199")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/StateMachineTests/test_backgroundWorkingLabelIsWorking`
Expected: FAIL — `type 'SessionState' has no member 'backgroundWorking'` (compile error).

- [ ] **Step 3a: Add the case and label**

In `App/Models/SessionState.swift`:

```swift
enum SessionState: String, Codable, Equatable, CaseIterable {
    case working
    case backgroundWorking
    case waiting
    case needsYou
    case finished
}
```

In the `displayLabel` switch, after the `.working` line:

```swift
        case .working:           return "Working"
        case .backgroundWorking: return "Working"
```

- [ ] **Step 3b: Add `RGB.dimmed`**

In `App/Models/RGB.swift`, add a new extension at the end of the file:

```swift
extension RGB {
    /// A darker variant used for the `backgroundWorking` state so it reads as
    /// "working, but in the background". Scales each channel toward black.
    func dimmed(by factor: Double = 0.62) -> RGB {
        RGB(red: red * factor, green: green * factor, blue: blue * factor, opacity: opacity)
    }
}
```

- [ ] **Step 3c: Handle the case in `Palette.background(for:)`**

In `App/Models/Palette.swift`, in the `switch state` of `background(for:)`:

```swift
        case .working:           return working
        case .backgroundWorking: return working.dimmed()
```

- [ ] **Step 3d: Handle the case in `SessionStateColor`**

In `App/Models/SessionStateColor.swift`, in the switch:

```swift
        case .working:           return NSColor(srgbRed: 0x3B/255, green: 0x82/255, blue: 0xF6/255, alpha: 1)
        case .backgroundWorking: return NSColor(srgbRed: 0x24/255, green: 0x50/255, blue: 0x8F/255, alpha: 1)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/StateMachineTests -only-testing:ClaudeMonitorTests/PaletteTests -only-testing:ClaudeMonitorTests/SessionStateColorTests`
Expected: PASS. The full project compiles (all `SessionState` switches are exhaustive). `test_highContrastMeetsWCAG_AA_ForEveryBackground` still passes because dimmed High-Contrast working is darker → higher contrast vs white text.

- [ ] **Step 5: Commit**

```bash
git add App/Models/SessionState.swift App/Models/RGB.swift App/Models/Palette.swift App/Models/SessionStateColor.swift Tests/StateMachineTests.swift Tests/PaletteTests.swift Tests/SessionStateColorTests.swift
git commit -m "Add backgroundWorking state with dimmed-blue colors"
```

---

### Task 4: `StateMachine` maps Stop-with-active-tasks to `backgroundWorking`

**Files:**
- Modify: `App/Core/StateMachine.swift`
- Test: `Tests/StateMachineTests.swift`

**Interfaces:**
- Consumes: `SessionState.backgroundWorking` (Task 3).
- Produces: `StateMachine.transition(from:for:backgroundTasksActive:)` with `backgroundTasksActive: Int = 0` default (keeps existing call sites/tests compiling). On `.stop`: `backgroundWorking` if `backgroundTasksActive > 0`, else `.waiting`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/StateMachineTests.swift`:

```swift
func test_stopWithActiveBackgroundTasksGoesToBackgroundWorking() {
    XCTAssertEqual(
        StateMachine.transition(from: .working, for: .stop, backgroundTasksActive: 2),
        .backgroundWorking)
}

func test_stopWithZeroBackgroundTasksGoesToWaiting() {
    XCTAssertEqual(
        StateMachine.transition(from: .working, for: .stop, backgroundTasksActive: 0),
        .waiting)
    XCTAssertEqual(StateMachine.transition(from: .working, for: .stop), .waiting) // default arg
}

func test_backgroundWorkingGoesToWorkingOnUserPromptSubmit() {
    XCTAssertEqual(
        StateMachine.transition(from: .backgroundWorking, for: .userPromptSubmit),
        .working)
}

func test_backgroundWorkingGoesToFinishedOnSessionEnd() {
    XCTAssertEqual(
        StateMachine.transition(from: .backgroundWorking, for: .sessionEnd),
        .finished)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/StateMachineTests/test_stopWithActiveBackgroundTasksGoesToBackgroundWorking`
Expected: FAIL — extra argument `backgroundTasksActive` (compile error).

- [ ] **Step 3: Update `StateMachine`**

Replace the body of `App/Core/StateMachine.swift` with:

```swift
import Foundation

enum StateMachine {
    /// Compute the new state given the current state (nil if unknown session) and incoming hook.
    /// Unknown sessions are synthesized as if a SessionStart had fired first.
    /// `backgroundTasksActive` is the count of still-running background tasks reported by the
    /// `Stop` hook payload; it only influences the `.stop` transition.
    static func transition(from current: SessionState?,
                           for hook: HookName,
                           backgroundTasksActive: Int = 0) -> SessionState {
        let base = current ?? applyFromNil()
        return apply(base, hook, backgroundTasksActive)
    }

    private static func applyFromNil() -> SessionState {
        .waiting  // synthesized SessionStart
    }

    private static func apply(_ state: SessionState,
                              _ hook: HookName,
                              _ backgroundTasksActive: Int) -> SessionState {
        if state == .finished { return .finished }
        switch hook {
        case .sessionStart:     return .waiting
        case .userPromptSubmit: return .working
        case .stop:             return backgroundTasksActive > 0 ? .backgroundWorking : .waiting
        case .notification:     return .needsYou
        case .sessionEnd:       return .finished
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/StateMachineTests`
Expected: PASS (all StateMachineTests).

- [ ] **Step 5: Commit**

```bash
git add App/Core/StateMachine.swift Tests/StateMachineTests.swift
git commit -m "Map Stop with active background tasks to backgroundWorking"
```

---

### Task 5: `SessionStore` applies the count and persists it on `Session`

**Files:**
- Modify: `App/Models/Session.swift`
- Modify: `App/Core/SessionStore.swift`
- Test: `Tests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `StateMachine.transition(from:for:backgroundTasksActive:)` (Task 4), `HookEvent.backgroundTasksActive` (Task 1).
- Produces: `Session.backgroundTaskCount: Int` (default `0`), set to the active count while the session is `.backgroundWorking`, else `0`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SessionStoreTests.swift` (the file's `event(...)` helper does not pass `backgroundTasksActive`, so build the `Stop` events inline):

```swift
func test_stopWithActiveBackgroundTasksEntersBackgroundWorkingWithCount() {
    let store = SessionStore(clock: FakeClock())
    store.apply(event(.sessionStart, session: "s"))
    let stop = HookEvent(hook: .stop, sessionId: "s", tty: "/dev/ttys0", pid: 1, cwd: "/p",
                         ts: 0, promptPreview: nil, toolName: nil,
                         notificationType: nil, message: nil, backgroundTasksActive: 3)
    store.apply(stop)
    let s = store.orderedSessions.first { $0.id == "s" }
    XCTAssertEqual(s?.state, .backgroundWorking)
    XCTAssertEqual(s?.backgroundTaskCount, 3)
}

func test_stopWithNoBackgroundTasksClearsCountAndWaits() {
    let store = SessionStore(clock: FakeClock())
    store.apply(event(.sessionStart, session: "s"))
    let busy = HookEvent(hook: .stop, sessionId: "s", tty: "/dev/ttys0", pid: 1, cwd: "/p",
                         ts: 0, promptPreview: nil, toolName: nil,
                         notificationType: nil, message: nil, backgroundTasksActive: 2)
    store.apply(busy)
    let idle = HookEvent(hook: .stop, sessionId: "s", tty: "/dev/ttys0", pid: 1, cwd: "/p",
                         ts: 0, promptPreview: nil, toolName: nil,
                         notificationType: nil, message: nil, backgroundTasksActive: 0)
    store.apply(idle)
    let s = store.orderedSessions.first { $0.id == "s" }
    XCTAssertEqual(s?.state, .waiting)
    XCTAssertEqual(s?.backgroundTaskCount, 0)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/SessionStoreTests/test_stopWithActiveBackgroundTasksEntersBackgroundWorkingWithCount`
Expected: FAIL — `Session` has no member `backgroundTaskCount` (compile error).

- [ ] **Step 3a: Add the property to `Session`**

In `App/Models/Session.swift`, after `lastPromptPreview`:

```swift
    var lastPromptPreview: String?  // sticks between UserPromptSubmit events
    var backgroundTaskCount: Int = 0  // active background tasks while .backgroundWorking
```

(The default `= 0` keeps the synthesized memberwise init source-compatible for existing constructors.)

- [ ] **Step 3b: Apply the count in `SessionStore`**

In `App/Core/SessionStore.swift`, in the existing-session branch, replace:

```swift
            let newState = StateMachine.transition(from: previousState, for: event.hook)
```

with:

```swift
            let activeBackground = event.backgroundTasksActive ?? 0
            let newState = StateMachine.transition(from: previousState, for: event.hook,
                                                   backgroundTasksActive: activeBackground)
```

Then, just before `orderedSessions[idx] = session`, add:

```swift
            session.backgroundTaskCount = (newState == .backgroundWorking) ? activeBackground : 0
            orderedSessions[idx] = session
```

In the new-session (`else`) branch, replace:

```swift
            let newState = StateMachine.transition(from: nil, for: event.hook)
            if newState == .finished { return }
            let session = Session(
                id: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                pid: event.pid,
                state: newState,
                enteredStateAt: clock.now(),
                lastPromptPreview: event.promptPreview
            )
```

with:

```swift
            let activeBackground = event.backgroundTasksActive ?? 0
            let newState = StateMachine.transition(from: nil, for: event.hook,
                                                   backgroundTasksActive: activeBackground)
            if newState == .finished { return }
            var session = Session(
                id: event.sessionId,
                cwd: event.cwd,
                tty: event.tty,
                pid: event.pid,
                state: newState,
                enteredStateAt: clock.now(),
                lastPromptPreview: event.promptPreview
            )
            session.backgroundTaskCount = (newState == .backgroundWorking) ? activeBackground : 0
```

(Note the `let session` → `var session` change so the count can be assigned.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/SessionStoreTests`
Expected: PASS (all SessionStoreTests).

- [ ] **Step 5: Commit**

```bash
git add App/Models/Session.swift App/Core/SessionStore.swift Tests/SessionStoreTests.swift
git commit -m "Track background task count on sessions"
```

---

### Task 6: `PushNotifier` suppresses the idle push during background work

**Files:**
- Modify: `App/Core/PushNotifier.swift`
- Test: `Tests/PushNotifierTests.swift`

**Interfaces:**
- Consumes: `HookEvent.backgroundTasksActive` (Task 1).
- Produces: no push when `event.hook == .stop && (backgroundTasksActive ?? 0) > 0`.

- [ ] **Step 1: Write the failing tests**

In `Tests/PushNotifierTests.swift`, extend the `event(...)` helper to accept the new field:

```swift
    private func event(_ hook: HookName,
                       cwd: String = "/Users/me/proj",
                       notificationType: String? = nil,
                       message: String? = nil,
                       backgroundTasksActive: Int? = nil) -> HookEvent {
        HookEvent(hook: hook, sessionId: "s", tty: "/dev/ttys000", pid: 1, cwd: cwd,
                  ts: 0, promptPreview: nil, toolName: nil,
                  notificationType: notificationType, message: message,
                  backgroundTasksActive: backgroundTasksActive)
    }
```

Add the tests:

```swift
func test_stopWithActiveBackgroundTasksDoesNotPush() async {
    preferences.prowlEnabled = true
    keychain.value = "k"
    await notifier.handleAndAwait(event(.stop, backgroundTasksActive: 2))
    XCTAssertEqual(prowl.calls.count, 0, "should not push while background tasks run")
}

func test_stopWithZeroBackgroundTasksStillPushes() async {
    preferences.prowlEnabled = true
    keychain.value = "k"
    await notifier.handleAndAwait(event(.stop, backgroundTasksActive: 0))
    XCTAssertEqual(prowl.calls.count, 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/PushNotifierTests/test_stopWithActiveBackgroundTasksDoesNotPush`
Expected: FAIL — `prowl.calls.count` is 1 (push fired).

- [ ] **Step 3: Update `PushNotifier.handle`**

In `App/Core/PushNotifier.swift`, after the existing guard:

```swift
        guard event.hook == .stop || event.hook == .notification else { return Task {} }
```

add:

```swift
        if event.hook == .stop, (event.backgroundTasksActive ?? 0) > 0 { return Task {} }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor -destination 'platform=macOS' -only-testing:ClaudeMonitorTests/PushNotifierTests`
Expected: PASS (all PushNotifierTests, including existing `test_stopProducesDoneTitle` which sends no background tasks).

- [ ] **Step 5: Commit**

```bash
git add App/Core/PushNotifier.swift Tests/PushNotifierTests.swift
git commit -m "Suppress idle push while background tasks are running"
```

---

### Task 7: UI — tile label with count + menu-bar aggregate

**Files:**
- Modify: `App/UI/TileView.swift`
- Modify: `App/UI/MenuBarController.swift`
- Test: none new (SwiftUI views exercised manually); verify `FlashCoordinator` needs no change.

**Interfaces:**
- Consumes: `Session.backgroundTaskCount` (Task 5); `SessionStateColor`/`Palette` cases (Task 3).

- [ ] **Step 1: Update the tile status line**

In `App/UI/TileView.swift`, replace:

```swift
                Text("\(session.state.displayLabel) · \(elapsed)")
```

with:

```swift
                Text(statusLine)
```

and add this computed property next to `elapsed`:

```swift
    private var statusLine: String {
        guard session.state == .backgroundWorking else {
            return "\(session.state.displayLabel) · \(elapsed)"
        }
        let n = session.backgroundTaskCount
        let unit = n == 1 ? "task" : "tasks"
        return "\(session.state.displayLabel) · \(n) \(unit) · \(elapsed)"
    }
```

- [ ] **Step 2: Update the menu-bar aggregate "winning" state**

In `App/UI/MenuBarController.swift`, after:

```swift
        let anyWorking = sessions.contains { $0.state == .working }
```

add:

```swift
        let anyBackgroundWorking = sessions.contains { $0.state == .backgroundWorking }
```

and update the winner ladder:

```swift
        if needsYou > 0    { winning = .needsYou }
        else if anyWaiting { winning = .waiting }
        else if anyWorking { winning = .working }
        else if anyBackgroundWorking { winning = .backgroundWorking }
        else               { winning = .finished } // idle → gray
```

- [ ] **Step 3: Verify `FlashCoordinator` needs no change**

Read `App/Core/FlashCoordinator.swift`. Confirm `shouldFlash` uses `if` statements (not an exhaustive `switch`), so the new case compiles without edits, and the desired behavior already holds: `working → backgroundWorking` does NOT flash (no rule matches); `backgroundWorking → waiting` DOES flash (matched by `new == .waiting`, the genuine idle moment). No code change. If you discover any exhaustive `switch` over `SessionState` elsewhere, add `case .backgroundWorking` returning the same as `.working`.

- [ ] **Step 4: Build and run the full suite**

Run: `make test`
Expected: BUILD SUCCEEDED and all tests pass.

- [ ] **Step 5: Manual smoke check**

Build & launch the app. In a real Claude Code terminal session, dispatch a background task (e.g. ask it to run `sleep 30 && echo done` in the background and end its turn), and separately dispatch a background **agent**. Confirm:
- the tile shows dimmed-blue **"Working · 1 task"** (not amber "Waiting"),
- **no** Prowl push fires while it runs,
- the tile keeps your last human prompt (not `<task-notification>` text),
- when the task completes and the agent truly idles, the tile turns amber "Waiting" and a push fires.

Per repo convention, don't race the unit-test build — run the app separately.

- [ ] **Step 6: Commit**

```bash
git add App/UI/TileView.swift App/UI/MenuBarController.swift
git commit -m "Show backgroundWorking tile with task count and menu-bar aggregate"
```

---

## Notes on residual risk

- **Background subagent `type` string** is unconfirmed (couldn't reproduce a background *agent* headlessly); the rule keys off `status`, not `type`, so it is covered regardless. Confirm in the Task 7 smoke check by dispatching a background **agent** as well as a background bash command.
- **Future schema drift**: `background_tasks` / `background_tasks_active` are optional end-to-end; their absence decodes to `nil` → count `0` → exactly today's behavior. Graceful degradation, no crash.
