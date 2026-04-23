// App/UI/SettingsView.swift
import SwiftUI
import AppKit

struct SettingsView: View {
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
                        Button("Remove", role: .destructive) { remove(entry) }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("Add Directory…") { addDirectory() }
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ entry: ManagedConfigDirectory) {
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.url.lastPathComponent)?"
        alert.informativeText = "Also uninstall the hook block from its settings.json?"
        alert.addButton(withTitle: "Uninstall & Remove")
        alert.addButton(withTitle: "Remove from List Only")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? HookInstaller.uninstall(configDir: entry.url)
            preferences.managedConfigDirectoryPaths.removeAll { $0 == entry.url.path }
            refresh()
        case .alertSecondButtonReturn:
            preferences.managedConfigDirectoryPaths.removeAll { $0 == entry.url.path }
            refresh()
        default:
            break
        }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
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
