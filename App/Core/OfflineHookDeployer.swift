import Foundation

/// Renders `offline-prowl.sh` from the bundled template with the user's API
/// key embedded, writes it to `~/.claude-monitor/offline-prowl.sh` (mode 0700),
/// and orchestrates installs/uninstalls of the matching hook entries across
/// all managed config dirs via `HookInstaller`.
enum OfflineHookDeployer {
    enum DeployError: Error { case templateMissing }

    private static let placeholder = "__PROWL_API_KEY__"
    private static let scriptRelativePath = ".claude-monitor/offline-prowl.sh"

    /// Render and write the script. Caller passes `apiKey` already trimmed.
    static func installScript(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              apiKey: String,
                              bundle: Bundle? = nil) throws {
        let template = try loadTemplate(bundle: bundle)
        let rendered = template.replacingOccurrences(of: placeholder, with: apiKey)

        let destDir = home.appendingPathComponent(".claude-monitor")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("offline-prowl.sh")

        try Data(rendered.utf8).write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dest.path)
    }

    /// Remove the rendered script. No-op when absent.
    static func uninstallScript(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let dest = home.appendingPathComponent(scriptRelativePath)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
    }

    /// Install the rendered script AND register the hook entries in every
    /// managed config dir. Errors propagate; callers should restore the
    /// preference if the call throws.
    static func enable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       configDirs: [URL],
                       apiKey: String,
                       bundle: Bundle? = nil) throws {
        try installScript(home: home, apiKey: apiKey, bundle: bundle)
        for dir in configDirs {
            try HookInstaller.installOfflineHook(configDir: dir)
        }
    }

    /// Remove the rendered script AND unregister the hook entries.
    static func disable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        configDirs: [URL]) throws {
        for dir in configDirs {
            try HookInstaller.uninstallOfflineHook(configDir: dir)
        }
        try uninstallScript(home: home)
    }

    private static func loadTemplate(bundle: Bundle?) throws -> String {
        let candidates: [Bundle] = [bundle ?? Bundle.main, Bundle(for: Sentinel.self)]
        for b in candidates {
            if let url = b.url(forResource: "offline-prowl.sh", withExtension: "template"),
               let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        throw DeployError.templateMissing
    }

    private final class Sentinel {}
}
