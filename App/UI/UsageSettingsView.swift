// App/UI/UsageSettingsView.swift
import SwiftUI

struct UsageSettingsView: View {
    @ObservedObject var preferences: Preferences

    @State private var accounts: [UsageAccountConfig] = []
    @State private var portText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show Claude usage limits", isOn: $preferences.usageMonitorEnabled)
                    .font(.headline)
                Text("Polls Anthropic's usage endpoint every 3 minutes for each logged-in Claude Code account, using the OAuth credentials Claude Code keeps in the Keychain. Refreshed tokens are written back, so Claude Code stays logged in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accountsSection
                .disabled(!preferences.usageMonitorEnabled)

            Divider()

            bridgeSection
                .disabled(!preferences.usageMonitorEnabled)

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear {
            accounts = UsageAccountConfig.discover()
            portText = String(preferences.usageBridgePort)
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accounts").font(.subheadline.weight(.semibold))
            if accounts.isEmpty {
                Text("No Claude Code config directories found in your home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    HStack(spacing: 8) {
                        Text(account.name)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        Text(account.configDir)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bridgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Serve usage to external displays", isOn: $preferences.usageBridgeEnabled)
            HStack(spacing: 8) {
                Text("Port")
                TextField("8737", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit(commitPort)
                    .onChange(of: preferences.usageBridgeEnabled) { _, _ in commitPort() }
            }
            .disabled(!preferences.usageBridgeEnabled)
            Text("Devices on your network (e.g. the ESP32 desk panel) can read the snapshot at http://<this-mac>:\(preferences.usageBridgePort)/usage and the display power state at /display. Anyone on your LAN can see these numbers while this is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commitPort() {
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) {
            preferences.usageBridgePort = port
        } else {
            portText = String(preferences.usageBridgePort)
        }
    }
}
