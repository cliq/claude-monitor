// App/UI/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updateChecker: UpdateChecker

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        Form {
            LabeledContent("Version") {
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates daily", isOn: $preferences.updateCheckEnabled)
                Text("Checks the GitHub releases page at launch and once a day. Nothing is downloaded automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Check Now") { updateChecker.checkNow() }
                    statusText
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusText: some View {
        switch updateChecker.lastOutcome {
        case .none:
            EmptyView()
        case .upToDate:
            Text("You're up to date.")
                .foregroundStyle(.secondary)
        case .updateAvailable(let version):
            if let url = updateChecker.availableUpdate?.url {
                Link("Version \(version) is available →", destination: url)
            } else {
                Text("Version \(version) is available.")
            }
        case .failed:
            Text("Couldn't reach GitHub. Will retry later.")
                .foregroundStyle(.secondary)
        }
    }
}
