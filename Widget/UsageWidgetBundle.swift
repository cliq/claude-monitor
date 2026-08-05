import SwiftUI
import WidgetKit

@main
struct UsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageWidget: Widget {
    let kind: String = UsageSnapshotStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code usage limits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
