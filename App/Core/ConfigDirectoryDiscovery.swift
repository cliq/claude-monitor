import Foundation

enum ConfigDirectoryDiscovery {
    /// Returns all directories under `home` whose name is `.claude` or `.claudewho-*`
    /// AND which contain a `settings.json`.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }

        return entries
            .filter { $0 == ".claude" || $0.hasPrefix(".claudewho-") }
            .map { home.appendingPathComponent($0) }
            .filter { dir in
                var isDir: ObjCBool = false
                let settings = dir.appendingPathComponent("settings.json").path
                return fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
                    && fm.fileExists(atPath: settings)
            }
            .sorted { $0.path < $1.path }
    }
}
