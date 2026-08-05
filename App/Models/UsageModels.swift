import Foundation

/// Display-ready usage for one account. Field names match the JSON the ESP32
/// firmware expects (same schema the original Python bridge served).
struct AccountUsage: Codable, Identifiable, Equatable, Hashable {
    var name: String
    var status: String // "ok" | "error" | "pending"
    var plan: String = ""
    var sessionPct: Int = -1
    var sessionResets: String = ""
    var sessionResetsAt: String?
    var weeklyPct: Int = 0
    var weeklyResets: String = ""
    var weeklyResetsAt: String?
    var modelPct: Int = -1
    var modelResets: String = ""
    var modelResetsAt: String?
    var modelLabel: String = ""
    var error: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, status, plan, error
        case sessionPct = "session_pct"
        case sessionResets = "session_resets"
        case sessionResetsAt = "session_resets_at"
        case weeklyPct = "weekly_pct"
        case weeklyResets = "weekly_resets"
        case weeklyResetsAt = "weekly_resets_at"
        case modelPct = "model_pct"
        case modelResets = "model_resets"
        case modelResetsAt = "model_resets_at"
        case modelLabel = "model_label"
    }
}

struct UsageSnapshot: Codable {
    var updatedAt: String?
    var accounts: [AccountUsage]
    var schemaVersion: Int = 1

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case accounts
        case schemaVersion = "schema_version"
    }

    init(updatedAt: String?, accounts: [AccountUsage], schemaVersion: Int = 1) {
        self.updatedAt = updatedAt
        self.accounts = accounts
        self.schemaVersion = schemaVersion
    }

    // Custom decode so JSON written before `schema_version` existed still
    // decodes (falls back to 1). `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        accounts = try container.decode([AccountUsage].self, forKey: .accounts)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}
