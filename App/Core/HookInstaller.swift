// App/Core/HookInstaller.swift
import Foundation

enum HookInstaller {
    static let currentVersion = 1
    private static let managedKey = "_managedBy"
    private static let managedValue = "claude-monitor"
    private static let versionKey = "_version"
    private static let allHooks = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]

    struct Status: Equatable {
        let status: HookInstallStatus
        let installedVersion: Int
    }

    // MARK: Inspect

    static func inspect(configDir: URL) throws -> Status {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        let json = try loadJson(settingsURL)
        let hooks = (json["hooks"] as? [String: Any]) ?? [:]

        var versions: [Int] = []
        var anyMissing = false
        var anyModified = false

        for hook in allHooks {
            let entries = (hooks[hook] as? [[String: Any]]) ?? []
            let managed = entries.filter { $0[managedKey] as? String == managedValue }
            if managed.isEmpty { anyMissing = true; continue }
            let expectedCmd = expectedCommand(for: hook)
            for entry in managed {
                if let v = entry[versionKey] as? Int { versions.append(v) }
                if (entry["command"] as? String) != expectedCmd { anyModified = true }
            }
        }

        if anyMissing && versions.isEmpty {
            return Status(status: .notInstalled, installedVersion: 0)
        }
        if anyMissing || anyModified {
            return Status(status: .modifiedExternally, installedVersion: versions.max() ?? 0)
        }
        let maxV = versions.max() ?? 0
        if maxV < currentVersion {
            return Status(status: .outdated, installedVersion: maxV)
        }
        return Status(status: .installed, installedVersion: maxV)
    }

    // MARK: Install

    static func install(configDir: URL) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        var json = (try? loadJson(settingsURL)) ?? [:]
        var hooks = (json["hooks"] as? [String: Any]) ?? [:]

        for hook in allHooks {
            var entries = (hooks[hook] as? [[String: Any]]) ?? []
            entries.removeAll { $0[managedKey] as? String == managedValue }
            let managed: [String: Any] = [
                managedKey: managedValue,
                versionKey: currentVersion,
                "command": expectedCommand(for: hook),
            ]
            entries.append(managed)
            hooks[hook] = entries
        }
        json["hooks"] = hooks
        try saveJson(json, to: settingsURL)
    }

    // MARK: Uninstall

    static func uninstall(configDir: URL) throws {
        let settingsURL = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var json = try loadJson(settingsURL)
        guard var hooks = json["hooks"] as? [String: Any] else { return }

        for (key, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { $0[managedKey] as? String == managedValue }
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

    private static func expectedCommand(for hook: String) -> String {
        "$HOME/.claude-monitor/hook.sh \(hook)"
    }

    private static func loadJson(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    private static func saveJson(_ json: [String: Any], to url: URL) throws {
        // Snapshot the existing file as <path>.bak before writing, so the previous
        // contents can be recovered manually if an install goes wrong. Only one
        // rolling backup is kept — the state immediately before the most recent write.
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            _ = try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }

        // Write with sorted keys + pretty printing for stable diffs.
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
