import Foundation

enum ConfigDirectoryDiscovery {
    /// Returns all directories under `home` whose name is `.claude` or `.claudewho-*`
    /// AND which contain a `settings.json`.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        scan(home: home, names: { $0 == ".claude" || $0.hasPrefix(".claudewho-") },
             markerFiles: ["settings.json"])
    }

    /// Returns all directories under `home` whose name is `.codex` or `.codexwho-*`
    /// AND which look like a Codex home (`config.toml` or `auth.json` inside — Codex
    /// dirs have no settings.json). Kept separate from `scan()` on purpose: Claude-only
    /// consumers such as `UsageAccountConfig` must never see Codex directories.
    static func scanCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        scan(home: home, names: { $0 == ".codex" || $0.hasPrefix(".codexwho-") },
             markerFiles: ["config.toml", "auth.json"])
    }

    private static func scan(home: URL, names: (String) -> Bool, markerFiles: [String]) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }

        return entries
            .filter(names)
            .map { home.appendingPathComponent($0) }
            .filter { dir in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                    return false
                }
                return markerFiles.contains { marker in
                    fm.fileExists(atPath: dir.appendingPathComponent(marker).path)
                }
            }
            .sorted { $0.path < $1.path }
    }
}
