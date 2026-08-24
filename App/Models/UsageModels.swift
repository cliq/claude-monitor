import Foundation

/// One metered limit for display: a rate-limit window or a spend-control
/// allowance. The `metrics` array on `AccountUsage` is the authoritative list
/// for native UI (panel/widget); the flat `session_*`/`weekly_*`/`model_*`
/// fields remain as an adapter for the ESP32 firmware and old snapshots.
struct UsageMetric: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var usedPct: Int
    var resets: String = ""
    var resetsAt: String?
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case id, label, resets, detail
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
    }
}

/// Display-ready usage for one account. Field names match the JSON the ESP32
/// firmware expects (same schema the original Python bridge served) — never
/// rename or remove keys; additive changes only.
struct AccountUsage: Codable, Identifiable, Equatable, Hashable {
    var provider: AgentProvider = .claude
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
    var metrics: [UsageMetric] = []
    var error: String?

    /// Provider-qualified so a Claude and a Codex account sharing a display
    /// name never collide in SwiftUI lists. Not part of the wire schema.
    var id: String { "\(provider.rawValue):\(name)" }

    /// What the panel/widget render: `metrics` when populated (Codex), else
    /// the legacy three-slot layout (Claude accounts and schema-v1 snapshots).
    var displayMetrics: [UsageMetric] {
        if !metrics.isEmpty { return metrics }
        return [
            UsageMetric(id: "session", label: "SESSION", usedPct: sessionPct,
                        resets: sessionResets, resetsAt: sessionResetsAt),
            UsageMetric(id: "weekly", label: "WEEKLY", usedPct: weeklyPct,
                        resets: weeklyResets, resetsAt: weeklyResetsAt),
            UsageMetric(id: "model", label: modelLabel.isEmpty ? "MODEL" : modelLabel,
                        usedPct: modelPct, resets: modelResets, resetsAt: modelResetsAt),
        ]
    }

    enum CodingKeys: String, CodingKey {
        case name, status, plan, error, provider, metrics
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

    init(provider: AgentProvider = .claude,
         name: String,
         status: String,
         plan: String = "",
         sessionPct: Int = -1,
         sessionResets: String = "",
         sessionResetsAt: String? = nil,
         weeklyPct: Int = 0,
         weeklyResets: String = "",
         weeklyResetsAt: String? = nil,
         modelPct: Int = -1,
         modelResets: String = "",
         modelResetsAt: String? = nil,
         modelLabel: String = "",
         metrics: [UsageMetric] = [],
         error: String? = nil) {
        self.provider = provider
        self.name = name
        self.status = status
        self.plan = plan
        self.sessionPct = sessionPct
        self.sessionResets = sessionResets
        self.sessionResetsAt = sessionResetsAt
        self.weeklyPct = weeklyPct
        self.weeklyResets = weeklyResets
        self.weeklyResetsAt = weeklyResetsAt
        self.modelPct = modelPct
        self.modelResets = modelResets
        self.modelResetsAt = modelResetsAt
        self.modelLabel = modelLabel
        self.metrics = metrics
        self.error = error
    }

    // Custom decode so schema-v1 payloads (no provider/metrics) and unknown
    // future providers keep decoding. `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawProvider = try c.decodeIfPresent(String.self, forKey: .provider)
        provider = rawProvider.flatMap(AgentProvider.init(rawValue:)) ?? .claude
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? ""
        sessionPct = try c.decodeIfPresent(Int.self, forKey: .sessionPct) ?? -1
        sessionResets = try c.decodeIfPresent(String.self, forKey: .sessionResets) ?? ""
        sessionResetsAt = try c.decodeIfPresent(String.self, forKey: .sessionResetsAt)
        weeklyPct = try c.decodeIfPresent(Int.self, forKey: .weeklyPct) ?? 0
        weeklyResets = try c.decodeIfPresent(String.self, forKey: .weeklyResets) ?? ""
        weeklyResetsAt = try c.decodeIfPresent(String.self, forKey: .weeklyResetsAt)
        modelPct = try c.decodeIfPresent(Int.self, forKey: .modelPct) ?? -1
        modelResets = try c.decodeIfPresent(String.self, forKey: .modelResets) ?? ""
        modelResetsAt = try c.decodeIfPresent(String.self, forKey: .modelResetsAt)
        modelLabel = try c.decodeIfPresent(String.self, forKey: .modelLabel) ?? ""
        metrics = try c.decodeIfPresent([UsageMetric].self, forKey: .metrics) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

struct UsageSnapshot: Codable {
    /// v2 added `provider` and `metrics` on accounts (additive — every v1 key
    /// is still written with the same meaning).
    static let currentSchemaVersion = 2

    var updatedAt: String?
    var accounts: [AccountUsage]
    var schemaVersion: Int = UsageSnapshot.currentSchemaVersion

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case accounts
        case schemaVersion = "schema_version"
    }

    init(updatedAt: String?, accounts: [AccountUsage], schemaVersion: Int = UsageSnapshot.currentSchemaVersion) {
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
