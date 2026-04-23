import Foundation

enum HookScriptDeployer {
    enum DeployError: Error { case bundleScriptMissing }

    /// Copy the bundled hook.sh into `<home>/.claude-monitor/hook.sh`, overwriting any existing file,
    /// and mark it executable.
    static func deploy(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundle: Bundle? = nil) throws {
        let b = bundle ?? Bundle.main
        guard let src = b.url(forResource: "hook", withExtension: "sh")
                    ?? Bundle(for: Sentinel.self).url(forResource: "hook", withExtension: "sh")
        else { throw DeployError.bundleScriptMissing }

        let destDir = home.appendingPathComponent(".claude-monitor")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("hook.sh")

        let data = try Data(contentsOf: src)
        try data.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    /// Marker class to locate the resource bundle in tests.
    private final class Sentinel {}
}
