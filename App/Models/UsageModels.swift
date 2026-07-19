import Foundation

/// One Claude Code login to poll usage for: a config directory plus the short
/// name shown on the dashboard/panel. Derived from `ConfigDirectoryDiscovery`
/// rather than configured by hand.
struct UsageAccountConfig: Identifiable, Equatable {
    let name: String
    let configDir: String
    var id: String { configDir }

    /// `.claudewho-personal` → "personal", `.claude` → "claude".
    static func accountName(forDirectoryNamed dirName: String) -> String {
        if dirName.hasPrefix(".claudewho-") {
            let suffix = String(dirName.dropFirst(".claudewho-".count))
            return suffix.isEmpty ? "claude" : suffix
        }
        return String(dirName.drop(while: { $0 == "." }))
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [UsageAccountConfig] {
        ConfigDirectoryDiscovery.scan(home: home).map { dir in
            UsageAccountConfig(name: accountName(forDirectoryNamed: dir.lastPathComponent),
                               configDir: dir.path)
        }
    }
}

/// Display-ready usage for one account. Field names match the JSON the ESP32
/// firmware expects (same schema the original Python bridge served).
struct AccountUsage: Codable, Identifiable, Equatable {
    var name: String
    var status: String // "ok" | "error" | "pending"
    var plan: String = ""
    var sessionPct: Int = -1
    var sessionResets: String = ""
    var weeklyPct: Int = 0
    var weeklyResets: String = ""
    var modelPct: Int = -1
    var modelResets: String = ""
    var modelLabel: String = ""
    var error: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, status, plan, error
        case sessionPct = "session_pct"
        case sessionResets = "session_resets"
        case weeklyPct = "weekly_pct"
        case weeklyResets = "weekly_resets"
        case modelPct = "model_pct"
        case modelResets = "model_resets"
        case modelLabel = "model_label"
    }
}

struct UsageSnapshot: Codable {
    var updatedAt: String?
    var accounts: [AccountUsage]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case accounts
    }
}

/// Stored OAuth credentials as Claude Code keeps them in the Keychain.
struct ClaudeOAuth {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double // unix ms
    var subscriptionType: String?
}
