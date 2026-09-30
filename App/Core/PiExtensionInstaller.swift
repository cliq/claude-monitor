import Foundation

/// Installs Claude Monitor's pi extension into a pi agent directory
/// (`~/.pi/agent` by default). Unlike Claude Code and Codex, pi has no hook
/// config to merge into: it loads every file in `<agentDir>/extensions/`, so
/// the integration is a single file Claude Monitor owns outright. Ownership and
/// schema are read from the `claude-monitor pi-extension v<N>` header line.
enum PiExtensionInstaller {
    enum InstallError: Error, LocalizedError {
        case bundleExtensionMissing
        case notOurs(URL)

        var errorDescription: String? {
            switch self {
            case .bundleExtensionMissing:
                return "The pi extension is missing from the app bundle."
            case .notOurs(let url):
                return "\(url.path) was not written by Claude Monitor, so it was left in place."
            }
        }
    }

    /// Bump when the bundled extension changes in a way users should see as
    /// "Outdated" before the next launch-time refresh rewrites it.
    static let currentVersion = 1
    static let fileName = "claude-monitor.ts"

    static func extensionFile(in agentDir: URL) -> URL {
        agentDir.appendingPathComponent("extensions").appendingPathComponent(fileName)
    }

    static func inspect(agentDir: URL) -> HookInstaller.Status {
        guard let body = try? String(contentsOf: extensionFile(in: agentDir), encoding: .utf8) else {
            return HookInstaller.Status(status: .notInstalled, installedVersion: 0)
        }
        guard let version = version(in: body) else {
            return HookInstaller.Status(status: .modifiedExternally, installedVersion: 0)
        }
        let status: HookInstallStatus
        if version < currentVersion {
            status = .outdated
        } else if version == currentVersion {
            status = .installed
        } else {
            status = .modifiedExternally
        }
        return HookInstaller.Status(status: status, installedVersion: version)
    }

    /// Writes the bundled extension, replacing any previous copy.
    static func install(agentDir: URL, bundle: Bundle? = nil) throws {
        let data = try bundledExtension(bundle: bundle)
        let dest = extensionFile(in: agentDir)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }

    /// Removes the extension file, but only one carrying our header.
    static func uninstall(agentDir: URL) throws {
        let file = extensionFile(in: agentDir)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let body = try String(contentsOf: file, encoding: .utf8)
        guard version(in: body) != nil else { throw InstallError.notOurs(file) }
        try FileManager.default.removeItem(at: file)
    }

    /// Rewrites the extension in every directory where ours is installed, so an
    /// app update ships extension changes without a manual reinstall. Missing
    /// and foreign files are left alone. Returns the refreshed directories.
    @discardableResult
    static func refreshInstalled(agentDirs: [URL], bundle: Bundle? = nil) -> [URL] {
        agentDirs.filter { dir in
            let status = inspect(agentDir: dir).status
            guard status == .installed || status == .outdated else { return false }
            do {
                try install(agentDir: dir, bundle: bundle)
                return true
            } catch {
                NSLog("PiExtensionInstaller: failed refreshing \(dir.path) — \(error)")
                return false
            }
        }
    }

    static func version(in body: String) -> Int? {
        guard let firstLine = body.split(separator: "\n", maxSplits: 1).first,
              let range = firstLine.range(of: #"claude-monitor pi-extension v(\d+)"#,
                                          options: .regularExpression)
        else { return nil }
        let match = firstLine[range]
        return Int(match.drop(while: { !$0.isNumber }))
    }

    private static func bundledExtension(bundle: Bundle?) throws -> Data {
        let b = bundle ?? Bundle.main
        guard let src = b.url(forResource: "pi-extension", withExtension: "ts")
                    ?? Bundle(for: Sentinel.self).url(forResource: "pi-extension", withExtension: "ts")
        else { throw InstallError.bundleExtensionMissing }
        return try Data(contentsOf: src)
    }

    /// Marker class to locate the resource bundle in tests.
    private final class Sentinel {}
}
