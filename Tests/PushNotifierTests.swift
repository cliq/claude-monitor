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
    func send(apiKey: String, event: String, description: String) async -> Result<Void, ProwlClient.Error> {
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
