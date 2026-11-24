import SwiftUI
import WidgetKit

@main
struct DeyeWatchWidgetsBundle: WidgetBundle {
    var body: some Widget { WatchPowerComplication() }
}

struct WatchEntry: TimelineEntry {
    let date: Date
    let live: Live?
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: .now, live: nil) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        Task { completion(WatchEntry(date: .now, live: try? await APIClient.shared.fetch().live)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        Task {
            let entry = WatchEntry(date: .now, live: try? await APIClient.shared.fetch().live)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
        }
    }
}

struct WatchPowerComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchPower", provider: WatchProvider()) { entry in
            WatchComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Світло")
        .description("Чи є світло і заряд батареї.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct WatchComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchEntry

    var body: some View {
        let state = PowerState(entry.live)
        let soc = entry.live?.soc
        let since = state == .unknown ? nil : entry.live?.sinceDate
        switch family {
        case .accessoryCircular:
            Gauge(value: (soc ?? 0) / 100) {
                Image(systemName: state.symbol)
            } currentValueLabel: {
                Image(systemName: state.symbol).foregroundStyle(state.accent)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(state.accent)
        case .accessoryCorner:
            Image(systemName: state.symbol)
                .font(.title3)
                .foregroundStyle(state.accent)
                .widgetLabel { Gauge(value: (soc ?? 0) / 100) { Text("") }.tint(state.accent) }
        case .accessoryInline:
            if let since {
                Text("\(state == .on ? "💡" : "🔌") ") + Text(since, style: .relative)
            } else {
                Text(state.title)
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                Label(state.title, systemImage: state.symbol).font(.headline).foregroundStyle(state.accent)
                if let since {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                Text("батарея \(soc.map { "\(Int($0))%" } ?? "—")").font(.caption)
            }
        }
    }
}
