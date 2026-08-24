// App/Models/AgentProvider.swift
import Foundation

/// Which agent CLI a session/event came from. Events that omit the field are
/// Claude Code's — the deployed hook.sh predates provider tagging, so absence
/// must keep decoding as `.claude`.
enum AgentProvider: String, Codable, Equatable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}
