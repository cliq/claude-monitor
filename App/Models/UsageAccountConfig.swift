import Foundation

/// One agent-CLI login to poll usage for: a provider, a config directory, and
/// the short name shown on the dashboard/panel. Derived from
/// `ConfigDirectoryDiscovery` rather than configured by hand.
struct UsageAccountConfig: Identifiable, Equatable, Sendable {
    let provider: AgentProvider
    let name: String
    let configDir: String
    /// Whether this account is included in the snapshot served to external
    /// displays (widget, LAN bridge / ESP32). The panel always shows every
    /// polled account regardless.
    let showOnExternalDisplays: Bool

    /// Provider-qualified so a Claude and a Codex account with the same
    /// display name never collide. Preferences stay keyed by `configDir`
    /// alone — those paths are already distinct across providers.
    var id: String { "\(provider.rawValue):\(configDir)" }

    init(provider: AgentProvider = .claude, name: String, configDir: String,
         showOnExternalDisplays: Bool = true) {
        self.provider = provider
        self.name = name
        self.configDir = configDir
        self.showOnExternalDisplays = showOnExternalDisplays
    }

    /// `.claudewho-personal` → "personal", `.claude` → "claude",
    /// `.codexwho-work` → "work", `.codex` → "codex".
    static func accountName(forDirectoryNamed dirName: String) -> String {
        for (prefix, fallback) in [(".claudewho-", "claude"), (".codexwho-", "codex")] {
            if dirName.hasPrefix(prefix) {
                let suffix = String(dirName.dropFirst(prefix.count))
                return suffix.isEmpty ? fallback : suffix
            }
        }
        return String(dirName.drop(while: { $0 == "." }))
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [UsageAccountConfig] {
        let claude = ConfigDirectoryDiscovery.scan(home: home).map { dir in
            UsageAccountConfig(provider: .claude,
                               name: accountName(forDirectoryNamed: dir.lastPathComponent),
                               configDir: dir.path)
        }
        let codex = ConfigDirectoryDiscovery.scanCodex(home: home).map { dir in
            UsageAccountConfig(provider: .codex,
                               name: accountName(forDirectoryNamed: dir.lastPathComponent),
                               configDir: dir.path)
        }
        return claude + codex
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
    /// ordered, minus disabled accounts, with custom names applied and each
    /// account flagged for external displays unless its dir is in
    /// `externalHiddenDirs`. Blank or whitespace-only custom names fall back
    /// to the derived name.
    static func resolve(discovered: [UsageAccountConfig],
                        order: [String],
                        disabledDirs: Set<String>,
                        customNames: [String: String],
                        externalHiddenDirs: Set<String> = []) -> [UsageAccountConfig] {
        ordered(discovered: discovered, order: order)
            .filter { !disabledDirs.contains($0.configDir) }
            .map { account in
                let custom = customNames[account.configDir]?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                return UsageAccountConfig(provider: account.provider,
                                          name: custom.isEmpty ? account.name : custom,
                                          configDir: account.configDir,
                                          showOnExternalDisplays: !externalHiddenDirs.contains(account.configDir))
            }
    }
}
