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
