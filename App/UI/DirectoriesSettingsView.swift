// App/UI/DirectoriesSettingsView.swift
import SwiftUI
import AppKit

struct DirectoriesSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var directoriesWithStatus: [ManagedConfigDirectory] = []
    @State private var codexDirectoriesWithStatus: [ManagedConfigDirectory] = []
    @State private var errorMessage: String?

    var body: some View {
        // The two directory lists can outgrow the fixed tab frame, so the whole
        // pane scrolls (same pattern as the Usage pane) and the lists are plain
        // stacks rather than Lists — nested scroll containers don't mix.
        ScrollView {
            content
        }
        .onAppear {
            autoDetectCodexIfEmpty()
            refresh()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Managed Claude config directories").font(.headline)
            Text("Claude Monitor installs its hook block into each directory's settings.json. Other hooks you've configured are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            directoryList(directoriesWithStatus,
                          emptyLabel: "No Claude directories in the list — use Redetect or Add Directory.",
                          install: { install($0.url) },
                          uninstall: { uninstall($0) },
                          remove: { remove($0) })

            HStack {
                Button("Add Directory…") { addDirectory() }
                Button("Redetect") { redetect() }
                Spacer()
            }

            Divider()

            Text("Managed Codex config directories").font(.headline)
            Text("Codex sessions report through hooks installed into each directory's hooks.json. After installing, run /hooks inside Codex to review and trust the new entries — they stay inactive until trusted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            directoryList(codexDirectoriesWithStatus,
                          emptyLabel: "No Codex directories in the list — use Redetect Codex or Add Codex Directory.",
                          install: { installCodex($0.url) },
                          uninstall: { uninstallCodex($0) },
                          remove: { removeCodex($0) })

            HStack {
                Button("Add Codex Directory…") { addCodexDirectory() }
                Button("Redetect Codex") { redetectCodex() }
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func directoryList(_ entries: [ManagedConfigDirectory],
                               emptyLabel: String,
                               install: @escaping (ManagedConfigDirectory) -> Void,
                               uninstall: @escaping (ManagedConfigDirectory) -> Void,
                               remove: @escaping (ManagedConfigDirectory) -> Void) -> some View {
        if entries.isEmpty {
            Text(emptyLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    directoryRow(entry,
                                 install: { install(entry) },
                                 uninstall: { uninstall(entry) },
                                 remove: { remove(entry) })
                    if entry.id != entries.last?.id {
                        Divider()
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private func directoryRow(_ entry: ManagedConfigDirectory,
                              install: @escaping () -> Void,
                              uninstall: @escaping () -> Void,
                              remove: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.url.path).font(.system(.body, design: .monospaced))
                Text(statusLabel(entry.status))
                    .font(.caption)
                    .foregroundStyle(statusColor(entry.status))
            }
            Spacer()
            if entry.status == .installed {
                Button("Reinstall") { install() }
            } else if entry.status == .outdated || entry.status == .modifiedExternally {
                Button("Reinstall") { install() }
                    .tint(.orange)
            } else {
                Button("Install") { install() }
            }
            if entry.status != .notInstalled {
                Button("Uninstall") { uninstall() }
            }
            Button("Remove", role: .destructive) { remove() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func refresh() {
        directoriesWithStatus = preferences.managedConfigDirectoryPaths
            .map(URL.init(fileURLWithPath:))
            .map { url in
                let status = (try? HookInstaller.inspect(configDir: url))
                    ?? HookInstaller.Status(status: .notInstalled, installedVersion: 0)
                return ManagedConfigDirectory(url: url,
                                              status: status.status,
                                              installedVersion: status.installedVersion)
            }
        codexDirectoriesWithStatus = preferences.managedCodexDirectoryPaths
            .map(URL.init(fileURLWithPath:))
            .map { url in
                let status = (try? HookInstaller.inspectCodexHook(configDir: url))
                    ?? HookInstaller.Status(status: .notInstalled, installedVersion: 0)
                return ManagedConfigDirectory(url: url,
                                              status: status.status,
                                              installedVersion: status.installedVersion)
            }
    }

    // MARK: Claude directories

    private func install(_ dir: URL) {
        do {
            try HookScriptDeployer.deploy()
            try HookInstaller.install(configDir: dir)
            refresh()
            showInstallSuccess(settingsFile: dir.appendingPathComponent("settings.json"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showInstallSuccess(settingsFile: URL) {
        let alert = NSAlert()
        alert.messageText = "Hooks installed"
        alert.informativeText = """
        Modified: \(settingsFile.path)

        A backup of the previous contents was saved alongside as settings.json.bak.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func uninstall(_ entry: ManagedConfigDirectory) {
        let alert = NSAlert()
        alert.messageText = "Uninstall hooks from \(entry.url.lastPathComponent)?"
        alert.informativeText = "Claude Monitor's hook block will be removed from settings.json. The directory stays in the list and can be reinstalled later."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookInstaller.uninstall(configDir: entry.url)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ entry: ManagedConfigDirectory) {
        // Only warn when there is actually an installed hook the user might
        // expect Remove to clean up; removing an uninstalled row is harmless.
        if entry.status != .notInstalled {
            guard confirmRemove(entry, hooksFileName: "settings.json") else { return }
        }
        preferences.managedConfigDirectoryPaths.removeAll { $0 == entry.url.path }
        refresh()
    }

    private func redetect() {
        let discovered = ConfigDirectoryDiscovery.scan().map(\.path)
        let currentSet = Set(preferences.managedConfigDirectoryPaths)
        let added = discovered.filter { !currentSet.contains($0) }
        guard !added.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No new Claude directories found."
            alert.informativeText = "Scanned your home folder for `.claude` and `.claudewho-*` directories containing a settings.json."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        preferences.managedConfigDirectoryPaths.append(contentsOf: added)
        refresh()
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // Claude config dirs start with `.`
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !preferences.managedConfigDirectoryPaths.contains(url.path) {
            preferences.managedConfigDirectoryPaths.append(url.path)
        }
        refresh()
    }

    // MARK: Codex directories

    /// First visit seeds the Codex list from a silent scan so the section isn't
    /// blank. Only runs while the list is empty — a user who removed entries
    /// deliberately gets them back only via Redetect Codex.
    private func autoDetectCodexIfEmpty() {
        guard preferences.managedCodexDirectoryPaths.isEmpty else { return }
        let discovered = ConfigDirectoryDiscovery.scanCodex().map(\.path)
        guard !discovered.isEmpty else { return }
        preferences.managedCodexDirectoryPaths = discovered
    }

    private func installCodex(_ dir: URL) {
        do {
            try HookScriptDeployer.deployCodexScript()
            try HookInstaller.installCodexHook(configDir: dir)
            refresh()
            showCodexInstallSuccess(hooksFile: dir.appendingPathComponent("hooks.json"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showCodexInstallSuccess(hooksFile: URL) {
        let alert = NSAlert()
        alert.messageText = "Codex hooks installed — trust required"
        alert.informativeText = """
        Modified: \(hooksFile.path)

        A backup of the previous contents was saved alongside as hooks.json.claude-monitor.bak.

        Codex won't run the new hooks until you trust them:
        1. Start or restart Codex.
        2. Run /hooks.
        3. Review and trust the Claude Monitor entries.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func uninstallCodex(_ entry: ManagedConfigDirectory) {
        let alert = NSAlert()
        alert.messageText = "Uninstall Codex hooks from \(entry.url.lastPathComponent)?"
        alert.informativeText = "Claude Monitor's hook entries will be removed from hooks.json. Hooks installed by other tools are preserved. The directory stays in the list and can be reinstalled later."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookInstaller.uninstallCodexHook(configDir: entry.url)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeCodex(_ entry: ManagedConfigDirectory) {
        if entry.status != .notInstalled {
            guard confirmRemove(entry, hooksFileName: "hooks.json") else { return }
        }
        preferences.managedCodexDirectoryPaths.removeAll { $0 == entry.url.path }
        refresh()
    }

    private func addCodexDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // Codex config dirs start with `.`
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !preferences.managedCodexDirectoryPaths.contains(url.path) {
            preferences.managedCodexDirectoryPaths.append(url.path)
        }
        refresh()
    }

    private func redetectCodex() {
        let discovered = ConfigDirectoryDiscovery.scanCodex().map(\.path)
        let currentSet = Set(preferences.managedCodexDirectoryPaths)
        let added = discovered.filter { !currentSet.contains($0) }
        guard !added.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No new Codex directories found."
            alert.informativeText = "Scanned your home folder for `.codex` and `.codexwho-*` directories containing a config.toml or auth.json."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        preferences.managedCodexDirectoryPaths.append(contentsOf: added)
        refresh()
    }

    // MARK: Shared helpers

    private func confirmRemove(_ entry: ManagedConfigDirectory, hooksFileName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.url.lastPathComponent) from the list?"
        alert.informativeText = "This only removes the directory from Claude Monitor's list. The installed hook in its \(hooksFileName) is left in place — use Uninstall first if you want that gone too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func statusLabel(_ s: HookInstallStatus) -> String {
        switch s {
        case .installed:          return "Installed"
        case .notInstalled:       return "Not installed"
        case .outdated:           return "Outdated — reinstall recommended"
        case .modifiedExternally: return "Modified externally"
        }
    }

    private func statusColor(_ s: HookInstallStatus) -> Color {
        switch s {
        case .installed:          return .green
        case .notInstalled:       return .secondary
        case .outdated:           return .orange
        case .modifiedExternally: return .orange
        }
    }
}
