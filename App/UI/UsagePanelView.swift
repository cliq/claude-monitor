// App/UI/UsagePanelView.swift
import SwiftUI

struct UsagePanelView: View {
    @ObservedObject var poller: UsagePoller
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            if poller.accounts.isEmpty {
                emptyState
            } else {
                ForEach(Array(poller.accounts.enumerated()), id: \.element.id) { i, account in
                    UsageAccountRow(account: account, compact: preferences.usagePanelCompact)
                    if i < poller.accounts.count - 1 {
                        Rectangle().fill(UsagePalette.line).frame(height: 1)
                    }
                }
            }
            statusBar
        }
        .frame(width: 480)
        .background(UsagePalette.bg)
    }

    private var emptyState: some View {
        Text(poller.updatedAt == nil ? "loading usage..." : "no usage accounts found")
            .font(.system(size: 12))
            .foregroundStyle(UsagePalette.muted)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isStale ? UsagePalette.crit : UsagePalette.okDot)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(UsagePalette.muted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(UsagePalette.statusBg)
    }

    private var isStale: Bool {
        guard let updated = poller.updatedAt else { return false }
        return Date().timeIntervalSince(updated) > UsageFormat.staleAfter
    }

    private var statusText: String {
        guard let updated = poller.updatedAt else { return "connecting..." }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "updated \(fmt.string(from: updated))"
    }
}
