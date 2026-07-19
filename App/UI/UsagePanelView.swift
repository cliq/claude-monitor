// App/UI/UsagePanelView.swift
import SwiftUI

/// Same palette and layout as the ESP32 desk panel (480x480 design), so the
/// in-app view and the external display read identically. Distinct from
/// `Palette` (session tile colors) — these are the usage panel's fixed colors.
enum UsagePalette {
    static let bg = RGB(0x14110D).color
    static let statusBg = RGB(0x0F0D0A).color
    static let line = RGB(0x241F19).color
    static let text = RGB(0xEDE6DB).color
    static let muted = RGB(0x6E6558).color
    static let reset = RGB(0x8A8072).color
    static let idle = RGB(0x55503F).color
    static let name = RGB(0xD97757).color
    static let sand = RGB(0xC9BFAF).color
    static let warn = RGB(0xE3A455).color
    static let crit = RGB(0xE25A3F).color
    static let track = RGB(0x262119).color
    static let okDot = RGB(0x8FAE6E).color
}

struct UsagePanelView: View {
    @ObservedObject var poller: UsagePoller

    var body: some View {
        VStack(spacing: 0) {
            if poller.accounts.isEmpty {
                emptyState
            } else {
                ForEach(Array(poller.accounts.enumerated()), id: \.element.id) { i, account in
                    UsageAccountRow(account: account)
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
        Text(poller.updatedAt == nil ? "loading usage..." : "no Claude Code accounts found")
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
        return Date().timeIntervalSince(updated) > UsagePoller.pollInterval * 3
    }

    private var statusText: String {
        guard let updated = poller.updatedAt else { return "connecting..." }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "updated \(fmt.string(from: updated))"
    }
}

private struct UsageAccountRow: View {
    let account: AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.name.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(1.8)
                    .foregroundStyle(UsagePalette.name)
                Text(account.plan)
                    .font(.system(size: 9, weight: .medium))
                    .kerning(1.1)
                    .foregroundStyle(UsagePalette.muted)
                if account.status == "error" {
                    Text(account.error ?? "error")
                        .font(.system(size: 9))
                        .foregroundStyle(UsagePalette.crit)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .top, spacing: 22) {
                UsageMetricCell(label: "SESSION", pct: account.sessionPct, resets: account.sessionResets)
                UsageMetricCell(label: "WEEKLY", pct: account.weeklyPct, resets: account.weeklyResets)
                UsageMetricCell(label: account.modelLabel.isEmpty ? "MODEL" : account.modelLabel,
                                pct: account.modelPct, resets: account.modelResets)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageMetricCell: View {
    let label: String
    let pct: Int
    let resets: String

    private var barColor: Color {
        pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.sand
    }
    private var valueColor: Color {
        pct < 0 ? UsagePalette.idle : pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .kerning(1.3)
                .foregroundStyle(UsagePalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(pct < 0 ? "-" : "\(pct)")
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                if pct >= 0 {
                    Text("%")
                        .font(.system(size: 15))
                        .foregroundStyle(UsagePalette.muted)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsagePalette.track)
                    if pct > 0 {
                        Capsule().fill(barColor)
                            .frame(width: geo.size.width * CGFloat(min(pct, 100)) / 100)
                    }
                }
            }
            .frame(height: 5)
            Text(pct < 0 ? "idle" : resets)
                .font(.system(size: 11))
                .foregroundStyle(pct < 0 ? UsagePalette.idle : UsagePalette.reset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
