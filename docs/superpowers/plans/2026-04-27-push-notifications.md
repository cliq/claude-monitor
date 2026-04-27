# Push Notifications via Prowl — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Prowl push notifications when Claude Code fires `Stop` or `Notification` hooks, configurable via a new "Push Notifications" Settings tab, with optional offline-mode fallback that pushes via Prowl directly when the monitor app isn't running.

**Architecture:** The bundled `hook.sh` is extended to forward `notification_type` and `message` to the local app. A new `PushNotifier` consumes every `HookEvent` post-state-machine and (when enabled) calls a `ProwlClient` over `URLSession`. The API key lives in the macOS Keychain via a `KeychainStore` wrapper. Offline mode installs a separate managed hook entry pointing at `~/.claude-monitor/offline-prowl.sh`, which probes a new `/health` endpoint to silently bail when the app is up.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, `Network.framework` (existing `EventServer`), `Security.framework` (new `KeychainStore`), `Foundation.URLSession` (Prowl HTTPS), bash + python3 (offline script), XCTest.

**Reference:** [docs/superpowers/specs/2026-04-27-push-notifications-design.md](../specs/2026-04-27-push-notifications-design.md)

---

## File Structure

**New:**
- `App/Core/KeychainStore.swift` — `kSecClassGenericPassword` get/set/delete wrapper.
- `App/Core/ProwlClient.swift` — Single-method async HTTP client for `api.prowlapp.com/publicapi/add`.
- `App/Core/PushNotifier.swift` — Decides whether to push for a `HookEvent`, builds title/body, dispatches `ProwlClient.send`.
- `App/Core/OfflineHookDeployer.swift` — Renders `offline-prowl.sh` from the template and orchestrates install/uninstall across managed config dirs.
- `App/UI/NotificationsSettingsView.swift` — New "Push Notifications" tab.
- `scripts/offline-prowl.sh.template` — Bundled resource; placeholder `__PROWL_API_KEY__` is substituted at deploy time.
- `Tests/KeychainStoreTests.swift`
- `Tests/ProwlClientTests.swift`
- `Tests/PushNotifierTests.swift`
- `Tests/OfflineHookDeployerTests.swift`
- `Tests/Fixtures/settings-with-managed-offline-v1.json`
- `Tests/Fixtures/settings-with-managed-main-and-offline.json`

**Modified:**
- `App/Models/HookEvent.swift` — Adds `notificationType: String?`, `message: String?`.
- `scripts/hook.sh` — Forwards `notification_type` and `message` from Claude's stdin payload.
- `App/Settings/Preferences.swift` — Adds `prowlEnabled: Bool`, `prowlOfflineHookEnabled: Bool`.
- `App/Core/EventServer.swift` — Adds `GET /health → 200`.
- `App/Core/SessionStore.swift` — Calls `pushNotifier.handle(event:)` after state-machine transitions.
- `App/Core/HookInstaller.swift` — Adds `installOfflineHook` / `uninstallOfflineHook` / `inspectOfflineHook` paths keyed by a separate managed-by tag.
- `App/UI/SettingsView.swift` — Adds a fourth tab.
- `App/AppDelegate.swift` — Wires `KeychainStore`, `ProwlClient`, `PushNotifier` into `SessionStore`.
- `project.yml` — Bundles `scripts/offline-prowl.sh.template` as a resource for the app target.
- `Tests/HookEventTests.swift` — New cases for the additional fields.
- `Tests/EventServerTests.swift` — New case for `/health`.
- `Tests/HookInstallerTests.swift` — New cases for the offline managed entry.

---

## Task 1: Extend `HookEvent` to carry notification subtype and message

**Files:**
- Modify: `App/Models/HookEvent.swift`
- Test: `Tests/HookEventTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/HookEventTests.swift`:

```swift
    func test_decodesNotificationWithSubtypeAndMessage() throws {
        let json = """
        {
          "hook": "Notification",
          "session_id": "n1",
          "tty": "/dev/ttys001",
          "pid": 1,
          "cwd": "/work",
          "ts": 1,
          "notification_type": "permission_prompt",
          "message": "Allow Claude to read /etc/hosts?"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.hook, .notification)
        XCTAssertEqual(event.notificationType, "permission_prompt")
        XCTAssertEqual(event.message, "Allow Claude to read /etc/hosts?")
    }

    func test_decodesEventWithoutSubtypeOrMessage() throws {
        let json = """
        {"hook":"Stop","session_id":"x","tty":"/","pid":1,"cwd":"/","ts":1}
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertNil(event.notificationType)
        XCTAssertNil(event.message)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/HookEventTests
```

