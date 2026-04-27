// App/UI/NotificationsSettingsView.swift
import SwiftUI

struct NotificationsSettingsView: View {
    @ObservedObject var preferences: Preferences

    @State private var apiKey: String = ""
    @State private var status: TestStatus = .idle
    @State private var keyExists: Bool = false
    @State private var clearTask: Task<Void, Never>?

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

            VStack(alignment: .leading, spacing: 6) {
                Text("Prowl API key").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    SecureField("Paste your API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!preferences.prowlEnabled)

                    Button("Test") { Task { await runTest() } }
                        .disabled(!preferences.prowlEnabled || apiKey.trimmingCharacters(in: .whitespaces).isEmpty || status == .sending)
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

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { loadKeyState() }
    }

    private func loadKeyState() {
        let existing = try? keychain.get()
        keyExists = (existing != nil)
        apiKey = existing ?? ""
    }

    private func runTest() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        clearTask?.cancel()
        status = .sending
        do { try keychain.set(trimmed); keyExists = true }
        catch { status = .failure("Couldn't save key to Keychain (\(error)).") ; return }

        let result = await prowl.send(apiKey: trimmed,
                                      event: "ClaudeMonitor: Test ✓",
                                      description: "If you're seeing this, your API key works.")
        switch result {
        case .success:
            status = .success
        case .failure(.invalidAPIKey):
            status = .failure("Invalid API key.")
        case .failure(.rateLimited):
            status = .failure("Rate limited (1000/hr exceeded).")
        case .failure(.network(let urlErr)):
            status = .failure("Network error: \(urlErr.localizedDescription)")
        case .failure(.http(let code, _)):
            status = .failure("Prowl error (HTTP \(code)).")
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
    }
}
