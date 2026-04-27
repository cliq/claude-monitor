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
}
