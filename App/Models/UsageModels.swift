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

    /// Discovered accounts in the user's preferred order: dirs present in
    /// `order` first (in that order), newly discovered dirs appended after in
    /// discovery order. Disabled accounts are kept — Settings still lists them.
    static func ordered(discovered: [UsageAccountConfig], order: [String]) -> [UsageAccountConfig] {
        let known = order.compactMap { dir in discovered.first { $0.configDir == dir } }
        let new = discovered.filter { !order.contains($0.configDir) }
        return known + new
    }

    /// The list the poller (and thus the panel and the ESP32) actually uses:
    /// ordered, minus disabled accounts, with custom names applied. Blank or
    /// whitespace-only custom names fall back to the derived name.
    static func resolve(discovered: [UsageAccountConfig],
                        order: [String],
                        disabledDirs: Set<String>,
                        customNames: [String: String]) -> [UsageAccountConfig] {
        ordered(discovered: discovered, order: order)
            .filter { !disabledDirs.contains($0.configDir) }
            .map { account in
                let custom = customNames[account.configDir]?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                return custom.isEmpty ? account
                    : UsageAccountConfig(name: custom, configDir: account.configDir)
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
