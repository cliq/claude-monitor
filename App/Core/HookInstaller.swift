// App/Core/HookInstaller.swift
import Foundation

enum HookInstaller {
    /// Bumped to 3 when the managed tag moved from sidecar keys (`_managedBy`,
    /// `_version`) *into* the command string itself — `hook.sh SessionStart
    /// --managed-by=claude-monitor --version=3`. Some tools that process
    /// `settings.json` (Claude Code's own loader among them, under some paths)
    /// re-serialize entries to the published schema and strip unknown keys,
    /// which left real installs looking "Not installed" even though the hooks
    /// were firing. The `command` field is schema-defined and survives those
    /// rewrites, so the version is encoded there.
    static let currentVersion = 3
    private static let managedKey = "_managedBy"
    private static let managedValue = "claude-monitor"
    private static let versionKey = "_version"
    private static let hookScriptPathMarker = ".claude-monitor/hook.sh"
    private static let managedByArg = "--managed-by=claude-monitor"
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
            let managed = entries.filter(isOurs)
            if managed.isEmpty { anyMissing = true; continue }
            let expectedCmd = expectedCommand(for: hook)
            for entry in managed {
                let v = detectedVersion(of: entry)
                versions.append(v)
                // Only compare commands at the current version. Older schemas used
                // different command shapes (v1's flat `command`, v2's untagged nested
                // form), so a mismatch there means "outdated", not "user modified".
                guard v == currentVersion else { continue }
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
            entries.removeAll(where: isOurs)
            let command: [String: Any] = [
                "type": "command",
                "command": expectedCommand(for: hook),
            ]
            // Shape matches Claude Code's hook schema:
            //   { matcher: "", hooks: [{ type: "command", command: "..." }] }
            // The sidecar `_managedBy`/`_version` keys are kept for tools that preserve
            // unknown fields, but they are *not* load-bearing — detection also works via
            // the `--managed-by=claude-monitor --version=N` args baked into the command.
            let managed: [String: Any] = [
                managedKey: managedValue,
                versionKey: currentVersion,
                "matcher": "",
                "hooks": [command],
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
            entries.removeAll(where: isOurs)
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
        "$HOME/.claude-monitor/hook.sh \(hook) \(managedByArg) --version=\(currentVersion)"
    }

    /// Entry "ownership": sidecar tag OR a managed command (by path) — whichever survives.
    private static func isOurs(_ entry: [String: Any]) -> Bool {
        if entry[managedKey] as? String == managedValue { return true }
        if let cmd = managedCommand(in: entry), cmd.contains(hookScriptPathMarker) { return true }
        return false
    }

    /// The strongest version signal on an entry: `--version=N` baked into the command
    /// wins (survives stripping), else the `_version` sidecar, else 0 (pre-tag install).
    private static func detectedVersion(of entry: [String: Any]) -> Int {
        if let cmd = managedCommand(in: entry), let v = versionArg(in: cmd) { return v }
        if let v = entry[versionKey] as? Int { return v }
        return 0
    }

    private static func managedCommand(in entry: [String: Any]) -> String? {
        // v2+ shape: { hooks: [{ type, command }] }.
        if let inner = entry["hooks"] as? [[String: Any]], let cmd = inner.first?["command"] as? String {
            return cmd
        }
        // v1 shape: { command } flat on the entry.
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
