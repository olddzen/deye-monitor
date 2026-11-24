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
    let entry: PowerEntry

    private var live: Live? { entry.live }
    private var on: Bool { live?.gridOn == true }
    private var stale: Bool { live?.isStale ?? true }
    private var tint: Color { live == nil || stale ? Theme.warning : on ? Theme.good : Theme.critical }
    private var title: String { live == nil ? "Немає даних" : stale ? "Deye мовчить" : on ? "Світло є" : "Світла немає" }
    private var icon: String { live == nil || stale ? "wifi.slash" : on ? "bolt.fill" : "bolt.slash.fill" }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let since = live?.sinceDate, !stale {
                Text("\(on ? "💡" : "🔌") \(on ? "є" : "немає") ") + Text(since, style: .relative)
            } else {
                Text("\(on ? "💡 світло є" : "🔌 світла немає")")
            }
        case .accessoryCircular:
            Gauge(value: (live?.soc ?? 0) / 100) {
                Image(systemName: icon)
            } currentValueLabel: {
                Text(live?.soc.map { "\(Int($0))" } ?? "—")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(title, systemImage: icon).font(.headline).widgetAccentable()
                if let since = live?.sinceDate, !stale {
                    (Text("вже ") + Text(since, style: .relative)).font(.caption).monospacedDigit()
                }
                Text("🔋 \(live?.soc.map { "\(Int($0))%" } ?? "—")").font(.caption)
            }
        case .systemMedium:
            HStack(spacing: 14) {
                statusColumn
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    battery
                    todayStrip
                }
            }
            .containerBackground(for: .widget) { background }
        default:
            VStack(alignment: .leading, spacing: 6) {
                statusColumn
                Spacer(minLength: 0)
                battery
            }
            .containerBackground(for: .widget) { background }
        }
    }

    private var background: some View {
        LinearGradient(colors: [tint.opacity(0.22), Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(on && !stale ? "Мережа є" : stale ? "немає даних" : "Мережі немає")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
            if let since = live?.sinceDate, !stale {
                Text(since, style: .relative).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("з \(Fmt.time(since))").font(.caption2).foregroundStyle(.secondary)
            } else if let u = live?.updatedDate, stale {
                Text("дані о \(Fmt.time(u))").font(.caption).foregroundStyle(.secondary)
            } else if let e = entry.error {
                Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private var battery: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 4)
                Circle().trim(from: 0, to: CGFloat((live?.soc ?? 0) / 100))
                    .stroke(Theme.batteryColor(live?.soc), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(live?.soc.map { "\(Int($0))%" } ?? "—").font(.headline).monospacedDigit()
                if let h = live?.runtimeH, h > 0 {
                    Text("≈ \(Fmt.short(h * 3600))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var todayStrip: some View {
        let cal = Fmt.kyivCalendar
        let now = entry.date, dayStart = cal.startOfDay(for: now)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Сьогодні").font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) in CGFloat(d.timeIntervalSince(dayStart) / 86400) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.good.opacity(0.35)).frame(width: x(now))
                    ForEach(entry.outagesToday) { o in
                        let s = max(o.startDate, dayStart), e = min(o.endDate ?? now, now)
                        if e > s {
                            Capsule().fill(Theme.critical).frame(width: max(3, x(e) - x(s))).offset(x: x(s))
                        }
                    }
                }
            }
            .frame(height: 10)
            HStack {
                Text("00"); Spacer(); Text("12"); Spacer(); Text("24")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

#Preview(as: .systemMedium) {
    PowerWidget()
} timeline: {
    PowerEntry.placeholder
}
