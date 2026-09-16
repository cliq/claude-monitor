// App/UI/UsageSettingsView.swift
import SwiftUI

struct UsageSettingsView: View {
    @ObservedObject var preferences: Preferences

    @State private var accounts: [UsageAccountConfig] = []
    @State private var portText: String = ""

    var body: some View {
        ScrollView {
            content
        }
        .onAppear {
            accounts = UsageAccountConfig.ordered(discovered: UsageAccountConfig.discover(),
                                                  order: preferences.usageAccountOrder)
            portText = String(preferences.usageBridgePort)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show usage limits", isOn: $preferences.usageMonitorEnabled)
                    .font(.headline)
                Text("Polls each enabled account every 3 minutes. Claude Code accounts use Anthropic's usage endpoint with the OAuth credentials Claude Code keeps in the Keychain — refreshed tokens are written back, so Claude Code stays logged in. Codex accounts are read through the Codex CLI's local app-server; their credentials are never read. Codex usage requires a ChatGPT sign-in (API-key logins are billed separately and have no plan limits).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accountsSection
                .disabled(!preferences.usageMonitorEnabled)

            if !metricGroupAccounts.isEmpty {
                Divider()
                metricGroupsSection
                    .disabled(!preferences.usageMonitorEnabled)
            }

            Divider()

            panelSection
                .disabled(!preferences.usageMonitorEnabled)

            Divider()

            bridgeSection
                .disabled(!preferences.usageMonitorEnabled)

        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accounts").font(.subheadline.weight(.semibold))
            if accounts.isEmpty {
                Text("No Claude Code or Codex config directories found in your home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Poll")
                        .frame(width: Self.checkboxColumnWidth)
                    Text("Account")
                    Spacer(minLength: 0)
                    Text("Widget · ESP32")
                        .frame(width: Self.externalColumnWidth)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                List {
                    ForEach(accounts) { account in
                        accountRow(account)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { from, to in
                        accounts.move(fromOffsets: from, toOffset: to)
                        preferences.usageAccountOrder = accounts.map(\.configDir)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(accounts.count), 5) * 30 + 8)
                Text("Drag to reorder — the panel and external displays show accounts in this order. Unpolled accounts don't appear anywhere. The right-hand checkmarks pick which accounts the widget and the ESP32 panel show (they fit three; the panel always shows every polled account). Leave the name empty to use the folder-derived default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let checkboxColumnWidth: CGFloat = 28
    private static let externalColumnWidth: CGFloat = 84

    private func accountRow(_ account: UsageAccountConfig) -> some View {
        let polled = !preferences.disabledUsageAccountDirs.contains(account.configDir)
        return HStack(spacing: 8) {
            Toggle("", isOn: enabledBinding(for: account))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: Self.checkboxColumnWidth)
            TextField(account.name, text: nameBinding(for: account))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            providerBadge(account.provider)
            Text(account.configDir)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Toggle("", isOn: externalBinding(for: account))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: Self.externalColumnWidth)
                .disabled(!polled)
                .help("Show this account on the widget and the ESP32 panel")
        }
    }

    private func providerBadge(_ provider: AgentProvider) -> some View {
        Text(provider.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }

    /// Disabled-list semantics, same as polling: checked = not hidden.
    private func externalBinding(for account: UsageAccountConfig) -> Binding<Bool> {
        Binding(
            get: { !preferences.externalHiddenUsageAccountDirs.contains(account.configDir) },
            set: { shown in
                if shown {
                    preferences.externalHiddenUsageAccountDirs.remove(account.configDir)
                } else {
                    preferences.externalHiddenUsageAccountDirs.insert(account.configDir)
                }
            }
        )
    }

    /// Disabled-list semantics: checked = not in the disabled set.
    private func enabledBinding(for account: UsageAccountConfig) -> Binding<Bool> {
        Binding(
            get: { !preferences.disabledUsageAccountDirs.contains(account.configDir) },
            set: { enabled in
                if enabled {
                    preferences.disabledUsageAccountDirs.remove(account.configDir)
                } else {
                    preferences.disabledUsageAccountDirs.insert(account.configDir)
                }
            }
        )
    }

    /// Empty field = no override; the placeholder shows the derived default.
    private func nameBinding(for account: UsageAccountConfig) -> Binding<String> {
        Binding(
            get: { preferences.usageAccountNames[account.configDir] ?? "" },
            set: { newValue in
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    preferences.usageAccountNames.removeValue(forKey: account.configDir)
                } else {
                    preferences.usageAccountNames[account.configDir] = newValue
                }
            }
        )
    }

    // MARK: - Optional metrics (Codex model allowances, spend limit)

    /// Polled accounts whose last poll returned optional-metric groups, in
    /// the accounts' display order. Only Codex reports these today.
    private var metricGroupAccounts: [(account: UsageAccountConfig, groups: [UsageMetricGroup])] {
        accounts.compactMap { account in
            guard !preferences.disabledUsageAccountDirs.contains(account.configDir),
                  let groups = preferences.knownUsageMetricGroups[account.configDir],
                  !groups.isEmpty else { return nil }
            return (account, groups)
        }
    }

    @ViewBuilder
    private var metricGroupsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional metrics").font(.subheadline.weight(.semibold))
            ForEach(metricGroupAccounts, id: \.account.id) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 6) {
                        Text(displayName(for: entry.account))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        providerBadge(entry.account.provider)
                    }
                    .frame(width: 180, alignment: .leading)
                    ForEach(entry.groups) { group in
                        Toggle(group.label, isOn: metricGroupBinding(dir: entry.account.configDir, group: group.key))
                            .toggleStyle(.checkbox)
                    }
                    Spacer(minLength: 0)
                }
            }
            Text("Extra limits some accounts report — a model's own allowance (e.g. GPT-5.3-Codex-Spark) or the workspace spend limit. Unchecked metrics are left off the usage panel, the widget, and the ESP32 panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func displayName(for account: UsageAccountConfig) -> String {
        let custom = preferences.usageAccountNames[account.configDir]?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? account.name : custom
    }

    /// Disabled-list semantics: checked = group not hidden for that account.
    private func metricGroupBinding(dir: String, group: String) -> Binding<Bool> {
        Binding(
            get: { !(preferences.hiddenUsageMetricGroups[dir] ?? []).contains(group) },
            set: { shown in
                var hidden = preferences.hiddenUsageMetricGroups[dir] ?? []
                if shown {
                    hidden.removeAll { $0 == group }
                } else if !hidden.contains(group) {
                    hidden.append(group)
                }
                if hidden.isEmpty {
                    preferences.hiddenUsageMetricGroups.removeValue(forKey: dir)
                } else {
                    preferences.hiddenUsageMetricGroups[dir] = hidden
                }
            }
        )
    }

    @ViewBuilder
    private var panelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage panel").font(.subheadline.weight(.semibold))
            Toggle("Compact layout", isOn: $preferences.usagePanelCompact)
            Text("Shows each account on a single row with smaller numbers, so the panel takes about a third of the vertical space.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Toggle("Turn external displays off when this Mac's screen is off",
                   isOn: $preferences.usageBridgeMirrorsDisplay)
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
