// App/UI/OnboardingView.swift
import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var preferences: Preferences
    let onFinished: () -> Void

    @State private var discoveredDirs: [URL] = []
    @State private var selected: Set<URL> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Claude Code hooks")
                .font(.title2).bold()
            Text("Select the Claude config directories where Claude Monitor should install its hooks. You can change this later in Settings.")
                .font(.body)

            if discoveredDirs.isEmpty {
                Text("No config directories found under your home folder.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(discoveredDirs, id: \.self) { dir in
                        Toggle(isOn: binding(for: dir)) {
                            Text(dir.path).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                .frame(minHeight: 120)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }

            HStack {
                Button("Skip") { preferences.hasOnboarded = true; onFinished() }
                Spacer()
                Button("Install Selected") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            discoveredDirs = ConfigDirectoryDiscovery.scan()
            selected = Set(discoveredDirs)
        }
    }

    private func binding(for dir: URL) -> Binding<Bool> {
        Binding(
            get: { selected.contains(dir) },
            set: { isOn in
                if isOn { selected.insert(dir) } else { selected.remove(dir) }
            }
        )
    }

    private func install() {
        do {
            try HookScriptDeployer.deploy()
            var modifiedFiles: [URL] = []
            for dir in selected.sorted(by: { $0.path < $1.path }) {
                let settingsFile = dir.appendingPathComponent("settings.json")
                try HookInstaller.install(configDir: dir)
                modifiedFiles.append(settingsFile)
            }
            preferences.managedConfigDirectoryPaths = Array(selected.map(\.path)).sorted()
            preferences.hasOnboarded = true
            showInstallSuccess(modifiedFiles: modifiedFiles)
            onFinished()
        } catch {
            errorMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    private func showInstallSuccess(modifiedFiles: [URL]) {
        let alert = NSAlert()
        alert.messageText = "Hooks installed"
        let fileList = modifiedFiles.map { "  • \($0.path)" }.joined(separator: "\n")
        alert.informativeText = """
        The following settings files were modified:

        \(fileList)

        A backup of each file's previous contents was saved alongside it as settings.json.bak.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
