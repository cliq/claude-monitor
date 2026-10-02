// App/Models/AgentProvider.swift
import Foundation

/// Which agent CLI a session/event came from. Events that omit the field are
/// Claude Code's — the deployed hook.sh predates provider tagging, so absence
/// must keep decoding as `.claude`. `kimi` and `zcode` only report usage
/// limits (no session hooks). Raw values are wire schema (usage snapshot,
/// ESP32 bridge, iOS `/panel`) — never rename them.
enum AgentProvider: String, Codable, Equatable {
    case claude
    case codex
    case pi
    case kimi
    case zcode

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .pi:     return "Pi"
        case .kimi:   return "Kimi"
        case .zcode:  return "ZCode"
        }
    }
}
