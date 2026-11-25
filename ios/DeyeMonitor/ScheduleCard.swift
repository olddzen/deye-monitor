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
                DayBar(title: "Сьогодні", day: today, actual: actualToday(now: now), now: now)
            }
            if let tomorrow = schedule.tomorrow {
                DayBar(title: "Завтра", day: tomorrow, actual: [], now: now)
            }
            HStack(spacing: 14) {
                legend(Theme.critical.opacity(0.25), "за графіком", dashed: true)
                legend(Theme.critical, "фактично", dashed: false)
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
            line("bolt.slash.fill", "За графіком світла немає до \(endText(cur))",
                 "ще \(Fmt.duration(cur.end.timeIntervalSince(now)))")
        } else if let next = (slots + tomorrowSlots).first(where: { $0.start > now }) {
            let isToday = slots.contains(next)
            line("clock.fill", "Наступне: \(isToday ? "" : "завтра ")\(Fmt.time(next.start))–\(endText(next))",
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

    private func endText(_ i: DateInterval) -> String {
        Fmt.kyivCalendar.component(.hour, from: i.end) == 0 && i.end > i.start.addingTimeInterval(60) ? "24:00" : Fmt.time(i.end)
    }

    private func actualToday(now: Date) -> [DateInterval] {
        let start = Fmt.kyivCalendar.startOfDay(for: now)
        return (stats?.outages ?? []).compactMap { o in
            let s = max(o.startDate, start), e = min(o.endDate ?? now, now)
            return e > s ? DateInterval(start: s, end: e) : nil
        }
    }

    private func legend(_ color: Color, _ text: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Theme.critical.opacity(dashed ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                .frame(width: 14, height: 8)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct DayBar: View {
    let title: String
    let day: ScheduleDay
    let actual: [DateInterval]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(day.applies ? (day.intervals.isEmpty ? "без відключень" : summary) : day.statusText)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                let w = geo.size.width
                let start = day.start ?? Fmt.kyivCalendar.startOfDay(for: now)
                let x = { (d: Date) in CGFloat(min(max(d.timeIntervalSince(start) / 86400, 0), 1)) * w }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(day.applies ? 0.06 : 0.03))
                    ForEach(day.intervals, id: \.start) { i in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.critical.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Theme.critical.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .frame(width: max(4, x(i.end) - x(i.start)))
                            .offset(x: x(i.start))
                    }
                    ForEach(actual, id: \.start) { i in
                        Capsule().fill(Theme.critical)
                            .frame(width: max(3, x(i.end) - x(i.start)), height: 6)
                            .offset(x: x(i.start))
                    }
                    if (start...start.addingTimeInterval(86400)).contains(now) {
                        Capsule().fill(.primary).frame(width: 2, height: 22).offset(x: x(now) - 1)
                    }
                }
            }
            .frame(height: 18)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { h in
                    Text(h).font(.caption2).foregroundStyle(.tertiary)
                    if h != "24" { Spacer() }
                }
            }
        }
    }

    private var summary: String {
        day.intervals.map { "\(Fmt.time($0.start))–\(Fmt.kyivCalendar.component(.hour, from: $0.end) == 0 ? "24:00" : Fmt.time($0.end))" }
            .joined(separator: ", ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
