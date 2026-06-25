import Foundation

/// Keeps the on-disk hook integration current across app updates. The actual
/// deployment/install work lives in `HookScriptDeployer` and `HookInstaller`;
/// this type owns the *policy* of when and which managed entries to refresh so
/// the decision is unit-testable without touching the filesystem.
enum HookMaintenance {
    /// The running app's build number (`CFBundleVersion`).
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    /// True when the app's build differs from the build we last refreshed hooks
    /// for — i.e. the app was updated, or this is the first launch that records a
    /// build. Gating on this means we only rewrite user config on an actual update.
    static func needsRefresh(currentBuild: String, lastBuild: String?) -> Bool {
        currentBuild != (lastBuild ?? "")
    }

    /// Reinstall the managed hook block in every already-managed directory whose
    /// installed schema is `.outdated`. Only the directories passed in are touched
    /// (callers pass the user's managed list), so new directories are never
    /// auto-opted-in. `inspect`/`install` are injectable for testing. A failure on
    /// one directory is logged and does not stop the others. Returns the
    /// directories that were refreshed.
    @discardableResult
    static func reinstallOutdated(
        managedDirs dirs: [URL],
        inspect: (URL) throws -> HookInstallStatus,
        install: (URL) throws -> Void
    ) -> [URL] {
        var refreshed: [URL] = []
        for dir in dirs {
            do {
                if try inspect(dir) == .outdated {
                    try install(dir)
                    refreshed.append(dir)
                }
            } catch {
                NSLog("HookMaintenance: failed refreshing \(dir.path) — \(error)")
            }
        }
        return refreshed
    }
}
