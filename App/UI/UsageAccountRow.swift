// App/UI/UsageAccountRow.swift
import SwiftUI

// One account's block in the usage panel. Pure SwiftUI over `AccountUsage` —
// shared by the macOS usage panel and the iOS app, so keep AppKit/UIKit out.

struct UsageAccountRow: View {
    let account: AccountUsage
    /// Compact: one row per account — name column on the left, small metric
    /// cells on the right — at roughly a third of the regular height.
    let compact: Bool

    private static let metricsPerRow = 3

    private var metricRows: [[UsageMetric]] {
        let metrics = account.displayMetrics
        return stride(from: 0, to: metrics.count, by: Self.metricsPerRow).map {
            Array(metrics[$0..<min($0 + Self.metricsPerRow, metrics.count)])
        }
    }

    /// Muted account-level facts that are not errors: the provider's note
    /// (credit balance) and unredeemed Codex reset grants. A grant that
    /// lapses within a week is called out in red.
    private struct InfoLine {
        var text: String
        var warning: Bool
    }

    private var infoLine: InfoLine? {
        var parts: [String] = []
        var warning = false
        if let note = account.note, !note.isEmpty { parts.append(note) }
        if let resets = account.resetCredits, resets > 0 {
            let noun = resets == 1 ? "1 reset" : "\(resets) resets"
            if UsageFormat.isWithin(days: 7, account.resetCreditsExpireAt) {
                warning = true
                parts.append("\(noun) expires \(UsageFormat.formatReset(account.resetCreditsExpireAt))")
            } else {
                parts.append("\(noun) available")
            }
        }
        return parts.isEmpty ? nil : InfoLine(text: parts.joined(separator: " · "), warning: warning)
    }

    var body: some View {
        Group {
            if compact { compactBody } else { regularBody }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.name.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(1.8)
                    .foregroundStyle(UsagePalette.name)
                providerBadge
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
                if let info = infoLine {
                    Text(info.text)
                        .font(.system(size: 10))
                        .foregroundStyle(info.warning ? UsagePalette.crit : UsagePalette.muted)
                        .lineLimit(1)
                }
            }
            metricGrid(spacing: 22)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(UsagePalette.name)
                    .lineLimit(1)
                // Business seats carry two-word plans ("BUSINESS PREMIUM")
                // that overflow the fixed column — wrap rather than truncate.
                Text([account.provider.displayName.uppercased(), account.plan]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    .font(.system(size: 8, weight: .medium))
                    .kerning(0.8)
                    .foregroundStyle(UsagePalette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let info = infoLine {
                    Text(info.text)
                        .font(.system(size: 9))
                        .foregroundStyle(info.warning ? UsagePalette.crit : UsagePalette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 96, alignment: .leading)
            if account.status == "error" {
                Text(account.error ?? "error")
                    .font(.system(size: 10))
                    .foregroundStyle(UsagePalette.crit)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                metricGrid(spacing: 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var providerBadge: some View {
        Text(account.provider.displayName.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .kerning(1.0)
            .foregroundStyle(UsagePalette.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(UsagePalette.line, lineWidth: 1))
    }

    private func metricGrid(spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(Array(metricRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row) { metric in
                        UsageMetricCellView(metric: metric, compact: compact)
                    }
                    // Pad short rows so cell widths stay consistent.
                    ForEach(0..<(Self.metricsPerRow - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }
}

struct UsageMetricCellView: View {
    let metric: UsageMetric
    let compact: Bool

    private var pct: Int { metric.usedPct }

    private var barColor: Color {
        pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.sand
    }
    private var valueColor: Color {
        pct < 0 ? UsagePalette.idle : pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.text
    }

    /// Reset time on one line, the optional detail ("1427 / 0 credits") on a
    /// second — joined on one line the pair truncates in every layout.
    private var footerLines: [String] {
        if pct < 0 { return ["idle"] }
        return [metric.resets, metric.detail ?? ""].filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func footer(size: CGFloat) -> some View {
        ForEach(footerLines, id: \.self) { line in
            Text(line)
                .font(.system(size: size))
                .foregroundStyle(pct < 0 ? UsagePalette.idle : UsagePalette.reset)
                .lineLimit(1)
        }
    }

    var body: some View {
        if compact { compactBody } else { regularBody }
    }

    private var regularBody: some View {
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
            bar(height: 5)
            footer(size: 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label and value share one line; the bar and reset time sit beneath.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.label)
                    .font(.system(size: 9, weight: .medium))
                    .kerning(1.0)
                    .foregroundStyle(UsagePalette.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(pct < 0 ? "-" : "\(pct)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                    if pct >= 0 {
                        Text("%")
                            .font(.system(size: 9))
                            .foregroundStyle(UsagePalette.muted)
                    }
                }
            }
            bar(height: 3)
            footer(size: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(UsagePalette.track)
                if pct > 0 {
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * CGFloat(min(pct, 100)) / 100)
                }
            }
        }
        .frame(height: height)
    }
}
