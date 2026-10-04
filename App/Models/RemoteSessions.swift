// App/Models/RemoteSessions.swift
import Foundation

/// One dashboard session as the LAN bridge serves it (`GET /sessions`) to the
/// iOS app. A wire DTO rather than `Session` itself: ttys, transcript paths and
/// task ids stay on the Mac, and dates travel as ISO 8601 strings like the
/// usage snapshot. Keys are snake_case wire schema — additive changes only.
struct RemoteSession: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var provider: AgentProvider = .claude
    var project: String
    var cwd: String
    var state: SessionState
    var enteredStateAt: String
    var promptPreview: String?
    var backgroundTaskCount: Int = 0
    /// Chauffeur's `chauffeur[-debug]://session/<project>/<session>` deep link
    /// for sessions it hosts, read from the agent process's environment on the
    /// Mac. The Chauffeur iPhone app registers the same scheme.
    var chauffeurURL: String?

    enum CodingKeys: String, CodingKey {
        case id, provider, project, cwd, state
        case enteredStateAt = "entered_state_at"
        case promptPreview = "prompt_preview"
        case backgroundTaskCount = "background_task_count"
        case chauffeurURL = "chauffeur_url"
    }

    init(id: String, provider: AgentProvider = .claude, project: String, cwd: String,
         state: SessionState, enteredStateAt: String, promptPreview: String? = nil,
         backgroundTaskCount: Int = 0, chauffeurURL: String? = nil) {
        self.id = id
        self.provider = provider
        self.project = project
        self.cwd = cwd
        self.state = state
        self.enteredStateAt = enteredStateAt
        self.promptPreview = promptPreview
        self.backgroundTaskCount = backgroundTaskCount
        self.chauffeurURL = chauffeurURL
    }

    // Custom decode so a Mac that grows a new provider or state doesn't break
    // older phones. `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let rawProvider = try c.decodeIfPresent(String.self, forKey: .provider)
        provider = rawProvider.flatMap(AgentProvider.init(rawValue:)) ?? .claude
        project = try c.decode(String.self, forKey: .project)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        let rawState = try c.decode(String.self, forKey: .state)
        state = SessionState(rawValue: rawState) ?? .waiting
        enteredStateAt = try c.decode(String.self, forKey: .enteredStateAt)
        promptPreview = try c.decodeIfPresent(String.self, forKey: .promptPreview)
        backgroundTaskCount = try c.decodeIfPresent(Int.self, forKey: .backgroundTaskCount) ?? 0
        chauffeurURL = try c.decodeIfPresent(String.self, forKey: .chauffeurURL)
    }

    var enteredStateDate: Date? { ISO8601DateFormatter().date(from: enteredStateAt) }

    /// The tile's status line, as the Mac's `TileView` words it.
    func statusLine(elapsed: TimeInterval) -> String {
        let secs = max(0, Int(elapsed))
        let clock = String(format: "%d:%02d", secs / 60, secs % 60)
        guard state == .backgroundWorking else { return "\(state.displayLabel) · \(clock)" }
        let unit = backgroundTaskCount == 1 ? "task" : "tasks"
        return "\(state.displayLabel) · \(backgroundTaskCount) \(unit) · \(clock)"
    }

    /// The Chauffeur deep link, only when it is one of Chauffeur's session
    /// links — a tampered or unexpected value never becomes an openable URL.
    var chauffeurSessionURL: URL? {
        guard let raw = chauffeurURL, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), Self.chauffeurSchemes.contains(scheme),
              url.host?.lowercased() == "session" else { return nil }
        return url
    }

    /// Release and debug Chauffeur builds. Mirrors `ChauffeurProvider.acceptedSchemes`
    /// and `LSApplicationQueriesSchemes` in the iOS Info.plist.
    static let chauffeurSchemes: Set<String> = ["chauffeur", "chauffeur-debug"]
}

/// `GET /sessions` body: the dashboard's visible sessions in dashboard order.
/// `generated_at` lets the phone correct elapsed times for clock skew.
struct SessionsSnapshot: Codable, Equatable {
    var generatedAt: String
    var sessions: [RemoteSession]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case sessions
    }
}
