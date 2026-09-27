// iOSWidget/MobileUsageWidgetBundle.swift
import SwiftUI
import WidgetKit

@main
struct MobileUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        MobileUsageWidget()
    }
}

struct MobileUsageWidget: Widget {
    let kind: String = UsageSnapshotStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MobileUsageTimelineProvider()) { entry in
            // An hour: the widget refreshes on WidgetKit's budget, so only a
            // Mac that stopped polling (or an unreachable one) should dim it.
            UsageWidgetView(entry: entry,
                            staleAfter: 3600,
                            emptyTitle: "No Mac selected",
                            emptyHint: "open Claude Monitor")
        }
        .configurationDisplayName("Claude Usage")
        .description("Usage limits from Claude Monitor on your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
