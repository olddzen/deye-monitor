import SwiftUI
import WidgetKit

@main
struct DeyeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PowerWidget()
    }
}

struct PowerEntry: TimelineEntry {
    let date: Date
    let live: Live?
    let outagesToday: [Outage]
    let error: String?

    static let placeholder = PowerEntry(date: .now, live: nil, outagesToday: [], error: nil)
}

struct PowerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PowerEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PowerEntry) -> Void) {
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PowerEntry>) -> Void) {
        Task {
            let entry = await load()
            // iOS decides the real cadence; ask again in ~10 minutes.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(600))))
        }
    }

    private func load() async -> PowerEntry {
        do {
            let r = try await APIClient.shared.fetch()
            let dayStart = Fmt.kyivCalendar.startOfDay(for: .now)
            let today = (r.data?.outages ?? []).filter { ($0.endDate ?? .now) > dayStart }
            return PowerEntry(date: .now, live: r.live, outagesToday: today, error: nil)
        } catch {
            return PowerEntry(date: .now, live: nil, outagesToday: [], error: error.localizedDescription)
        }
    }
}

struct PowerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PowerWidget", provider: PowerProvider()) { entry in
            PowerWidgetView(entry: entry)
                .environment(\.locale, Fmt.uk)
        }
        .configurationDisplayName("Світло і батарея")
        .description("Чи є світло, відколи, і заряд батареї Deye.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct PowerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: PowerEntry

    private var live: Live? { entry.live }
    private var state: PowerState { PowerState(live) }
    private var since: Date? {
        guard state != .unknown else { return nil }
        if let s = live?.sinceDate { return s }
        return entry.outagesToday.last(where: { $0.end == nil })?.startDate
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let since {
                Text("\(state == .on ? "💡" : "🔌") ") + Text(since, style: .relative)
            } else {
                Text(state.title)
            }
        case .accessoryCircular:
            Gauge(value: (live?.soc ?? 0) / 100) {
                Image(systemName: state.symbol)
            } currentValueLabel: {
                Text(live?.soc.map { "\(Int($0))" } ?? "—")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Label(state.title, systemImage: state.symbol).font(.headline).widgetAccentable()
                if let since {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                Text("батарея \(live?.soc.map { "\(Int($0))%" } ?? "—")").font(.caption)
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                status
                VStack(alignment: .leading, spacing: 10) {
                    battery
                    Spacer(minLength: 0)
                    today
                }
            }
            .containerBackground(for: .widget) { background }
        default:
            VStack(alignment: .leading, spacing: 0) {
                status
                Spacer(minLength: 6)
                battery
            }
            .containerBackground(for: .widget) { background }
        }
    }

    private var background: some View {
        let base = scheme == .dark ? Color(hex: 0x111213) : Color(hex: 0xf7f7f4)
        return ZStack {
            base
            RadialGradient(colors: [state.accent.opacity(scheme == .dark ? 0.55 : 0.32), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 170)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: state.symbol).foregroundStyle(state.accent)
                Text(state.title).font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            if let since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("з \(Fmt.time(since))").font(.caption2).foregroundStyle(.secondary)
            } else if let u = live?.updatedDate {
                Text("дані о \(Fmt.time(u))").font(.caption).foregroundStyle(.secondary)
            } else if let e = entry.error {
                Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var battery: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(live?.soc.map { "\(Int($0))" } ?? "—").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                if let h = live?.runtimeH, h > 0 {
                    Text("≈ \(Fmt.short(h * 3600))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            CapsuleMeter(fraction: (live?.soc ?? 0) / 100,
                         tint: (live?.soc ?? 100) < 20 ? Theme.critical : (live?.soc ?? 100) < 40 ? Theme.warning : state.accent,
                         height: 6)
        }
    }

    private var today: some View {
        let cal = Fmt.kyivCalendar
        let now = entry.date, dayStart = cal.startOfDay(for: now)
        return VStack(alignment: .leading, spacing: 4) {
            Text("сьогодні").font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) in CGFloat(d.timeIntervalSince(dayStart) / 86400) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(Theme.good.opacity(0.4)).frame(width: max(4, x(now)))
                    ForEach(entry.outagesToday) { o in
                        let s = max(o.startDate, dayStart), e = min(o.endDate ?? now, now)
                        if e > s {
                            Capsule().fill(Theme.critical).frame(width: max(3, x(e) - x(s))).offset(x: x(s))
                        }
                    }
                }
            }
            .frame(height: 6)
        }
    }
}

#Preview(as: .systemMedium) {
    PowerWidget()
} timeline: {
    PowerEntry.placeholder
}
