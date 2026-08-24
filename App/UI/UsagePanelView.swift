// App/UI/UsagePanelView.swift
import SwiftUI

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

private struct UsageAccountRow: View {
    let account: AccountUsage

    private static let metricsPerRow = 3

    private var metricRows: [[UsageMetric]] {
        let metrics = account.displayMetrics
        return stride(from: 0, to: metrics.count, by: Self.metricsPerRow).map {
            Array(metrics[$0..<min($0 + Self.metricsPerRow, metrics.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.name.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(1.8)
                    .foregroundStyle(UsagePalette.name)
                Text(account.provider.displayName.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(1.0)
                    .foregroundStyle(UsagePalette.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(UsagePalette.line, lineWidth: 1))
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
            ForEach(Array(metricRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 22) {
                    ForEach(row) { metric in
                        UsageMetricCellView(metric: metric)
                    }
                    // Pad short rows so cell widths stay consistent.
                    ForEach(0..<(Self.metricsPerRow - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageMetricCellView: View {
    let metric: UsageMetric

    private var pct: Int { metric.usedPct }

    private var barColor: Color {
        pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.sand
    }
    private var valueColor: Color {
        pct < 0 ? UsagePalette.idle : pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.text
    }

    private var footer: String {
        if pct < 0 { return "idle" }
        return [metric.resets, metric.detail ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.label)
                .font(.system(size: 9, weight: .medium))
                .kerning(1.3)
                .foregroundStyle(UsagePalette.muted)
                .lineLimit(1)
                // Long named-bucket labels end in the distinguishing duration
                // suffix ("… 5H" vs "… 7D") — keep the tail, drop the head.
                .truncationMode(.head)
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
            Text(footer)
                .font(.system(size: 11))
                .foregroundStyle(pct < 0 ? UsagePalette.idle : UsagePalette.reset)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
