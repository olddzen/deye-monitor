import SwiftUI
import WidgetKit

@main
struct DeyeWatchWidgetsBundle: WidgetBundle {
    var body: some Widget { WatchPowerComplication() }
}

struct WatchEntry: TimelineEntry {
    let date: Date
    let live: Live?
    var schedule: Schedule? = nil
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: .now, live: nil) }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        Task { completion(await Self.entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        Task {
            let entry = await Self.entry()
            var next = Date.now.addingTimeInterval(900)
            if let e = entry.schedule?.mergedSlots.flatMap({ [$0.start, $0.end] }).filter({ $0 > .now }).min(), e < next {
                next = e.addingTimeInterval(30)  // refresh right after a planned switch
            }
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    static func entry() async -> WatchEntry {
        let r = try? await APIClient.shared.fetch()
        return WatchEntry(date: .now, live: r?.live, schedule: r?.schedule)
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
        let plannedOn = state == .off ? entry.schedule?.plannedEnd(now: entry.date, since: since).flatMap { $0 > entry.date ? $0 : nil } : nil
        let plannedOff = state == .on ? entry.schedule?.nextPlanned(after: entry.date)
            .flatMap { $0.start.timeIntervalSince(entry.date) < 86400 ? $0.start : nil } : nil
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
            if let on = plannedOn {
                Text("🔌 до \(Fmt.time(on))")
            } else if let off = plannedOff {
                Text("💡 відкл. о \(Fmt.time(off))")
            } else if let since {
                Text("\(state == .on ? "💡" : "🔌") ") + Text(since, style: .relative)
            } else {
                Text(state.title)
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                Label(state.title, systemImage: state.symbol).font(.headline).foregroundStyle(state.accent)
                if let on = plannedOn {
                    Text(timerInterval: entry.date...on, countsDown: true)
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text("увімкнуть о \(Fmt.time(on)) · \(soc.map { "\(Int($0))%" } ?? "—")").font(.caption)
                } else {
                    if let since {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    }
                    Text([plannedOff.map { "відкл. о \(Fmt.time($0))" }, "батарея \(soc.map { "\(Int($0))%" } ?? "—")"]
                        .compactMap { $0 }.joined(separator: " · ")).font(.caption)
                }
            }
        }
    }
}
