import Foundation

/// Decides whether a `HookEvent` should produce a Prowl push and dispatches
/// the send. All policy lives here; transport lives in `ProwlClient`.
final class PushNotifier {
    typealias Send = (_ apiKey: String, _ event: String, _ description: String) async -> Result<Void, ProwlClient.Error>
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

    private static func title(for event: HookEvent) -> String {
        let project = projectName(from: event.cwd)
        let status = statusText(for: event)
        return project.isEmpty ? status : "\(project): \(status)"
    }

    private static func body(for event: HookEvent) -> String {
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