Expected: both new tests fail (`notificationType` and `message` properties don't exist).

- [ ] **Step 3: Add the fields to `HookEvent`**

Edit `App/Models/HookEvent.swift`:

```swift
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
    let notificationType: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case hook
        case sessionId        = "session_id"
        case tty
        case pid
        case cwd
        case ts
        case promptPreview    = "prompt_preview"
        case toolName         = "tool_name"
        case notificationType = "notification_type"
        case message
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: all `HookEventTests` pass; full suite still green.

- [ ] **Step 5: Commit**

```bash
git add App/Models/HookEvent.swift Tests/HookEventTests.swift
git commit -m "Add notification_type and message to HookEvent"
```

---

## Task 2: Forward `notification_type` and `message` from `hook.sh`

**Files:**
- Modify: `scripts/hook.sh`
- Test: `Tests/HookScriptTests.swift` (new test case)

- [ ] **Step 1: Write the failing test**

Append to `Tests/HookScriptTests.swift`:

```swift
    func test_hookScriptForwardsNotificationFields() async throws {
        let scriptURL = try XCTUnwrap(findHookScript())

        var received: [HookEvent] = []
        let expect = expectation(description: "event")
        let server = EventServer { event in
            received.append(event)
            expect.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-hooktest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpHome.appendingPathComponent(".claude-monitor"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpHome) }

        try "\(server.port!)\n".write(
            to: tmpHome.appendingPathComponent(".claude-monitor/port"),
            atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, "Notification"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmpHome.path
        proc.environment = env

        let inputPipe = Pipe()
        proc.standardInput = inputPipe
        try proc.run()
        inputPipe.fileHandleForWriting.write(#"""
        {"session_id":"s1","notification_type":"idle_prompt","message":"You there?"}
        """#.data(using: .utf8)!)
        try inputPipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        await fulfillment(of: [expect], timeout: 3)
        XCTAssertEqual(received[0].notificationType, "idle_prompt")
        XCTAssertEqual(received[0].message, "You there?")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/HookScriptTests/test_hookScriptForwardsNotificationFields
```

Expected: fails — script does not yet emit the new fields, so `notificationType`/`message` decode as nil.

- [ ] **Step 3: Extend `hook.sh`**

In `scripts/hook.sh`, replace the Python block (currently lines 35–58) with one that includes the two new fields. The full updated Python branch:

```bash
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
notif_type = src.get("notification_type")
if isinstance(notif_type, str):
    out["notification_type"] = notif_type
msg = src.get("message")
if isinstance(msg, str):
    out["message"] = msg
print(json.dumps(out))
PY
)"
```

The bash fallback (no python3) is intentionally left without the new fields — best-effort, matching how it already handles `prompt_preview`.

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Run the full hook test suite to confirm no regression**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/HookScriptTests
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/hook.sh Tests/HookScriptTests.swift
git commit -m "Forward notification_type and message from hook.sh"
```

---

## Task 3: Add `/health` endpoint to `EventServer`

**Files:**
- Modify: `App/Core/EventServer.swift`
- Test: `Tests/EventServerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/EventServerTests.swift`:

```swift
    func test_serverRespondsToHealthCheck() async throws {
        let server = EventServer { _ in }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/EventServerTests/test_serverRespondsToHealthCheck
```

Expected: fails with `405` (method not allowed) — the existing `/event`-only path rejects everything else.

- [ ] **Step 3: Add the `/health` branch**

In `App/Core/EventServer.swift`, replace the body of `respond(to:on:)` so it handles GET /health before the POST /event path:

```swift
    private func respond(to req: RawHTTPRequest, on connection: NWConnection) {
        defer { connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        }) }

        if req.method == "GET" && req.path == "/health" {
            send(status: 200, message: "OK", connection: connection)
            return
        }

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
```

- [ ] **Step 4: Run the EventServer suite**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/EventServerTests
```

Expected: all four cases pass (the existing three plus the new health check).

- [ ] **Step 5: Commit**

```bash
git add App/Core/EventServer.swift Tests/EventServerTests.swift
git commit -m "Add GET /health endpoint to EventServer for liveness probes"
```

---

## Task 4: Add Prowl preferences

**Files:**
- Modify: `App/Settings/Preferences.swift`
- Test: `Tests/PreferencesTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/PreferencesTests.swift`:

```swift
    func test_prowlPreferencesDefaultToFalseAndPersist() {
        let suiteName = "test-prowl-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        XCTAssertFalse(prefs.prowlEnabled)
        XCTAssertFalse(prefs.prowlOfflineHookEnabled)

        prefs.prowlEnabled = true
        prefs.prowlOfflineHookEnabled = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.prowlEnabled)
        XCTAssertTrue(reloaded.prowlOfflineHookEnabled)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/PreferencesTests/test_prowlPreferencesDefaultToFalseAndPersist
```

Expected: fails — properties don't exist.

- [ ] **Step 3: Add the properties**

In `App/Settings/Preferences.swift`, add inside the class (anywhere alongside the other `@Published` properties):

```swift
    @Published var prowlEnabled: Bool {
        didSet { defaults.set(prowlEnabled, forKey: Self.prowlEnabledKey) }
    }

    @Published var prowlOfflineHookEnabled: Bool {
        didSet { defaults.set(prowlOfflineHookEnabled, forKey: Self.prowlOfflineKey) }
    }
```

Add the keys to the private statics:

```swift
    private static let prowlEnabledKey  = "prowlEnabled"
    private static let prowlOfflineKey  = "prowlOfflineHookEnabled"
```

Initialize them in `init`:

```swift
        self.prowlEnabled = defaults.bool(forKey: Self.prowlEnabledKey)
        self.prowlOfflineHookEnabled = defaults.bool(forKey: Self.prowlOfflineKey)
```

- [ ] **Step 4: Run the Preferences tests**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/PreferencesTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add App/Settings/Preferences.swift Tests/PreferencesTests.swift
git commit -m "Add prowlEnabled and prowlOfflineHookEnabled preferences"
```

---

## Task 5: `KeychainStore`

**Files:**
- Create: `App/Core/KeychainStore.swift`
- Test: `Tests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/KeychainStoreTests.swift`:

```swift
import XCTest
@testable import ClaudeMonitor

final class KeychainStoreTests: XCTestCase {
    private let testService = "com.cliq.ClaudeMonitor.tests.prowl-\(UUID().uuidString)"
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        store = KeychainStore(service: testService, account: "default")
        try? store.delete()
    }

    override func tearDown() {
        try? store.delete()
        super.tearDown()
    }

    func test_returnsNilWhenNoEntryExists() throws {
        XCTAssertNil(try store.get())
    }

    func test_setAndGetRoundTrip() throws {
        try store.set("abc-123")
        XCTAssertEqual(try store.get(), "abc-123")
    }

    func test_setOverwritesExistingValue() throws {
        try store.set("first")
        try store.set("second")
        XCTAssertEqual(try store.get(), "second")
    }

    func test_deleteRemovesValue() throws {
        try store.set("to-be-deleted")
        try store.delete()
        XCTAssertNil(try store.get())
    }

    func test_deleteIsIdempotent() throws {
        try store.delete()
        XCTAssertNoThrow(try store.delete())
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/KeychainStoreTests
```

Expected: fails with "Cannot find 'KeychainStore' in scope".

- [ ] **Step 3: Implement `KeychainStore`**

Create `App/Core/KeychainStore.swift`:

```swift
import Foundation
import Security

/// Thin wrapper over Security.framework for storing one UTF-8 string per
/// (service, account) pair. Used by the Prowl integration to keep the API key
/// out of UserDefaults.
struct KeychainStore {
    enum Error: Swift.Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    let service: String
    let account: String

    func get() throws -> String? {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound: return nil
        case errSecSuccess:
            guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        default:
            throw Error.unexpectedStatus(status)
        }
    }

    func set(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Error.unexpectedStatus(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Error.unexpectedStatus(addStatus) }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.unexpectedStatus(status)
        }
    }
}

extension KeychainStore {
    /// Default store for the Prowl API key.
    static let prowl = KeychainStore(
        service: "com.cliq.ClaudeMonitor.prowl",
        account: "default"
    )
}
```

- [ ] **Step 4: Run the tests**

Same command as Step 2. Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Core/KeychainStore.swift Tests/KeychainStoreTests.swift
git commit -m "Add KeychainStore wrapper for the Prowl API key"
```

---

## Task 6: `ProwlClient`

**Files:**
- Create: `App/Core/ProwlClient.swift`
- Test: `Tests/ProwlClientTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ProwlClientTests.swift`:

```swift
import XCTest
@testable import ClaudeMonitor

final class ProwlClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
        URLProtocol.registerClass(URLProtocolStub.self)
    }
    override func tearDown() {
        URLProtocol.unregisterClass(URLProtocolStub.self)
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeClient() -> ProwlClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [URLProtocolStub.self]
        return ProwlClient(session: URLSession(configuration: cfg))
    }

    func test_sendBuildsExpectedRequest() async throws {
        URLProtocolStub.responder = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://api.prowlapp.com/publicapi/add")
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let body = String(data: URLProtocolStub.bodyOf(req) ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("apikey=KEY"))
            XCTAssertTrue(body.contains("application=Claude%20Monitor"))
            XCTAssertTrue(body.contains("event=proj%3A%20Done"))
            XCTAssertTrue(body.contains("description=Finished%20responding."))
            XCTAssertTrue(body.contains("priority=0"))
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let result = await makeClient().send(apiKey: "KEY",
                                             event: "proj: Done",
                                             description: "Finished responding.")
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    func test_send401MapsToInvalidAPIKey() async throws {
        URLProtocolStub.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.invalidAPIKey) = result else { return XCTFail("got \(result)") }
    }

    func test_send406MapsToRateLimited() async throws {
        URLProtocolStub.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 406, httpVersion: nil, headerFields: nil)!, Data())
        }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.rateLimited) = result else { return XCTFail("got \(result)") }
    }

    func test_send500MapsToHttp() async throws {
        URLProtocolStub.responder = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             "boom".data(using: .utf8)!)
        }
        let result = await makeClient().send(apiKey: "X", event: "e", description: "d")
        guard case .failure(.http(let code, let body)) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(code, 500)
        XCTAssertEqual(body, "boom")
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedBodies: [URL: Data] = [:]

    static func reset() {
        responder = nil
        capturedBodies = [:]
    }

    static func bodyOf(_ req: URLRequest) -> Data? {
        if let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }
        return req.httpBody
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let r = Self.responder else { fatalError("no responder set") }
        let (resp, data) = r(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/ProwlClientTests
```

Expected: fails with "Cannot find 'ProwlClient' in scope".

- [ ] **Step 3: Implement `ProwlClient`**

Create `App/Core/ProwlClient.swift`:

```swift
import Foundation

enum ProwlError: Error, Equatable {
    case network(URLError)
    case http(status: Int, body: String)
    case invalidAPIKey
    case rateLimited
}

/// Single-method HTTP client for `https://api.prowlapp.com/publicapi/add`.
/// All Prowl writes (real events and the Settings "Test" button) go through
/// this type so encoding and status-mapping live in one place.
struct ProwlClient {
    private static let endpoint = URL(string: "https://api.prowlapp.com/publicapi/add")!
    private static let application = "Claude Monitor"

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(apiKey: String, event: String, description: String) async -> Result<Void, ProwlError> {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded([
            "apikey":      apiKey,
            "application": Self.application,
            "event":       event,
            "description": description,
            "priority":    "0",
        ])

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200..<300:
                return .success(())
            case 401:
                return .failure(.invalidAPIKey)
            case 406:
                return .failure(.rateLimited)
            default:
                return .failure(.http(status: status, body: String(data: data, encoding: .utf8) ?? ""))
            }
        } catch let urlError as URLError {
            return .failure(.network(urlError))
        } catch {
            return .failure(.network(URLError(.unknown)))
        }
    }

    private func formEncoded(_ pairs: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let body = pairs
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .sorted()
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
```

- [ ] **Step 4: Run the tests**

Same command as Step 2. Expected: all 4 tests pass.

The test that asserts `event=proj%3A%20Done` depends on `formEncoded` sorting alphabetically, which is what the implementation does (`.sorted()` on the joined string fragments).

- [ ] **Step 5: Commit**

```bash
git add App/Core/ProwlClient.swift Tests/ProwlClientTests.swift
git commit -m "Add ProwlClient with status-code-aware error mapping"
```

---

## Task 7: `PushNotifier`

**Files:**
- Create: `App/Core/PushNotifier.swift`
- Test: `Tests/PushNotifierTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PushNotifierTests.swift`:

```swift
import XCTest
@testable import ClaudeMonitor

final class PushNotifierTests: XCTestCase {
    private var preferences: Preferences!
    private var keychain: InMemoryKey!
    private var prowl: SpyProwl!
    private var notifier: PushNotifier!

    override func setUp() {
        super.setUp()
        let suiteName = "test-pushnotifier-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        preferences = Preferences(defaults: defaults)
        keychain = InMemoryKey()
        prowl = SpyProwl()
        notifier = PushNotifier(preferences: preferences, keychainGetter: keychain.get, prowlSend: prowl.send)
    }

    private func event(_ hook: HookName,
                       cwd: String = "/Users/me/proj",
                       notificationType: String? = nil,
                       message: String? = nil) -> HookEvent {
        HookEvent(hook: hook, sessionId: "s", tty: "/dev/ttys000", pid: 1, cwd: cwd,
                  ts: 0, promptPreview: nil, toolName: nil,
                  notificationType: notificationType, message: message)
    }

    func test_doesNothingWhenMasterToggleOff() async {
        preferences.prowlEnabled = false
        keychain.value = "k"
        await notifier.handleAndAwait(event(.stop))
        XCTAssertEqual(prowl.calls.count, 0)
    }

    func test_doesNothingWhenApiKeyMissing() async {
        preferences.prowlEnabled = true
        keychain.value = nil
        await notifier.handleAndAwait(event(.stop))
        XCTAssertEqual(prowl.calls.count, 0)
    }

    func test_skipsHooksOtherThanStopAndNotification() async {
        preferences.prowlEnabled = true
        keychain.value = "k"
        await notifier.handleAndAwait(event(.sessionStart))
        await notifier.handleAndAwait(event(.userPromptSubmit))
        await notifier.handleAndAwait(event(.sessionEnd))
        XCTAssertEqual(prowl.calls.count, 0)
    }

    func test_stopProducesDoneTitle() async {
        preferences.prowlEnabled = true
        keychain.value = "k"
        await notifier.handleAndAwait(event(.stop))
        XCTAssertEqual(prowl.calls.count, 1)
        XCTAssertEqual(prowl.calls[0].event, "proj: Done")
        XCTAssertEqual(prowl.calls[0].description, "Finished responding.")
    }

    func test_notificationSubtypesProduceMatchingTitles() async {
        preferences.prowlEnabled = true
        keychain.value = "k"

        await notifier.handleAndAwait(event(.notification, notificationType: "permission_prompt", message: "OK?"))
        await notifier.handleAndAwait(event(.notification, notificationType: "idle_prompt"))
        await notifier.handleAndAwait(event(.notification, notificationType: "elicitation_dialog"))
        await notifier.handleAndAwait(event(.notification, notificationType: "weird_unknown"))
        await notifier.handleAndAwait(event(.notification, notificationType: nil))

        XCTAssertEqual(prowl.calls.map(\.event), [
            "proj: Permission needed",
            "proj: Waiting for you",
            "proj: Needs input",
            "proj: Notification",
            "proj: Notification",
        ])
    }

    func test_notificationUsesProvidedMessageOrFallback() async {
        preferences.prowlEnabled = true
        keychain.value = "k"

        await notifier.handleAndAwait(event(.notification, notificationType: "idle_prompt", message: "wake up"))
        await notifier.handleAndAwait(event(.notification, notificationType: "idle_prompt", message: nil))

        XCTAssertEqual(prowl.calls[0].description, "wake up")
        XCTAssertEqual(prowl.calls[1].description, "Claude Code sent a notification.")
    }

    func test_emptyCwdOmitsProjectPrefix() async {
        preferences.prowlEnabled = true
        keychain.value = "k"
        await notifier.handleAndAwait(event(.stop, cwd: ""))
        XCTAssertEqual(prowl.calls[0].event, "Done")
    }
}

// Tiny in-memory test doubles. PushNotifier takes a getter closure and a send
// closure to keep production code free of protocols that exist only for tests.

private final class InMemoryKey {
    var value: String?
    func get() -> String? { value }
}

private final class SpyProwl {
    struct Call { let event: String; let description: String; let key: String }
    private(set) var calls: [Call] = []
    func send(apiKey: String, event: String, description: String) async -> Result<Void, ProwlError> {
        calls.append(Call(event: event, description: description, key: apiKey))
        return .success(())
    }
}

private extension PushNotifier {
    /// Test helper — calls `handle` and waits for the dispatched send to finish.
    func handleAndAwait(_ event: HookEvent) async {
        await handle(event: event).value
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/PushNotifierTests
```

Expected: fails with "Cannot find 'PushNotifier' in scope".

- [ ] **Step 3: Implement `PushNotifier`**

Create `App/Core/PushNotifier.swift`:

```swift
import Foundation

/// Decides whether a `HookEvent` should produce a Prowl push and dispatches
/// the send. All policy lives here; transport lives in `ProwlClient`.
final class PushNotifier {
    typealias Send = (_ apiKey: String, _ event: String, _ description: String) async -> Result<Void, ProwlError>
    typealias KeyGetter = () -> String?

    private let preferences: Preferences
    private let keychainGetter: KeyGetter
    private let prowlSend: Send

    init(preferences: Preferences,
         keychainGetter: @escaping KeyGetter,
         prowlSend: @escaping Send) {
        self.preferences = preferences
        self.keychainGetter = keychainGetter
        self.prowlSend = prowlSend
    }

    /// Returns a `Task` so the caller can await dispatch in tests; production
    /// callers ignore it. Always returns immediately for events that don't
    /// trigger a push.
    @discardableResult
    func handle(event: HookEvent) -> Task<Void, Never> {
        guard preferences.prowlEnabled else { return Task {} }
        guard event.hook == .stop || event.hook == .notification else { return Task {} }
        guard let key = keychainGetter(), !key.isEmpty else {
            NSLog("PushNotifier: skipping push — Prowl API key is not configured")
            return Task {}
        }

        let title = Self.title(for: event)
        let body = Self.body(for: event)
        return Task.detached(priority: .utility) { [prowlSend] in
            let result = await prowlSend(key, title, body)
            if case .failure(let error) = result {
                NSLog("PushNotifier: Prowl send failed — \(error)")
            }
        }
    }

    static func title(for event: HookEvent) -> String {
        let project = projectName(from: event.cwd)
        let status = statusText(for: event)
        return project.isEmpty ? status : "\(project): \(status)"
    }

    static func body(for event: HookEvent) -> String {
        switch event.hook {
        case .stop:
            return "Finished responding."
        case .notification:
            return event.message ?? "Claude Code sent a notification."
        default:
            return ""
        }
    }

    private static func statusText(for event: HookEvent) -> String {
        switch event.hook {
        case .stop:
            return "Done"
        case .notification:
            switch event.notificationType {
            case "permission_prompt":  return "Permission needed"
            case "idle_prompt":        return "Waiting for you"
            case "elicitation_dialog": return "Needs input"
            default:                   return "Notification"
            }
        default:
            return ""
        }
    }

    private static func projectName(from cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        return (cwd as NSString).lastPathComponent
    }
}
```

- [ ] **Step 4: Run the tests**

Same command as Step 2. Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Core/PushNotifier.swift Tests/PushNotifierTests.swift
git commit -m "Add PushNotifier deciding when to fire Prowl pushes"
```

---

## Task 8: Wire `PushNotifier` into the event pipeline

**Files:**
- Modify: `App/Core/SessionStore.swift`
- Modify: `App/AppDelegate.swift`
- Test: `Tests/SessionStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SessionStoreTests.swift`:

```swift
    func test_applyForwardsEventToPushNotifier() {
        var captured: [HookEvent] = []
        let store = SessionStore(clock: SystemClock(), onEventApplied: { captured.append($0) })

        let event = HookEvent(hook: .stop, sessionId: "s", tty: "/dev/ttys0", pid: 1, cwd: "/p",
                              ts: 0, promptPreview: nil, toolName: nil,
                              notificationType: nil, message: nil)
        store.apply(event)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].sessionId, "s")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/SessionStoreTests/test_applyForwardsEventToPushNotifier
```

Expected: fails — `init` does not accept `onEventApplied`.

- [ ] **Step 3: Add the hook to `SessionStore`**

In `App/Core/SessionStore.swift`, replace the `init` and the end of `apply` so the store invokes a caller-provided callback for every applied event. Keep the rest of the file intact.

```swift
final class SessionStore: ObservableObject {
    @Published private(set) var orderedSessions: [Session] = []

    private let clock: Clock
    private let onEventApplied: (HookEvent) -> Void

    init(clock: Clock = SystemClock(),
         onEventApplied: @escaping (HookEvent) -> Void = { _ in }) {
        self.clock = clock
        self.onEventApplied = onEventApplied
    }

    func apply(_ event: HookEvent) {
        defer { onEventApplied(event) }
        // ... existing body unchanged ...
    }
```

(Place the existing body of `apply(_:)` inside the function after the `defer` line. The `defer` runs after every return path — including the `finished`-removed branch and the `notKnown && finished` short-circuit — which is exactly what we want.)

- [ ] **Step 4: Run the test**

Same command as Step 2. Expected: PASS. Run the full SessionStore suite to confirm no regressions:

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/SessionStoreTests
```

Expected: all pass.

- [ ] **Step 5: Wire the notifier into `AppDelegate`**

Modify `App/AppDelegate.swift`. Add a stored property:

```swift
    private var pushNotifier: PushNotifier!
```

Inside `applicationDidFinishLaunching(_:)`, after `preferences` is constructed and before `store` is used, build the notifier:

```swift
        let prowlClient = ProwlClient()
        pushNotifier = PushNotifier(
            preferences: preferences,
            keychainGetter: { try? KeychainStore.prowl.get() },
            prowlSend: prowlClient.send
        )
```

Then change the `store` instantiation line. The current declaration is `private let store = SessionStore()` (a property initializer). Replace with a `var` and assign in `applicationDidFinishLaunching` so it can capture `pushNotifier`:

In the property list at the top:

```swift
    private var store: SessionStore!
```

And in `applicationDidFinishLaunching`, after the notifier is built:

```swift
        store = SessionStore(onEventApplied: { [weak self] event in
            self?.pushNotifier.handle(event: event)
        })
```

(Place this before `server = EventServer { ... }` so the server's callback can route events to the now-existing `store`.)

- [ ] **Step 6: Run the full unit-test suite to confirm no regressions**

```bash
make test
```

Expected: all pass.

- [ ] **Step 7: Build the app to ensure the AppDelegate changes compile**

```bash
xcodebuild build -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add App/Core/SessionStore.swift App/AppDelegate.swift Tests/SessionStoreTests.swift
git commit -m "Route every applied HookEvent through PushNotifier"
```

---

## Task 9: `NotificationsSettingsView` (online configuration only)

**Files:**
- Create: `App/UI/NotificationsSettingsView.swift`
- Modify: `App/UI/SettingsView.swift`

This task implements the master toggle, the API key field, the Test button, and the "Remove key" link. The offline-mode toggle is added in Task 13.

- [ ] **Step 1: Create the view**

Create `App/UI/NotificationsSettingsView.swift`:

```swift
// App/UI/NotificationsSettingsView.swift
import SwiftUI

struct NotificationsSettingsView: View {
    @ObservedObject var preferences: Preferences

    @State private var apiKey: String = ""
    @State private var status: TestStatus = .idle
    @State private var keyExists: Bool = false

    private let keychain: KeychainStore
    private let prowl: ProwlClient

    enum TestStatus: Equatable {
        case idle
        case sending
        case success
        case failure(String)

        var label: String? {
            switch self {
            case .idle: return nil
            case .sending: return "Sending test…"
            case .success: return "Test sent ✓"
            case .failure(let msg): return msg
            }
        }
    }

    init(preferences: Preferences,
         keychain: KeychainStore = .prowl,
         prowl: ProwlClient = ProwlClient()) {
        self.preferences = preferences
        self.keychain = keychain
        self.prowl = prowl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle("Enable Prowl push notifications", isOn: $preferences.prowlEnabled)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Prowl API key").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    SecureField("Paste your API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!preferences.prowlEnabled)

                    Button("Test") { Task { await runTest() } }
                        .disabled(!preferences.prowlEnabled || apiKey.trimmingCharacters(in: .whitespaces).isEmpty || status == .sending)
                }

                if let label = status.label {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(status == .success ? .green : (status == .sending ? .secondary : .red))
                }

                Text("Get a key at prowlapp.com → Settings → API Keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if keyExists {
                    Button("Remove key", role: .destructive) { removeKey() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { loadKeyState() }
    }

    private func loadKeyState() {
        let existing = (try? keychain.get()) ?? nil
        keyExists = (existing != nil)
        apiKey = existing ?? ""
    }

    private func runTest() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        status = .sending
        do { try keychain.set(trimmed); keyExists = true }
        catch { status = .failure("Couldn't save key to Keychain (\(error)).") ; return }

        let result = await prowl.send(apiKey: trimmed,
                                      event: "ClaudeMonitor: Test ✓",
                                      description: "If you're seeing this, your API key works.")
        switch result {
        case .success:
            status = .success
        case .failure(.invalidAPIKey):
            status = .failure("Invalid API key.")
        case .failure(.rateLimited):
            status = .failure("Rate limited (1000/hr exceeded).")
        case .failure(.network(let urlErr)):
            status = .failure("Network error: \(urlErr.localizedDescription)")
        case .failure(.http(let code, _)):
            status = .failure("Prowl error (HTTP \(code)).")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if status == .success || status.label?.hasPrefix("Network error") == true || status.label == "Invalid API key." || status.label == "Rate limited (1000/hr exceeded)." {
                status = .idle
            }
        }
    }

    private func removeKey() {
        try? keychain.delete()
        apiKey = ""
        keyExists = false
        status = .idle
    }
}
```

- [ ] **Step 2: Add the new tab to `SettingsView`**

Edit `App/UI/SettingsView.swift`:

```swift
// App/UI/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            DirectoriesSettingsView(preferences: preferences)
                .frame(width: 560, height: 440)
                .tabItem { Label("Directories", systemImage: "folder") }

            AppearanceSettingsView(preferences: preferences)
                .frame(width: 560, height: 300)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            TerminalsSettingsView(preferences: preferences)
                .frame(width: 560, height: 320)
                .tabItem { Label("Terminals", systemImage: "terminal") }

            NotificationsSettingsView(preferences: preferences)
                .frame(width: 560, height: 420)
                .tabItem { Label("Push Notifications", systemImage: "bell.badge") }
        }
    }
}
```

- [ ] **Step 3: Build and verify it compiles**

```bash
xcodebuild build -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite**

```bash
make test
```

Expected: all pass.

- [ ] **Step 5: Smoke test manually**

```bash
make install
```

Open Settings (⌘,), confirm a fourth "Push Notifications" tab appears with the master toggle, key field, Test button, and "Get a key…" caption. Don't enter a real key yet.

- [ ] **Step 6: Commit**

```bash
git add App/UI/NotificationsSettingsView.swift App/UI/SettingsView.swift
git commit -m "Add Push Notifications settings tab with key field and test button"
```

---

## Task 10: Bundle the offline script template

**Files:**
- Create: `scripts/offline-prowl.sh.template`
- Modify: `project.yml`

The script must work standalone when invoked by Claude as a hook. It detects the live monitor via `/health`, exits 0 if up, otherwise parses Claude's stdin and POSTs to Prowl with the embedded API key.

- [ ] **Step 1: Create the template**

Create `scripts/offline-prowl.sh.template`:

```bash
#!/bin/bash
# claude-monitor offline Prowl hook — installed to ~/.claude-monitor/offline-prowl.sh
# when the user enables "Send pushes even when ClaudeMonitor isn't running".
# Probes the running monitor via GET /health; if the monitor responds, exits 0
# (the in-app PushNotifier is handling the event). Otherwise, parses Claude's
# stdin payload and POSTs to api.prowlapp.com directly.
# Always exits 0 so hook failures can never affect the Claude session.

set +e

# The deployer substitutes this placeholder with the real key at install time.
PROWL_API_KEY='__PROWL_API_KEY__'

PORT_FILE="$HOME/.claude-monitor/port"
if [ -f "$PORT_FILE" ]; then
  PORT="$(tr -d ' \n\r' < "$PORT_FILE")"
  if [ -n "$PORT" ]; then
    if curl -fsS -m 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
      exit 0   # monitor is up; in-app path is handling this event.
    fi
  fi
fi

STDIN_JSON="$(cat 2>/dev/null)"
[ -n "$STDIN_JSON" ] || STDIN_JSON="{}"
HOOK_NAME="${1:-unknown}"
CWD_VAL="$(pwd)"
export STDIN_JSON HOOK_NAME CWD_VAL PROWL_API_KEY

if ! command -v python3 >/dev/null 2>&1; then
  exit 0   # without python3 we can't safely parse Claude's payload.
fi

PYTHONIOENCODING=utf-8 python3 - <<'PY'
import json, os, sys
from urllib import request, parse

src = {}
try:
    src = json.loads(os.environ.get("STDIN_JSON") or "{}")
except Exception:
    pass

hook = os.environ.get("HOOK_NAME") or src.get("hook_event_name") or "Unknown"
cwd  = src.get("cwd") or os.environ.get("CWD_VAL") or ""
project = os.path.basename(cwd) if cwd else ""

if hook == "Stop":
    status = "Done"
    body   = "Finished responding."
elif hook == "Notification":
    nt = src.get("notification_type")
    status = {
        "permission_prompt":  "Permission needed",
        "idle_prompt":        "Waiting for you",
        "elicitation_dialog": "Needs input",
    }.get(nt, "Notification")
    body = src.get("message") or "Claude Code sent a notification."
else:
    sys.exit(0)   # only Stop and Notification trigger pushes.

title = f"{project}: {status}" if project else status
data  = parse.urlencode({
    "apikey":      os.environ["PROWL_API_KEY"],
    "application": "Claude Monitor",
    "event":       title,
    "description": body,
    "priority":    "0",
}).encode("utf-8")

try:
    req = request.Request("https://api.prowlapp.com/publicapi/add", data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    request.urlopen(req, timeout=5).read()
except Exception:
    pass
PY

exit 0
```

- [ ] **Step 2: Add the template to the build resources**

In `project.yml`, find the `ClaudeMonitor` target's `sources` block (around line 23) and add the template alongside the existing `scripts/hook.sh` entry. Also add it to the test target so deployer tests can find it:

```yaml
    sources:
      - path: App
      - path: scripts/hook.sh
        buildPhase: resources
      - path: scripts/offline-prowl.sh.template
        buildPhase: resources
```

And in the `ClaudeMonitorTests` target's `sources` block (around line 52):

```yaml
    sources:
      - path: Tests
      - path: scripts/hook.sh
        buildPhase: resources
      - path: scripts/offline-prowl.sh.template
        buildPhase: resources
      - path: Tests/Fixtures
        buildPhase: resources
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
make gen
```

Expected: silent success.

- [ ] **Step 4: Build to confirm the resource is bundled**

```bash
xcodebuild build -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add scripts/offline-prowl.sh.template project.yml
git commit -m "Bundle offline-prowl.sh.template for the Prowl offline hook"
```

---

## Task 11: Extend `HookInstaller` for the offline managed entry

The offline entry uses a separate managed-by tag (`claude-monitor-offline-prowl`) and points at `~/.claude-monitor/offline-prowl.sh`. It coexists with the v3 main entry and is installed/uninstalled independently.

**Files:**
- Modify: `App/Core/HookInstaller.swift`
- Test: `Tests/HookInstallerTests.swift`
- Create: `Tests/Fixtures/settings-with-managed-offline-v1.json`
- Create: `Tests/Fixtures/settings-with-managed-main-and-offline.json`

- [ ] **Step 1: Add the offline fixtures**

Create `Tests/Fixtures/settings-with-managed-offline-v1.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "_managedBy": "claude-monitor-offline-prowl",
        "_version": 1,
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude-monitor/offline-prowl.sh Stop --managed-by=claude-monitor-offline-prowl --version=1" }
        ]
      }
    ],
    "Notification": [
      {
        "_managedBy": "claude-monitor-offline-prowl",
        "_version": 1,
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude-monitor/offline-prowl.sh Notification --managed-by=claude-monitor-offline-prowl --version=1" }
        ]
      }
    ]
  }
}
```

Create `Tests/Fixtures/settings-with-managed-main-and-offline.json` by combining `settings-with-managed-v3.json` and the offline fixture above (both managed blocks present in the same file). Concretely, copy `Tests/Fixtures/settings-with-managed-v3.json`, then for each of `Stop` and `Notification`, add a second array element with the offline managed block.

- [ ] **Step 2: Write the failing tests**

Append to `Tests/HookInstallerTests.swift`:

```swift
    // MARK: Offline-prowl managed entry

    func test_inspectOfflineHookReportsNotInstalledWhenAbsent() throws {
        _ = try writeSettings("settings-with-managed-v3")
        let status = try HookInstaller.inspectOfflineHook(configDir: dir)
        XCTAssertEqual(status.status, .notInstalled)
    }

    func test_inspectOfflineHookReportsInstalledWhenPresent() throws {
        _ = try writeSettings("settings-with-managed-offline-v1")
        let status = try HookInstaller.inspectOfflineHook(configDir: dir)
        XCTAssertEqual(status.status, .installed)
        XCTAssertEqual(status.installedVersion, 1)
    }

    func test_installOfflineHookLeavesMainHookIntact() throws {
        let url = try writeSettings("settings-with-managed-v3")
        try HookInstaller.installOfflineHook(configDir: dir)

        XCTAssertEqual(try HookInstaller.inspect(configDir: dir).status, .installed,
                       "main hook entry must still be detected")
        XCTAssertEqual(try HookInstaller.inspectOfflineHook(configDir: dir).status, .installed)
        // Sanity-check the file has both managed blocks for Stop.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let stop = (json?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        XCTAssertEqual(stop.count, 2)
    }

    func test_uninstallOfflineHookLeavesMainHookIntact() throws {
        _ = try writeSettings("settings-with-managed-main-and-offline")
        try HookInstaller.uninstallOfflineHook(configDir: dir)

        XCTAssertEqual(try HookInstaller.inspect(configDir: dir).status, .installed)
        XCTAssertEqual(try HookInstaller.inspectOfflineHook(configDir: dir).status, .notInstalled)
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/HookInstallerTests
```

Expected: the four new tests fail with "no member `inspectOfflineHook`" / "no member `installOfflineHook`" / "no member `uninstallOfflineHook`".

- [ ] **Step 4: Refactor `HookInstaller` to support a second managed-block "kind"**

Edit `App/Core/HookInstaller.swift`. Add a private `Kind` configuration struct and parametrize the existing helpers, then expose new public methods for the offline kind. The existing public API (`inspect`, `install`, `uninstall`) stays unchanged in signature and behavior.

Replace the top of the enum with:

```swift
enum HookInstaller {
    static let currentVersion = 3

    private struct Kind {
        let managedValue: String
        let scriptPathMarker: String
        let scriptRelativePath: String   // e.g. ".claude-monitor/hook.sh"
        let hooks: [String]
        let currentVersion: Int
    }

    private static let mainKind = Kind(
        managedValue: "claude-monitor",
        scriptPathMarker: ".claude-monitor/hook.sh",
        scriptRelativePath: ".claude-monitor/hook.sh",
        hooks: ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"],
        currentVersion: 3
    )

    private static let offlineKind = Kind(
        managedValue: "claude-monitor-offline-prowl",
        scriptPathMarker: ".claude-monitor/offline-prowl.sh",
        scriptRelativePath: ".claude-monitor/offline-prowl.sh",
        hooks: ["Stop", "Notification"],
        currentVersion: 1
    )

    private static let managedKey = "_managedBy"
    private static let versionKey = "_version"
```

Replace the existing `inspect`, `install`, `uninstall`, and helper static methods with kind-parameterized versions plus the original public entry points and the new offline ones. Full replacement of the rest of the file:

```swift
    struct Status: Equatable {
        let status: HookInstallStatus
        let installedVersion: Int
    }

    // MARK: Public API — main hook (unchanged signatures)

    static func inspect(configDir: URL) throws -> Status {
        try inspect(configDir: configDir, kind: mainKind)
    }

    static func install(configDir: URL) throws {
        try install(configDir: configDir, kind: mainKind)
    }

    static func uninstall(configDir: URL) throws {
        try uninstall(configDir: configDir, kind: mainKind)
    }

    // MARK: Public API — offline-prowl hook

    static func inspectOfflineHook(configDir: URL) throws -> Status {
        try inspect(configDir: configDir, kind: offlineKind)
    }

    static func installOfflineHook(configDir: URL) throws {
        try install(configDir: configDir, kind: offlineKind)
    }

    static func uninstallOfflineHook(configDir: URL) throws {
        try uninstall(configDir: configDir, kind: offlineKind)
    }

    // MARK: Implementation

    private static func inspect(configDir: URL, kind: Kind) throws -> Status {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        let json = try loadJson(settingsURL)
        let hooks = (json["hooks"] as? [String: Any]) ?? [:]

        var versions: [Int] = []
        var anyMissing = false
        var anyModified = false

        for hook in kind.hooks {
            let entries = (hooks[hook] as? [[String: Any]]) ?? []
            let managed = entries.filter { isOurs($0, kind: kind) }
            if managed.isEmpty { anyMissing = true; continue }
            let expectedCmd = expectedCommand(for: hook, kind: kind)
            for entry in managed {
                let v = detectedVersion(of: entry)
                versions.append(v)
                guard v == kind.currentVersion else { continue }
                let innerHooks = (entry["hooks"] as? [[String: Any]]) ?? []
                let innerCmd = innerHooks.first?["command"] as? String
                if innerCmd != expectedCmd { anyModified = true }
            }
        }

        if anyMissing && versions.isEmpty {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        if anyMissing || anyModified {
            return Status(status: .modifiedExternally, installedVersion: versions.max() ?? 0)
        }
        let maxV = versions.max() ?? 0
        if maxV < kind.currentVersion {
            return Status(status: .outdated, installedVersion: maxV)
        }
        return Status(status: .installed, installedVersion: maxV)
    }

    private static func install(configDir: URL, kind: Kind) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        var json = (try? loadJson(settingsURL)) ?? [:]
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]

        for hook in kind.hooks {
            var entries = (hooks[hook] as? [[String: Any]]) ?? []
            entries.removeAll(where: { isOurs($0, kind: kind) })
            let command: [String: Any] = [
                "type": "command",
                "command": expectedCommand(for: hook, kind: kind),
            ]
            let managed: [String: Any] = [
                managedKey: kind.managedValue,
                versionKey: kind.currentVersion,
                "matcher": "",
                "hooks": [command],
            ]
            entries.append(managed)
            hooks[hook] = entries
        }
        json["hooks"] = hooks
        try saveJson(json, to: settingsURL)
    }

    private static func uninstall(configDir: URL, kind: Kind) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var json = try loadJson(settingsURL)
        guard var hooks = json["hooks"] as? [String: Any] else { return }

        for (key, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: { isOurs($0, kind: kind) })
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

    private static func expectedCommand(for hook: String, kind: Kind) -> String {
        "$HOME/\(kind.scriptRelativePath) \(hook) --managed-by=\(kind.managedValue) --version=\(kind.currentVersion)"
    }

    private static func isOurs(_ entry: [String: Any], kind: Kind) -> Bool {
        if entry[managedKey] as? String == kind.managedValue { return true }
        if let cmd = managedCommand(in: entry), cmd.contains(kind.scriptPathMarker) {
            // Disambiguate: the main and offline scripts share the parent dir,
            // so match on the full filename via the marker which includes it.
            return true
        }
        return false
    }

    private static func detectedVersion(of entry: [String: Any]) -> Int {
        if let cmd = managedCommand(in: entry), let v = versionArg(in: cmd) { return v }
        if let v = entry[versionKey] as? Int { return v }
        return 0
    }

    private static func managedCommand(in entry: [String: Any]) -> String? {
        if let inner = entry["hooks"] as? [[String: Any]], let cmd = inner.first?["command"] as? String {
            return cmd
        }
        return entry["command"] as? String
    }

    private static func versionArg(in command: String) -> Int? {
        guard let range = command.range(of: "--version=") else { return nil }
        let tail = command[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func loadJson(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    private static func saveJson(_ json: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            _ = try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
```

- [ ] **Step 5: Run the HookInstaller tests**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/HookInstallerTests
```

Expected: all tests pass — both the existing main-hook cases and the four new offline-hook cases.

- [ ] **Step 6: Commit**

```bash
git add App/Core/HookInstaller.swift Tests/HookInstallerTests.swift Tests/Fixtures/settings-with-managed-offline-v1.json Tests/Fixtures/settings-with-managed-main-and-offline.json
git commit -m "Support a separate managed-by tag for the offline-prowl hook entry"
```

---

## Task 12: `OfflineHookDeployer`

Renders the bundled template with the user's API key and writes it to `~/.claude-monitor/offline-prowl.sh` mode 0700. Also drives `HookInstaller.installOfflineHook` / `uninstallOfflineHook` across all managed config dirs.

**Files:**
- Create: `App/Core/OfflineHookDeployer.swift`
- Test: `Tests/OfflineHookDeployerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/OfflineHookDeployerTests.swift`:

```swift
import XCTest
@testable import ClaudeMonitor

final class OfflineHookDeployerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-offlinedeployer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func test_installWritesScriptWithEmbeddedKeyAndMode0700() throws {
        try OfflineHookDeployer.installScript(home: home, apiKey: "SECRET-KEY-123")

        let dest = home.appendingPathComponent(".claude-monitor/offline-prowl.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let contents = try String(contentsOf: dest)
        XCTAssertTrue(contents.contains("SECRET-KEY-123"))
        XCTAssertFalse(contents.contains("__PROWL_API_KEY__"),
                       "placeholder should be substituted out")

        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode, 0o700)
    }

    func test_installOverwritesPreviousScript() throws {
        try OfflineHookDeployer.installScript(home: home, apiKey: "FIRST")
        try OfflineHookDeployer.installScript(home: home, apiKey: "SECOND")

        let dest = home.appendingPathComponent(".claude-monitor/offline-prowl.sh")
        let contents = try String(contentsOf: dest)
        XCTAssertTrue(contents.contains("SECOND"))
        XCTAssertFalse(contents.contains("FIRST"))
    }

    func test_uninstallRemovesScript() throws {
        try OfflineHookDeployer.installScript(home: home, apiKey: "X")
        try OfflineHookDeployer.uninstallScript(home: home)
        let dest = home.appendingPathComponent(".claude-monitor/offline-prowl.sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func test_uninstallIsNoopWhenScriptMissing() throws {
        XCTAssertNoThrow(try OfflineHookDeployer.uninstallScript(home: home))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' \
  -only-testing:ClaudeMonitorTests/OfflineHookDeployerTests
```

Expected: fails — type doesn't exist.

- [ ] **Step 3: Implement `OfflineHookDeployer`**

Create `App/Core/OfflineHookDeployer.swift`:

```swift
import Foundation

/// Renders `offline-prowl.sh` from the bundled template with the user's API
/// key embedded, writes it to `~/.claude-monitor/offline-prowl.sh` (mode 0700),
/// and orchestrates installs/uninstalls of the matching hook entries across
/// all managed config dirs via `HookInstaller`.
enum OfflineHookDeployer {
    enum DeployError: Error { case templateMissing }

    private static let placeholder = "__PROWL_API_KEY__"
    private static let scriptRelativePath = ".claude-monitor/offline-prowl.sh"

    /// Render and write the script. Caller passes `apiKey` already trimmed.
    static func installScript(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              apiKey: String,
                              bundle: Bundle? = nil) throws {
        let template = try loadTemplate(bundle: bundle)
        let rendered = template.replacingOccurrences(of: placeholder, with: apiKey)

        let destDir = home.appendingPathComponent(".claude-monitor")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("offline-prowl.sh")

        try Data(rendered.utf8).write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dest.path)
    }

    /// Remove the rendered script. No-op when absent.
    static func uninstallScript(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let dest = home.appendingPathComponent(scriptRelativePath)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
    }

    /// Install the rendered script AND register the hook entries in every
    /// managed config dir. Errors propagate; callers should restore the
    /// preference if the call throws.
    static func enable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       configDirs: [URL],
                       apiKey: String,
                       bundle: Bundle? = nil) throws {
        try installScript(home: home, apiKey: apiKey, bundle: bundle)
        for dir in configDirs {
            try HookInstaller.installOfflineHook(configDir: dir)
        }
    }

    /// Remove the rendered script AND unregister the hook entries.
    static func disable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        configDirs: [URL]) throws {
        for dir in configDirs {
            try HookInstaller.uninstallOfflineHook(configDir: dir)
        }
        try uninstallScript(home: home)
    }

    private static func loadTemplate(bundle: Bundle?) throws -> String {
        let candidates: [Bundle] = [bundle ?? Bundle.main, Bundle(for: Sentinel.self)]
        for b in candidates {
            if let url = b.url(forResource: "offline-prowl.sh", withExtension: "template"),
               let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        throw DeployError.templateMissing
    }

    private final class Sentinel {}
}
```

- [ ] **Step 4: Run the tests**

Same command as Step 2. Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add App/Core/OfflineHookDeployer.swift Tests/OfflineHookDeployerTests.swift
git commit -m "Add OfflineHookDeployer to render and install the offline-prowl script"
```

---

## Task 13: Wire offline mode into the Settings UI and gate it on the master toggle

Adds the offline-mode toggle to `NotificationsSettingsView`, calls `OfflineHookDeployer.enable` / `.disable` on toggle changes, redeploys when the API key changes, and gates everything on the master toggle.

**Files:**
- Modify: `App/UI/NotificationsSettingsView.swift`

- [ ] **Step 1: Add the offline section to the view**

Replace the body of `NotificationsSettingsView.swift` with the version below. Most of the file from Task 9 stays; the new pieces are the `offlineSection` view, the `applyOfflineState` helper, the master-toggle observer, and a `.onChange(of: preferences.prowlEnabled)` that uninstalls the offline script when the master toggle is turned off.

```swift
// App/UI/NotificationsSettingsView.swift
import SwiftUI

struct NotificationsSettingsView: View {
    @ObservedObject var preferences: Preferences

    @State private var apiKey: String = ""
    @State private var status: TestStatus = .idle
    @State private var keyExists: Bool = false
    @State private var offlineError: String?

    private let keychain: KeychainStore
    private let prowl: ProwlClient

    enum TestStatus: Equatable {
        case idle
        case sending
        case success
        case failure(String)

        var label: String? {
            switch self {
            case .idle: return nil
            case .sending: return "Sending test…"
            case .success: return "Test sent ✓"
            case .failure(let msg): return msg
            }
        }
    }

    init(preferences: Preferences,
         keychain: KeychainStore = .prowl,
         prowl: ProwlClient = ProwlClient()) {
        self.preferences = preferences
        self.keychain = keychain
        self.prowl = prowl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle("Enable Prowl push notifications", isOn: $preferences.prowlEnabled)
                .font(.headline)
                .onChange(of: preferences.prowlEnabled) { _, newValue in
                    if !newValue { disableOfflineForGate() }
                    else if preferences.prowlOfflineHookEnabled, let key = currentKey() {
                        applyOfflineState(enable: true, apiKey: key)
                    }
                }

            keySection
                .disabled(!preferences.prowlEnabled)

            Divider()

            offlineSection
                .disabled(!preferences.prowlEnabled || !keyExists)

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { loadKeyState() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var keySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prowl API key").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                SecureField("Paste your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Button("Test") { Task { await runTest() } }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || status == .sending)
            }

            if let label = status.label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(status == .success ? .green : (status == .sending ? .secondary : .red))
            }

            Text("Get a key at prowlapp.com → Settings → API Keys.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if keyExists {
                Button("Remove key", role: .destructive) { removeKey() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Send pushes even when ClaudeMonitor isn't running",
                   isOn: $preferences.prowlOfflineHookEnabled)
                .onChange(of: preferences.prowlOfflineHookEnabled) { _, newValue in
                    guard preferences.prowlEnabled, let key = currentKey() else {
                        if newValue && currentKey() == nil {
                            offlineError = "Enter and save your Prowl API key first."
                            preferences.prowlOfflineHookEnabled = false
                        }
                        return
                    }
                    applyOfflineState(enable: newValue, apiKey: key)
                }

            if preferences.prowlOfflineHookEnabled {
                Text("⚠ This stores your Prowl API key in plain text in ~/.claude-monitor/offline-prowl.sh. Anyone with read access to your home folder can read it. The monitor app keeps the key in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = offlineError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func loadKeyState() {
        let existing = (try? keychain.get()) ?? nil
        keyExists = (existing != nil)
        apiKey = existing ?? ""
    }

    private func currentKey() -> String? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return (try? keychain.get()) ?? nil
    }

    private func runTest() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        status = .sending
        do {
            try keychain.set(trimmed)
            keyExists = true
        } catch {
            status = .failure("Couldn't save key to Keychain (\(error)).")
            return
        }

        if preferences.prowlOfflineHookEnabled {
            applyOfflineState(enable: true, apiKey: trimmed)
        }

        let result = await prowl.send(apiKey: trimmed,
                                      event: "ClaudeMonitor: Test ✓",
                                      description: "If you're seeing this, your API key works.")
        switch result {
        case .success:                         status = .success
        case .failure(.invalidAPIKey):         status = .failure("Invalid API key.")
        case .failure(.rateLimited):           status = .failure("Rate limited (1000/hr exceeded).")
        case .failure(.network(let urlErr)):   status = .failure("Network error: \(urlErr.localizedDescription)")
        case .failure(.http(let code, _)):     status = .failure("Prowl error (HTTP \(code)).")
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            status = .idle
        }
    }

    private func removeKey() {
        try? keychain.delete()
        apiKey = ""
        keyExists = false
        status = .idle
        if preferences.prowlOfflineHookEnabled {
            preferences.prowlOfflineHookEnabled = false
            applyOfflineState(enable: false, apiKey: "")
        }
    }

    private func disableOfflineForGate() {
        // Master toggle was turned off — uninstall the offline script even if
        // the user previously had offline mode on. The preference itself is
        // preserved so re-enabling the master toggle restores the behavior.
        guard preferences.prowlOfflineHookEnabled else { return }
        applyOfflineState(enable: false, apiKey: "", preserveOfflinePref: true)
    }

    private func applyOfflineState(enable: Bool, apiKey: String, preserveOfflinePref: Bool = false) {
        offlineError = nil
        let configDirs = preferences.managedConfigDirectoryPaths
            .map { URL(fileURLWithPath: $0) }
        do {
            if enable {
                try OfflineHookDeployer.enable(configDirs: configDirs, apiKey: apiKey)
            } else {
                try OfflineHookDeployer.disable(configDirs: configDirs)
            }
        } catch {
            offlineError = "Couldn't update offline hook: \(error.localizedDescription)"
            if !preserveOfflinePref {
                preferences.prowlOfflineHookEnabled = false
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify it compiles**

```bash
xcodebuild build -project ClaudeMonitor.xcodeproj -scheme ClaudeMonitor \
  -destination 'platform=macOS' -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite**

```bash
make test
```

Expected: all pass.

- [ ] **Step 4: Manual smoke test**

```bash
make install
```

In Settings → Push Notifications:
- Master toggle off → key field, Test, offline toggle all disabled.
- Master toggle on, no key → offline toggle disabled.
- Enter a real key, click Test → "Test sent ✓"; phone gets a push.
- Toggle offline mode on → warning text appears in orange; `~/.claude-monitor/offline-prowl.sh` exists with the key inside; managed `Stop`/`Notification` blocks for `claude-monitor-offline-prowl` appear in `~/.claude/settings.json`.
- Toggle offline mode off → script gone; managed offline blocks gone.
- Enable offline mode, then turn the master toggle off → script gone again, but `prowlOfflineHookEnabled` is still `true` in `defaults read $PRODUCT_BUNDLE_IDENTIFIER`. Re-enable master toggle → script reinstalls.

- [ ] **Step 5: Commit**

```bash
git add App/UI/NotificationsSettingsView.swift
git commit -m "Wire offline mode toggle into the Push Notifications tab"
```

---

## Task 14: Manual end-to-end verification

This task has no code — it walks the manual checklist from the spec to confirm the feature works against real Claude Code sessions and the real Prowl API.

- [ ] **Step 1: Set a real Prowl key and send a test push**

In Settings → Push Notifications, paste the user's Prowl API key (the one from `~/.claude/claude-prowl.sh`, currently `4ddd8b084767d9c5e8c0d42004312e090089f186`). Click Test. Confirm "Test sent ✓" appears and the phone receives a "ClaudeMonitor: Test ✓" push.

- [ ] **Step 2: Trigger a real Claude `Notification` and `Stop`**

In a Claude Code session in any monitored project, run any prompt that requires permission (e.g. one that triggers a tool-use prompt) — phone should receive `<project>: Permission needed` with the underlying message as the body. Wait for the response to finish — phone should receive `<project>: Done` with body `Finished responding.`. Confirm exactly one push per event.

- [ ] **Step 3: Quit the app, fire an event with offline mode OFF**

`pkill -x ClaudeMonitor`, then run a Claude prompt. Confirm no push arrives.

- [ ] **Step 4: Quit the app, fire an event with offline mode ON**

Re-launch ClaudeMonitor, enable offline mode, quit again, run a Claude prompt. Confirm a push arrives (sent by `~/.claude-monitor/offline-prowl.sh`).

- [ ] **Step 5: Re-launch the app while offline mode is on, fire an event**

Re-launch ClaudeMonitor (offline mode still on). Run a Claude prompt. Confirm exactly one push arrives — the in-app `PushNotifier` should have handled it, and the offline script's `/health` probe should have caused it to exit silently.

- [ ] **Step 6: Disable offline mode**

Toggle offline mode off in Settings. Confirm:
- `~/.claude-monitor/offline-prowl.sh` is gone (`ls ~/.claude-monitor/`).
- `~/.claude/settings.json` no longer contains entries with `--managed-by=claude-monitor-offline-prowl`.

- [ ] **Step 7: Change the API key while offline mode is on**

Enable offline mode, then enter a new key in the field and click Test. Confirm the script at `~/.claude-monitor/offline-prowl.sh` contains the new key.

- [ ] **Step 8: Click "Remove key"**

Confirm field clears, "Remove key" link disappears, offline mode toggle disables itself, and (if it was on) the offline script is uninstalled.

- [ ] **Step 9: If everything passes, push the branch and open a PR**

```bash
git push -u origin push-notifications
gh pr create --title "Push notifications via Prowl" --body "$(cat docs/superpowers/specs/2026-04-27-push-notifications-design.md | head -40)

See full spec at docs/superpowers/specs/2026-04-27-push-notifications-design.md and plan at docs/superpowers/plans/2026-04-27-push-notifications.md."
```

(Skip the PR creation if the user prefers to merge locally.)
