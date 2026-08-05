// Widget/UsageWidgetView.swift
import SwiftUI
import WidgetKit

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(for: snapshot)
            } else {
                emptyState
            }
        }
        .containerBackground(UsagePalette.bg, for: .widget)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Usage monitoring off")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UsagePalette.muted)
            Text("open ClaudeMonitor")
                .font(.system(size: 9))
                .foregroundStyle(UsagePalette.idle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for snapshot: UsageSnapshot) -> some View {
        let updated = parseDate(snapshot.updatedAt)
        let isStale = entry.date.timeIntervalSince(updated ?? .distantPast) > UsageFormat.staleAfter

        switch family {
        case .systemSmall:
            if let account = snapshot.accounts.first {
                UsageAccountBlock(account: account, now: entry.date, isStale: isStale, compact: true, metrics: [.session, .weekly])
                    .padding(12)
            } else {
                emptyState
            }
        case .systemMedium:
            if let account = snapshot.accounts.first {
                UsageAccountBlock(account: account, now: entry.date, isStale: isStale, compact: false, metrics: [.session, .weekly, .model])
                    .padding(14)
            } else {
                emptyState
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                let accounts = Array(snapshot.accounts.prefix(4))
                if accounts.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { i, account in
                        UsageAccountBlock(
                            account: account,
                            now: entry.date,
                            isStale: isStale,
                            compact: false,
                            metrics: [.session, .weekly, .model]
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if i < accounts.count - 1 {
                            Rectangle().fill(UsagePalette.line).frame(height: 1)
                        }
                    }
                }
                Spacer(minLength: 0)
                Rectangle().fill(UsagePalette.line).frame(height: 1)
                statusLine(updated: updated, isStale: isStale)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    private func statusLine(updated: Date?, isStale: Bool) -> some View {
        Text(statusText(updated: updated, isStale: isStale))
            .font(.system(size: 8))
            .foregroundStyle(UsagePalette.muted)
    }

    private func statusText(updated: Date?, isStale: Bool) -> String {
        guard let updated else { return "updated —" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = entry.date.timeIntervalSince(updated) > 86400 ? "E HH:mm" : "HH:mm"
        let prefix = isStale ? "as of" : "updated"
        return "\(prefix) \(fmt.string(from: updated))"
    }

    private func parseDate(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: iso) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: iso)
    }
}

private enum UsageMetricKind {
    case session, weekly, model
}

private struct UsageAccountBlock: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let account: AccountUsage
    let now: Date
    let isStale: Bool
    let compact: Bool
    let metrics: [UsageMetricKind]

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(UsagePalette.name)
                Spacer()
                Circle()
                    .fill(account.status == "error" || isStale ? UsagePalette.crit : UsagePalette.okDot)
                    // Monochrome mode renders both dot colors as the same white;
                    // dim the ok state so error/stale still stands out.
                    .opacity(renderingMode == .fullColor || account.status == "error" || isStale ? 1 : 0.45)
                    .frame(width: 5, height: 5)
            }
            if account.status == "error" {
                Text(account.error ?? "error")
                    .font(.system(size: 8))
                    .foregroundStyle(UsagePalette.crit)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: compact ? 10 : 14) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, kind in
                    metricCell(for: kind)
                }
            }
        }
    }

    @ViewBuilder
    private func metricCell(for kind: UsageMetricKind) -> some View {
        switch kind {
        case .session:
            UsageMetricCell(label: "SESSION", pct: account.sessionPct,
                             resetLabel: resetLabel(iso: account.sessionResetsAt, fallback: account.sessionResets),
                             isStale: isStale)
        case .weekly:
            UsageMetricCell(label: "WEEKLY", pct: account.weeklyPct,
                             resetLabel: resetLabel(iso: account.weeklyResetsAt, fallback: account.weeklyResets),
                             isStale: isStale)
        case .model:
            UsageMetricCell(label: account.modelLabel.isEmpty ? "MODEL" : account.modelLabel, pct: account.modelPct,
                             resetLabel: resetLabel(iso: account.modelResetsAt, fallback: account.modelResets),
                             isStale: isStale)
        }
    }

    private func resetLabel(iso: String?, fallback: String) -> String {
        guard let iso else { return fallback }
        return UsageFormat.formatReset(iso, now: now)
    }
}

private struct UsageMetricCell: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let label: String
    let pct: Int
    let resetLabel: String
    let isStale: Bool

    private var valueSize: CGFloat {
        family == .systemLarge ? 16 : 20
    }

    // In monochrome ("vibrant") rendering the system remaps every color to a
    // white material weighted by luminance — the dark track and light fill
    // flatten to the same white and every bar reads as 100%. Opacity survives
    // the remap, so non-full-color modes use opacity contrast instead.
    private var trackStyle: AnyShapeStyle {
        renderingMode == .fullColor
            ? AnyShapeStyle(UsagePalette.track)
            : AnyShapeStyle(.white.opacity(0.25))
    }
    private var fillStyle: AnyShapeStyle {
        renderingMode == .fullColor ? AnyShapeStyle(barColor) : AnyShapeStyle(.white)
    }

    private var barColor: Color {
        pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.sand
    }
    private var valueColor: Color {
        pct < 0 ? UsagePalette.idle : pct >= 85 ? UsagePalette.crit : pct >= 60 ? UsagePalette.warn : UsagePalette.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 7, weight: .medium))
                .kerning(1.0)
                .foregroundStyle(UsagePalette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(pct < 0 ? "-" : "\(pct)")
                    .font(.system(size: valueSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                if pct >= 0 {
                    Text("%")
                        .font(.system(size: valueSize * 0.6))
                        .foregroundStyle(UsagePalette.muted)
                }
            }
            .opacity(isStale ? 0.55 : 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(trackStyle)
                    if pct > 0 {
                        Capsule().fill(fillStyle)
                            .frame(width: geo.size.width * CGFloat(min(pct, 100)) / 100)
                    }
                }
            }
            .frame(height: 3)
            .opacity(isStale ? 0.55 : 1)
            Text(pct < 0 ? "idle" : resetLabel)
                .font(.system(size: 7))
                .foregroundStyle(pct < 0 ? UsagePalette.idle : UsagePalette.reset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
