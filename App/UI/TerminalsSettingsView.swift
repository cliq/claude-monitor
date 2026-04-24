// App/UI/TerminalsSettingsView.swift
import SwiftUI

struct TerminalsSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var installedTerminals: [TerminalProvider] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal applications").font(.headline)
            Text("Claude Monitor auto-detects which app hosts each Claude session. Uncheck to skip a terminal when focusing tabs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if installedTerminals.isEmpty {
                Text("No supported terminal applications installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(installedTerminals, id: \.bundleID) { provider in
                    Toggle(isOn: terminalBinding(for: provider.bundleID)) {
                        HStack {
                            Text(provider.displayName)
                            Text("(\(provider.bundleID))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                if allTerminalsDisabled {
                    Text("No terminal enabled — clicking a tile won't focus anything.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
        .padding(20)
        .onAppear {
            installedTerminals = TerminalRegistry.installed()
        }
    }

    private var allTerminalsDisabled: Bool {
        guard !installedTerminals.isEmpty else { return false }
        return installedTerminals.allSatisfy { preferences.disabledTerminalBundleIDs.contains($0.bundleID) }
    }

    private func terminalBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { !preferences.disabledTerminalBundleIDs.contains(bundleID) },
            set: { newValue in
                if newValue {
                    preferences.disabledTerminalBundleIDs.remove(bundleID)
                } else {
                    preferences.disabledTerminalBundleIDs.insert(bundleID)
                }
            }
        )
    }
}
