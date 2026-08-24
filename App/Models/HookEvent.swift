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
    let backgroundTasksActive: Int?
    let provider: AgentProvider

    init(hook: HookName, sessionId: String, tty: String, pid: Int32, cwd: String,
         ts: Int, promptPreview: String?, toolName: String?,
         notificationType: String?, message: String?,
         backgroundTasksActive: Int? = nil,
         provider: AgentProvider = .claude) {
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
        self.provider = provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hook = try c.decode(HookName.self, forKey: .hook)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        tty = try c.decode(String.self, forKey: .tty)
        pid = try c.decode(Int32.self, forKey: .pid)
        cwd = try c.decode(String.self, forKey: .cwd)
        ts = try c.decode(Int.self, forKey: .ts)
        promptPreview = try c.decodeIfPresent(String.self, forKey: .promptPreview)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        backgroundTasksActive = try c.decodeIfPresent(Int.self, forKey: .backgroundTasksActive)
        // Absent for payloads from hook.sh versions that predate provider tagging.
        provider = try c.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
    }

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
        case backgroundTasksActive = "background_tasks_active"
        case provider
    }
}
