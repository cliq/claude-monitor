// App/UI/NotificationsSettingsView.swift
import SwiftUI

struct NotificationsSettingsView: View {
    @ObservedObject var preferences: Preferences

    @State private var apiKey: String = ""
    @State private var status: TestStatus = .idle
    @State private var keyExists: Bool = false
    @State private var clearTask: Task<Void, Never>?
    @State private var offlineError: String?

    private let keychain: KeychainStore
    private let prowl: ProwlClient

    enum TestStatus: Equatable {
        case idle
        case sending
        case success
        case failure(String)

        var label: String? {
            switch self {
            case .idle: return nil
            case .sending: return "Sending test…"
            case .success: return "Test sent ✓"
            case .failure(let msg): return msg
            }
        }
    }

    init(preferences: Preferences,
         keychain: KeychainStore = .prowl,
         prowl: ProwlClient = ProwlClient()) {
        self.preferences = preferences
        self.keychain = keychain
        self.prowl = prowl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle("Enable Prowl push notifications", isOn: $preferences.prowlEnabled)
                .font(.headline)
                .onChange(of: preferences.prowlEnabled) { _, newValue in
                    if !newValue { disableOfflineForGate() }
                    else if preferences.prowlOfflineHookEnabled, let key = currentKey() {
                        applyOfflineState(enable: true, apiKey: key)
                    }
                }

            keySection
                .disabled(!preferences.prowlEnabled)

            Divider()

            offlineSection
                .disabled(!preferences.prowlEnabled || !keyExists)

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { loadKeyState() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var keySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prowl API key").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                SecureField("Paste your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Button("Test") { Task { await runTest() } }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || status == .sending)
            }

            if let label = status.label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(status == .success ? .green : (status == .sending ? .secondary : .red))
            }

            Text("Get a key at prowlapp.com → Settings → API Keys.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if keyExists {
                Button("Remove key", role: .destructive) { removeKey() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Send pushes even when ClaudeMonitor isn't running",
                   isOn: $preferences.prowlOfflineHookEnabled)
                .onChange(of: preferences.prowlOfflineHookEnabled) { _, newValue in
                    guard preferences.prowlEnabled else { return }
                    guard let key = currentKey() else {
                        if newValue {
                            offlineError = "Enter and save your Prowl API key first."
                            preferences.prowlOfflineHookEnabled = false
                        }
                        return
                    }
                    applyOfflineState(enable: newValue, apiKey: key)
                }

            if preferences.prowlOfflineHookEnabled {
                Text("⚠ This stores your Prowl API key in plain text in ~/.claude-monitor/offline-prowl.sh. Anyone with read access to your home folder can read it. The monitor app keeps the key in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = offlineError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func loadKeyState() {
        let existing = try? keychain.get()
        keyExists = (existing != nil)
        apiKey = existing ?? ""
    }

    private func currentKey() -> String? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return (try? keychain.get()) ?? nil
    }

    private func runTest() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        clearTask?.cancel()
        status = .sending
        do {
            try keychain.set(trimmed)
            keyExists = true
        } catch {
            status = .failure("Couldn't save key to Keychain (\(error)).")
            return
        }

        if preferences.prowlOfflineHookEnabled {
            applyOfflineState(enable: true, apiKey: trimmed)
        }

        let result = await prowl.send(apiKey: trimmed,
                                      event: "ClaudeMonitor: Test ✓",
                                      description: "If you're seeing this, your API key works.")
        switch result {
        case .success:                         status = .success
        case .failure(.invalidAPIKey):         status = .failure("Invalid API key.")
        case .failure(.rateLimited):           status = .failure("Rate limited (1000/hr exceeded).")
        case .failure(.network(let urlErr)):   status = .failure("Network error: \(urlErr.localizedDescription)")
        case .failure(.http(let code, _)):     status = .failure("Prowl error (HTTP \(code)).")
        }

        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { status = .idle }
        }
    }

    private func removeKey() {
        clearTask?.cancel()
        try? keychain.delete()
        apiKey = ""
        keyExists = false
        status = .idle
        if preferences.prowlOfflineHookEnabled {
            preferences.prowlOfflineHookEnabled = false
            applyOfflineState(enable: false, apiKey: "")
        }
    }

    private func disableOfflineForGate() {
        // Master toggle was turned off — uninstall the offline script even if
        // the user previously had offline mode on. The preference itself is
        // preserved so re-enabling the master toggle restores the behavior.
        guard preferences.prowlOfflineHookEnabled else { return }
        applyOfflineState(enable: false, apiKey: "", preserveOfflinePref: true)
    }

    private func applyOfflineState(enable: Bool, apiKey: String, preserveOfflinePref: Bool = false) {
        offlineError = nil
        let configDirs = preferences.managedConfigDirectoryPaths
            .map { URL(fileURLWithPath: $0) }
        do {
            if enable {
                try OfflineHookDeployer.enable(configDirs: configDirs, apiKey: apiKey)
            } else {
                try OfflineHookDeployer.disable(configDirs: configDirs)
            }
        } catch {
            offlineError = "Couldn't update offline hook: \(error.localizedDescription)"
            if !preserveOfflinePref {
                preferences.prowlOfflineHookEnabled = false
            }
        }
    }
}
