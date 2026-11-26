import SwiftUI

/// YASNO planned outages: what's next, will the battery cover it, and today/tomorrow on a 24-hour bar
/// with the real outages laid over the plan.
struct ScheduleCard: View {
    let schedule: Schedule
    let live: Live?
    let stats: Stats?

    var body: some View {
        let now = Date.now
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Графік · група \(schedule.group)")
                Spacer()
                Text("YASNO").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            headline(now: now)
            if let today = schedule.today {
                DayBar(title: "Сьогодні", day: today, actual: actualToday(now: now), now: now, showsActual: true)
            }
            if let tomorrow = schedule.tomorrow {
                DayBar(title: "Завтра", day: tomorrow, actual: [], now: now)
            }
        }
        .glassCard()
    }

    // MARK: headline

    @ViewBuilder private func headline(now: Date) -> some View {
        let today = schedule.today
        let slots = (today?.applies == true ? today?.intervals : nil) ?? []
        let tomorrowSlots = (schedule.tomorrow?.applies == true ? schedule.tomorrow?.intervals : nil) ?? []
        if let today, !today.applies {
            line("calendar.badge.clock", today.statusText.capitalizedFirst, nil)
        } else if let cur = slots.first(where: { $0.contains(now) }) {
            line("bolt.slash.fill", "За графіком світла немає до \(Fmt.slotEnd(cur))",
                 "ще \(Fmt.duration(cur.end.timeIntervalSince(now)))")
        } else if let next = (slots + tomorrowSlots).first(where: { $0.start > now }) {
            let isToday = slots.contains(next)
            line("clock.fill", "Наступне: \(isToday ? "" : "завтра ")\(Fmt.slot(next))",
                 "через \(Fmt.duration(next.start.timeIntervalSince(now))) · триватиме \(Fmt.duration(next.duration))")
        } else {
            line("checkmark.circle.fill", "Сьогодні більше відключень немає",
                 schedule.tomorrow?.applies == true ? "завтра без відключень" : schedule.tomorrow.map { "завтра: \($0.statusText)" })
        }
    }

    private func line(_ symbol: String, _ title: String, _ subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(symbol == "checkmark.circle.fill" ? Theme.good : Theme.critical)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).monospacedDigit()
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }


    private func actualToday(now: Date) -> [DateInterval] {
        let start = Fmt.kyivCalendar.startOfDay(for: now)
        var list = (stats?.outages ?? []).compactMap { o -> DateInterval? in
            let s = max(o.startDate, start), e = min(o.endDate ?? now, now)
            return e > s ? DateInterval(start: s, end: e) : nil
        }
        // The live feed knows about a fresh outage minutes before the 5-minute history does.
        if let live, live.gridOn == false, let since = live.sinceDate,
           !list.contains(where: { abs($0.start.timeIntervalSince(max(since, start))) < 600 }) {
            let s = max(since, start)
            if now > s { list.append(DateInterval(start: s, end: now)) }
        }
        return list.sorted { $0.start < $1.start }
    }
}

private struct DayBar: View {
    let title: String
    let day: ScheduleDay
    let actual: [DateInterval]
    let now: Date
    /// Today shows a second lane with what really happened; tomorrow only has the plan.
    var showsActual = false

    private let laneLabel: CGFloat = 34

    var body: some View {
        let start = day.start ?? Fmt.kyivCalendar.startOfDay(for: now)
        let isToday = (start...start.addingTimeInterval(86400)).contains(now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if !day.applies {
                    Text(day.statusText).font(.caption).foregroundStyle(.secondary)
                } else if day.intervals.isEmpty {
                    Text("без відключень").font(.caption.weight(.semibold)).foregroundStyle(Theme.good)
                } else {
                    Text("план: " + day.intervals.map { Fmt.slot($0) }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if day.applies {
                lane("план", start: start, isToday: isToday) { x in
                    ForEach(day.intervals, id: \.start) { i in
                        block(x: x, i, fill: Theme.critical.opacity(0.22), stroke: Theme.critical.opacity(0.7), dashed: true,
                              label: Fmt.slot(i))
                    }
                }
                if showsActual {
                    lane("факт", start: start, isToday: isToday) { x in
                        ForEach(actual, id: \.start) { i in
                            block(x: x, i, fill: Theme.critical, stroke: .clear, dashed: false,
                                  label: Fmt.time(i.start), labelColor: .white)
                        }
                    }
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: laneLabel)
                    ForEach(["00", "06", "12", "18", "24"], id: \.self) { h in
                        Text(h).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        if h != "24" { Spacer() }
                    }
                }
                if showsActual {
                    factLine
                }
            }
        }
    }

    /// One 24-hour lane with a label on the left and a "now" line when it is today.
    private func lane<Content: View>(_ label: String, start: Date, isToday: Bool,
                                     @ViewBuilder content: @escaping (@escaping (Date) -> CGFloat) -> Content) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: laneLabel, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) in CGFloat(min(max(d.timeIntervalSince(start) / 86400, 0), 1)) * w }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.07))
                    // Hour grid every 3 hours so a block's edges can be read at a glance.
                    ForEach(1..<8) { k in
                        Rectangle().fill(.primary.opacity(k % 2 == 0 ? 0.14 : 0.07))
                            .frame(width: 1).offset(x: w * CGFloat(k) / 8)
                    }
                    content(x)
                    if isToday {
                        Capsule().fill(.primary).frame(width: 2.5).padding(.vertical, -3).offset(x: x(now) - 1.25)
                    }
                }
            }
            .frame(height: 24)
        }
    }

    private func block(x: (Date) -> CGFloat, _ i: DateInterval, fill: Color, stroke: Color, dashed: Bool,
                       label: String, labelColor: Color = .primary) -> some View {
        let width = max(4, x(i.end) - x(i.start))
        return RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [4, 2] : [])))
            .overlay(alignment: .leading) {
                if width > 70 {
                    Text(label).font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(labelColor).lineLimit(1).padding(.leading, 6)
                }
            }
            .frame(width: width)
            .offset(x: x(i.start))
    }

    /// Exact times of what really happened today, e.g. "10:02–14:55 · 19:34–зараз".
    @ViewBuilder private var factLine: some View {
        if actual.isEmpty {
            Text("Сьогодні світло не вимикали").font(.caption).foregroundStyle(.secondary)
        } else {
            let parts = actual.map { i -> String in
                let ongoing = i.end >= now.addingTimeInterval(-60)
                return "\(Fmt.time(i.start))–\(ongoing ? "зараз" : Fmt.time(i.end))"
            }
            HStack(spacing: 6) {
                Image(systemName: "bolt.slash.fill").font(.caption2).foregroundStyle(Theme.critical)
                Text("Фактично без світла: " + parts.joined(separator: ", "))
                    .font(.caption.weight(.medium)).monospacedDigit()
            }
        }
    }

}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
