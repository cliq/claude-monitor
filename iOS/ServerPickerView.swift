// iOS/ServerPickerView.swift
import SwiftUI

/// Pick the Mac to read usage from: Macs advertising the bridge over
/// Bonjour, or a typed host/port for networks where Bonjour doesn't reach.
struct ServerPickerView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var browser: BridgeBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var manualText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if browser.serviceNames.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.serviceNames, id: \.self) { name in
                        row(title: name, endpoint: .bonjour(name: name))
                    }
                } header: {
                    Text("On this network")
                } footer: {
                    Text("On the Mac, turn on Claude Monitor → Settings → Usage → \"Serve usage to external displays\".")
                }

                Section {
                    if case .manual = store.endpoint, let endpoint = store.endpoint {
                        row(title: endpoint.displayName, endpoint: endpoint)
                    }
                    TextField("my-mac.local:8737", text: $manualText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(connectManual)
                    Button("Connect", action: connectManual)
                        .disabled(BridgeEndpoint.manual(from: manualText) == nil)
                } header: {
                    Text("Address")
                } footer: {
                    Text("Host name or IP address of the Mac, with the bridge port if it isn't \(String(BridgeEndpoint.defaultPort)).")
                }
            }
            .navigationTitle("Choose Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func row(title: String, endpoint: BridgeEndpoint) -> some View {
        Button {
            store.endpoint = endpoint
            dismiss()
        } label: {
            HStack {
                Label(title, systemImage: "desktopcomputer")
                    .foregroundStyle(.primary)
                Spacer()
                if store.endpoint == endpoint {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func connectManual() {
        guard let endpoint = BridgeEndpoint.manual(from: manualText) else { return }
        store.endpoint = endpoint
        manualText = ""
        dismiss()
    }
}
