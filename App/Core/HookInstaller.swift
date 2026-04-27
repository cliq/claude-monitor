// App/Core/HookInstaller.swift
import Foundation

enum HookInstaller {
    /// Main-hook schema version, also exported for tests. Bumped to 3 when the managed tag
    /// moved from sidecar keys (`_managedBy`, `_version`) *into* the command string itself —
    /// `hook.sh SessionStart --managed-by=claude-monitor --version=3`. Some tools that
    /// process `settings.json` (Claude Code's own loader among them, under some paths)
    /// re-serialize entries to the published schema and strip unknown keys, which left real
    /// installs looking "Not installed" even though the hooks were firing. The `command`
    /// field is schema-defined and survives those rewrites, so the version is encoded there.
    static let currentVersion = 3

    private struct Kind {
        let managedValue: String
        /// Substring matched against the full command string to identify entries we own
        /// when sidecar keys have been stripped by a foreign serializer. Today this equals
        /// `scriptRelativePath`; the two stay separate so a future kind can use a shorter
        /// or partial marker without changing the deployed command path.
        let scriptPathMarker: String
        /// Path relative to `$HOME` that is written into the managed entry's command.
        let scriptRelativePath: String
        let hooks: [String]
        let currentVersion: Int
    }

    private static let mainKind = Kind(
        managedValue: "claude-monitor",
        scriptPathMarker: ".claude-monitor/hook.sh",
        scriptRelativePath: ".claude-monitor/hook.sh",
        hooks: ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"],
        currentVersion: HookInstaller.currentVersion
    )

    private static let offlineKind = Kind(
        managedValue: "claude-monitor-offline-prowl",
        scriptPathMarker: ".claude-monitor/offline-prowl.sh",
        scriptRelativePath: ".claude-monitor/offline-prowl.sh",
        hooks: ["Stop", "Notification"],
        currentVersion: 1
    )

    private static let managedKey = "_managedBy"
    private static let versionKey = "_version"

    struct Status: Equatable {
        let status: HookInstallStatus
        let installedVersion: Int
    }

    // MARK: Public API — main hook (unchanged signatures)

    static func inspect(configDir: URL) throws -> Status {
        try inspect(configDir: configDir, kind: mainKind)
    }

    static func install(configDir: URL) throws {
        try install(configDir: configDir, kind: mainKind)
    }

    static func uninstall(configDir: URL) throws {
        try uninstall(configDir: configDir, kind: mainKind)
    }

    // MARK: Public API — offline-prowl hook

    static func inspectOfflineHook(configDir: URL) throws -> Status {
        try inspect(configDir: configDir, kind: offlineKind)
    }

    static func installOfflineHook(configDir: URL) throws {
        try install(configDir: configDir, kind: offlineKind)
    }

    static func uninstallOfflineHook(configDir: URL) throws {
        try uninstall(configDir: configDir, kind: offlineKind)
    }

    // MARK: Implementation

    private static func inspect(configDir: URL, kind: Kind) throws -> Status {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        let json = try loadJson(settingsURL)
        let hooks = (json["hooks"] as? [String: Any]) ?? [:]

        var versions: [Int] = []
        var anyMissing = false
        var anyModified = false

        for hook in kind.hooks {
            let entries = (hooks[hook] as? [[String: Any]]) ?? []
            let managed = entries.filter { isOurs($0, kind: kind) }
            if managed.isEmpty { anyMissing = true; continue }
            let expectedCmd = expectedCommand(for: hook, kind: kind)
            for entry in managed {
                let v = detectedVersion(of: entry)
                versions.append(v)
                guard v == kind.currentVersion else { continue }
                let innerHooks = (entry["hooks"] as? [[String: Any]]) ?? []
                let innerCmd = innerHooks.first?["command"] as? String
                if innerCmd != expectedCmd { anyModified = true }
            }
        }

        if anyMissing && versions.isEmpty {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        if anyMissing || anyModified {
            return Status(status: .modifiedExternally, installedVersion: versions.max() ?? 0)
        }
        let maxV = versions.max() ?? 0
        if maxV < kind.currentVersion {
            return Status(status: .outdated, installedVersion: maxV)
        }
        return Status(status: .installed, installedVersion: maxV)
    }

    private static func install(configDir: URL, kind: Kind) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        var json = (try? loadJson(settingsURL)) ?? [:]
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]

        for hook in kind.hooks {
            var entries = (hooks[hook] as? [[String: Any]]) ?? []
            entries.removeAll(where: { isOurs($0, kind: kind) })
            let command: [String: Any] = [
                "type": "command",
                "command": expectedCommand(for: hook, kind: kind),
            ]
            let managed: [String: Any] = [
                managedKey: kind.managedValue,
                versionKey: kind.currentVersion,
                "matcher": "",
                "hooks": [command],
            ]
            entries.append(managed)
            hooks[hook] = entries
        }
        json["hooks"] = hooks
        try saveJson(json, to: settingsURL)
    }

    private static func uninstall(configDir: URL, kind: Kind) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var json = try loadJson(settingsURL)
        guard var hooks = json["hooks"] as? [String: Any] else { return }

        for (key, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: { isOurs($0, kind: kind) })
            if entries.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = entries
            }
        }
        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
        try saveJson(json, to: settingsURL)
    }

    // MARK: Helpers

    private static func expectedCommand(for hook: String, kind: Kind) -> String {
        "$HOME/\(kind.scriptRelativePath) \(hook) --managed-by=\(kind.managedValue) --version=\(kind.currentVersion)"
    }

    private static func isOurs(_ entry: [String: Any], kind: Kind) -> Bool {
        if entry[managedKey] as? String == kind.managedValue { return true }
        if let cmd = managedCommand(in: entry), cmd.contains(kind.scriptPathMarker) {
            return true
        }
        return false
    }

    private static func detectedVersion(of entry: [String: Any]) -> Int {
        if let cmd = managedCommand(in: entry), let v = versionArg(in: cmd) { return v }
        if let v = entry[versionKey] as? Int { return v }
        return 0
    }

    private static func managedCommand(in entry: [String: Any]) -> String? {
        if let inner = entry["hooks"] as? [[String: Any]], let cmd = inner.first?["command"] as? String {
            return cmd
        }
        return entry["command"] as? String
    }

    private static func versionArg(in command: String) -> Int? {
        guard let range = command.range(of: "--version=") else { return nil }
        let tail = command[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func loadJson(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    private static func saveJson(_ json: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            _ = try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
