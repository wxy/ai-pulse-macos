import SwiftUI
import WidgetKit

struct AIPulseMacWidget: Widget {
    let kind = "AIPulseMacWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacWidgetProvider()) { entry in
            AIPulseMacWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Pulse · Mac")
        .description("Native Mac widget for today's AI coding activity.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

@main
struct AIPulseMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIPulseMacWidget()
    }
}

#if DEBUG
#Preview(as: .systemSmall) {
    AIPulseMacWidget()
} timeline: {
    MacWidgetProvider.previewEntry(at: .now)
    MacWidgetProvider.previewEntry(at: .now, staleSummary: true)
    MacWidgetProvider.previewEntry(at: .now, expiredPulse: true)
    MacWidgetProvider.previewEntry(at: .now, status: .noData)
}
#endif