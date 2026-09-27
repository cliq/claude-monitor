// iOS/MobileUsageView.swift
import SwiftUI

/// The iPhone rendering of the Mac's usage panel: the same account rows
/// (`UsageAccountRow`) and status bar, fed by the LAN bridge.
struct MobileUsageView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var browser: BridgeBrowser
    @AppStorage("usagePanelCompact") private var compact = false
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh() }
            .background(UsagePalette.bg)
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(UsagePalette.statusBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        compact.toggle()
                    } label: {
                        Image(systemName: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    }
                    .accessibilityLabel(compact ? "Regular layout" : "Compact layout")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPicker = true
                    } label: {
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityLabel("Choose Mac")
                }
            }
            .tint(UsagePalette.name)
        }
        .sheet(isPresented: $showingPicker) {
            ServerPickerView(store: store, browser: browser)
        }
        .onAppear {
            if store.endpoint == nil { showingPicker = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.endpoint == nil {
            placeholder("Choose the Mac running Claude Monitor", action: "Choose Mac")
        } else if let snapshot = store.snapshot {
            if snapshot.accounts.isEmpty {
                placeholder(snapshot.updatedAt == nil ? "loading usage..." : "no usage accounts found")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.accounts.enumerated()), id: \.element.id) { i, account in
                        UsageAccountRow(account: account, compact: compact)
                        if i < snapshot.accounts.count - 1 {
                            Rectangle().fill(UsagePalette.line).frame(height: 1)
                        }
                    }
                }
            }
        } else if let error = store.errorMessage {
            placeholder(error, action: "Choose Mac")
        } else {
            placeholder("connecting...")
        }
    }

    private func placeholder(_ text: String, action: String? = nil) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(UsagePalette.muted)
                .multilineTextAlignment(.center)
            if let action {
                Button(action) { showingPicker = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        // Re-evaluates staleness without a new fetch arriving.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(isHealthy(now: context.date) ? UsagePalette.okDot : UsagePalette.crit)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(store.errorMessage == nil ? UsagePalette.muted : UsagePalette.crit)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 30)
            .background(UsagePalette.statusBg)
        }
    }

    private func isHealthy(now: Date) -> Bool {
        guard store.errorMessage == nil, let updated = store.updatedAt else { return false }
        return now.timeIntervalSince(updated) <= UsageFormat.staleAfter
    }

    private var statusText: String {
        guard let endpoint = store.endpoint else { return "no Mac selected" }
        if let error = store.errorMessage, store.snapshot != nil {
            return "\(endpoint.displayName): \(error)"
        }
        guard let updated = store.updatedAt else { return endpoint.displayName }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "updated \(fmt.string(from: updated)) · \(endpoint.displayName)"
    }
}
