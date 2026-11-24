import SwiftUI

/// Month-style calendar of the last 30 days: darker = longer without power.
struct OutageCalendar: View, Equatable {
    let days: [DayRow]
    let version: Double
    @State private var picked: String?

    static func == (a: OutageCalendar, b: OutageCalendar) -> Bool { a.version == b.version }

    private let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]

    var body: some View {
        let cal = Fmt.kyivCalendar
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let first = days.first?.day ?? .now
        // start the grid on the Monday on or before the first day
        let lead = (cal.component(.weekday, from: first) + 5) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: cal.startOfDay(for: first)) ?? first
        let cells = (0..<35).map { cal.date(byAdding: .day, value: $0, to: start) ?? start }
        let maxMin = max(60, days.compactMap(\.offMin).max() ?? 60)
        let today = Fmt.isoDay.string(from: .now)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Календар відключень")
                Spacer()
                Text("30 днів").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(weekdays, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                ForEach(cells, id: \.self) { d in
                    let key = Fmt.isoDay.string(from: d)
                    let row = byDate[key]
                    let off = row?.offMin ?? 0
                    let has = row?.hasData == true
                    let fill: Color = !has ? Color.primary.opacity(0.04)
                        : off > 0 ? Theme.seqColor(min(1, off / maxMin)) : PowerState.on.accent.opacity(0.18)
                    Button { picked = key } label: {
                        Text("\(cal.component(.day, from: d))")
                            .font(.caption.weight(key == today ? .bold : .medium)).monospacedDigit()
                            .foregroundStyle(row == nil ? Color.secondary.opacity(0.4) : off / maxMin > 0.5 ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(picked == key ? Color.primary : key == today ? Color.primary.opacity(0.3) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(row == nil)
                }
            }
            Group {
                if let p = picked, let row = byDate[p] {
                    Text("\(Fmt.dayMonth(row.day)): " + (row.hasData == true
                        ? ((row.offMin ?? 0) > 0 ? "без світла \(Fmt.duration((row.offMin ?? 0) * 60))" : "світло було весь день")
                        : "немає даних")
                        + (row.loadKwh.map { " · спожито \(Fmt.number($0)) кВт·год" } ?? ""))
                } else {
                    Text("Зелений — весь день зі світлом, синій — що яскравіший, то довше без світла")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()
    }
}
