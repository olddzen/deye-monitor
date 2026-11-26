import SwiftUI
import WidgetKit

@main
struct DeyeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PowerWidget()
        OutageLiveActivity()
        if #available(iOS 18.0, *) {
            PowerControl()
        }
    }
}

struct PowerEntry: TimelineEntry {
    let date: Date
    let live: Live?
    let outagesToday: [Outage]
    let error: String?
    var schedule: Schedule? = nil
    var week: WeekStats? = nil
    var days7: [DayRow] = []

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
            // iOS decides the real cadence; ask again in ~10 minutes, or right after a planned switch.
            var next = Date.now.addingTimeInterval(600)
            if let s = entry.schedule {
                let edges = s.mergedSlots.flatMap { [$0.start, $0.end] }.filter { $0 > .now }
                if let e = edges.min(), e < next { next = e.addingTimeInterval(30) }
            }
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load() async -> PowerEntry {
        do {
            let r = try await APIClient.shared.fetch()
            let dayStart = Fmt.kyivCalendar.startOfDay(for: .now)
            let today = (r.data?.outages ?? []).filter { ($0.endDate ?? .now) > dayStart }
            return PowerEntry(date: .now, live: r.live, outagesToday: today, error: nil, schedule: r.schedule,
                              week: r.data?.week, days7: Array((r.data?.daily30 ?? []).suffix(7)))
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
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
    /// Off by the schedule: when it should come back.
    private var plannedOn: Date? {
        guard state == .off, let end = entry.schedule?.plannedEnd(now: entry.date, since: since), end > entry.date else { return nil }
        return end
    }
    /// On: the next planned outage within a day.
    private var plannedOff: Date? {
        guard state == .on, let next = entry.schedule?.nextPlanned(after: entry.date),
              next.start.timeIntervalSince(entry.date) < 86400 else { return nil }
        return next.start
    }
    private var plannedLine: String? {
        if let on = plannedOn { return "увімкнуть о \(Fmt.time(on))" }
        if let off = plannedOff { return "вимкнуть \(Fmt.until(off, now: entry.date))" }
        return nil
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let on = plannedOn {
                Text("🔌 до \(Fmt.time(on)) · ") + Text(timerInterval: entry.date...on, countsDown: true)
            } else if let off = plannedOff {
                Text("💡 відкл. \(Fmt.until(off, now: entry.date))")
            } else if let since {
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
                if let on = plannedOn {
                    Text(timerInterval: entry.date...on, countsDown: true)
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                } else if let since {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                }
                Text([plannedLine, "\(live?.soc.map { "\(Int($0))%" } ?? "—")"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    status
                    Spacer(minLength: 4)
                    if let u = live?.updatedDate { freshness(u) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    battery
                    flowRow(compact: true)
                    Spacer(minLength: 0)
                    dayBar(title: "сьогодні", day: entry.schedule?.today, actual: entry.outagesToday)
                    dayBar(title: "завтра", day: entry.schedule?.tomorrow, actual: [])
                }
            }
            .containerBackground(for: .widget) { background }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    status
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(live?.soc.map { "\(Int($0))" } ?? "—")
                                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("%").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        }
                        Text(batteryMode).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                CapsuleMeter(fraction: (live?.soc ?? 0) / 100,
                             tint: (live?.soc ?? 100) < 20 ? Theme.critical : (live?.soc ?? 100) < 40 ? Theme.warning : state.accent,
                             height: 6)
                flowRow(compact: false)
                Divider().opacity(0.3)
                dayBar(title: "сьогодні", day: entry.schedule?.today, actual: entry.outagesToday)
                dayBar(title: "завтра", day: entry.schedule?.tomorrow, actual: [])
                Spacer(minLength: 0)
                if !entry.days7.isEmpty { weekBars }
                HStack {
                    if let w = entry.week {
                        Text("7 днів: \(Fmt.number(w.offH)) год без світла")
                    }
                    Spacer()
                    if let u = live?.updatedDate { freshness(u) }
                }
                .font(.caption2).foregroundStyle(.secondary)
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
            if let on = plannedOn {
                Text(timerInterval: entry.date...on, countsDown: true)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("увімкнуть о \(Fmt.time(on))").font(.caption2.weight(.semibold))
                if family != .systemSmall, let since {
                    (Text(family == .systemLarge ? "вимкнули о \(Fmt.time(since)) · " : "з \(Fmt.time(since)) · ")
                     + Text(timerInterval: since...Date.distantFuture, countsDown: false))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            } else if let since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("з \(Fmt.time(since))" + (plannedOff.map { " · відкл. \(Fmt.until($0, now: entry.date))" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
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

    /// Hours without power for each of the last 7 days (measured).
    private var weekBars: some View {
        let maxH = max(entry.days7.compactMap(\.offMin).max() ?? 0, 60) / 60
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(entry.days7) { d in
                let h = (d.offMin ?? 0) / 60
                VStack(spacing: 3) {
                    Text(h >= 0.1 ? Fmt.number(h) : "").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary).monospacedDigit()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(h > 0 ? Theme.critical.opacity(0.75) : Theme.good.opacity(0.35))
                        .frame(height: max(3, CGFloat(h / maxH) * 34))
                    Text(d.day.formatted(.dateTime.weekday(.narrow).locale(Fmt.uk)))
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 62, alignment: .bottom)
    }

    /// Time of the inverter data; orange with a warning when it is older than Deye's usual cadence.
    private func freshness(_ u: Date) -> some View {
        let old = entry.date.timeIntervalSince(u) > Fmt.staleAfter
        return Label("дані о \(Fmt.time(u))", systemImage: old ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(old ? .semibold : .regular))
            .foregroundStyle(old ? Theme.warning : .secondary)
            .lineLimit(1)
    }

    private var batteryMode: String {
        let bp = live?.batteryPower ?? 0
        if live?.gridOn == false, live?.soc != nil { return "розряд ≈ \(Int(live?.drawW ?? bp)) Вт" }
        if bp < -20 { return (live?.soc ?? 0) >= 99 ? "повна" : "заряд \(Int(-bp)) Вт" }
        if bp > 20 { return "розряд \(Int(bp)) Вт" }
        return "у спокої"
    }

    /// Grid · battery · flat, measured watts.
    private func flowRow(compact: Bool) -> some View {
        let gridOn = live?.gridOn == true
        let items: [(String, String, String)] = [
            ("bolt.fill", gridOn ? "\(Int(live?.gridPower ?? 0)) Вт" : "немає", "мережа"),
            ("battery.75percent", live?.soc == nil ? "—" : "\(Int(abs(live?.drawW ?? live?.batteryPower ?? 0))) Вт", "батарея"),
            ("house.fill", "\(Int(live?.load ?? 0)) Вт", "квартира"),
        ]
        return HStack(spacing: compact ? 8 : 0) {
            ForEach(items, id: \.2) { symbol, value, caption in
                if compact {
                    HStack(spacing: 3) {
                        Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(caption).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// One day: planned outages (dashed), real ones (solid), now marker; summary on the right.
    private func dayBar(title: String, day: ScheduleDay?, actual: [Outage]) -> some View {
        let now = entry.date
        let start = day?.start ?? Fmt.kyivCalendar.startOfDay(for: now)
        let planned = day?.applies == true ? day?.intervals ?? [] : []
        let summary: String = {
            guard let day else { return "" }
            guard day.applies else {
                return family == .systemMedium && day.status == "WaitingForSchedule" ? "ще немає" : day.statusText
            }
            return planned.isEmpty ? "без відключень"
                : planned.map(Fmt.slot)
                    .joined(separator: ", ")
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption2.weight(.semibold))
                Spacer()
                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) in CGFloat(min(max(d.timeIntervalSince(start) / 86400, 0), 1)) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    ForEach(planned, id: \.start) { i in
                        RoundedRectangle(cornerRadius: 3).fill(Theme.critical.opacity(0.22))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Theme.critical.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                            .frame(width: max(3, x(i.end) - x(i.start))).offset(x: x(i.start))
                    }
                    ForEach(actual) { o in
                        let s = max(o.startDate, start), e = min(o.endDate ?? now, now)
                        if e > s { Capsule().fill(Theme.critical).frame(width: max(3, x(e) - x(s)), height: 4).offset(x: x(s)) }
                    }
                    if now > start && now < start.addingTimeInterval(86400) {
                        Capsule().fill(.primary).frame(width: 2, height: 12).offset(x: x(now) - 1)
                    }
                }
            }
            .frame(height: 10)
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
