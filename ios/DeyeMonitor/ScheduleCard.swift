import SwiftUI

/// YASNO planned outages: what's next, and an interactive timeline (yesterday → tomorrow) with the real
/// outages under the plan.
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
            let today0 = schedule.today?.start ?? Fmt.kyivCalendar.startOfDay(for: now)
            let last0 = schedule.tomorrow?.start ?? today0
            let cal = Fmt.kyivCalendar
            let yesterday0 = cal.date(byAdding: .day, value: -1, to: today0) ?? today0.addingTimeInterval(-86400)
            let days = [yesterday0, today0] + (last0 > today0 ? [last0] : [])
            let facts = actual(in: DateInterval(start: yesterday0, end: now), now: now)
            ScheduleTimeline(plan: planned, fact: facts, days: days, now: now)
            VStack(alignment: .leading, spacing: 4) {
                if let today = schedule.today { summary("Сьогодні", today) }
                if let tomorrow = schedule.tomorrow { summary("Завтра", tomorrow) }
                factLine(facts.filter { Fmt.kyivCalendar.isDate($0.end, inSameDayAs: now) || $0.end >= now }, now: now)
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


    /// Plan for every published day (a day without a schedule in force has no blocks).
    private var planned: [DateInterval] {
        [schedule.today, schedule.tomorrow].compactMap { $0 }.filter(\.applies).flatMap(\.intervals)
    }

    private func actual(in range: DateInterval, now: Date) -> [DateInterval] {
        var list = (stats?.outages ?? []).compactMap { o -> DateInterval? in
            let s = max(o.startDate, range.start), e = min(o.endDate ?? now, now)
            return e > s ? DateInterval(start: s, end: e) : nil
        }
        // The live feed knows about a fresh outage minutes before the 5-minute history does.
        if let live, live.gridOn == false, let since = live.sinceDate,
           !list.contains(where: { abs($0.start.timeIntervalSince(max(since, range.start))) < 600 }) {
            let s = max(since, range.start)
            if now > s { list.append(DateInterval(start: s, end: now)) }
        }
        return list.sorted { $0.start < $1.start }
    }

    private func summary(_ title: String, _ day: ScheduleDay) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            Text(!day.applies ? day.statusText
                 : day.intervals.isEmpty ? "без відключень"
                 : "план " + day.intervals.map { Fmt.slot($0) }.joined(separator: ", "))
                .font(.caption).foregroundStyle(day.applies && day.intervals.isEmpty ? Theme.good : .secondary).monospacedDigit()
        }
    }

    /// Exact times of what really happened today, e.g. "10:02–14:55, 19:34–зараз".
    @ViewBuilder private func factLine(_ actual: [DateInterval], now: Date) -> some View {
        if actual.isEmpty {
            Text("Сьогодні світло не вимикали").font(.caption).foregroundStyle(.secondary)
        } else {
            let parts = actual.map { i -> String in
                "\(Fmt.time(i.start))–\(i.end >= now.addingTimeInterval(-60) ? "зараз" : Fmt.time(i.end))"
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
