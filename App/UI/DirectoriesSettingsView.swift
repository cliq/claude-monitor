// App/UI/DirectoriesSettingsView.swift
import SwiftUI
import AppKit

struct DirectoriesSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var directoriesWithStatus: [ManagedConfigDirectory] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Managed Claude config directories").font(.headline)
            Text("Claude Monitor installs its hook block into each directory's settings.json. Other hooks you've configured are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(directoriesWithStatus) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.url.path).font(.system(.body, design: .monospaced))
                            Text(statusLabel(entry.status))
                                .font(.caption)
                                .foregroundStyle(statusColor(entry.status))
                        }
                        Spacer()
                        if entry.status == .installed {
                            Button("Reinstall") { install(entry.url) }
                        } else if entry.status == .outdated || entry.status == .modifiedExternally {
                            Button("Reinstall") { install(entry.url) }
                                .tint(.orange)
                        } else {
                            Button("Install") { install(entry.url) }
                        }
                        if entry.status != .notInstalled {
                            Button("Uninstall") { uninstall(entry) }
                        }
                        Button("Remove", role: .destructive) { remove(entry) }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("Add Directory…") { addDirectory() }
                Button("Redetect") { redetect() }
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding(20)
        .onAppear { refresh() }
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
    }

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
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.url.lastPathComponent) from the list?"
        alert.informativeText = "This only removes the directory from Claude Monitor's list. Any installed hook in its settings.json is left in place — use Uninstall first if you want that gone too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
