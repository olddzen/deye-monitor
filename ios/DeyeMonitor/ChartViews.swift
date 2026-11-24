import Charts
import SwiftUI

// MARK: - Today

struct TodayStrip: View {
    let outages: [Outage]

    var body: some View {
        let cal = Fmt.kyivCalendar
        let now = Date.now
        let dayStart = cal.startOfDay(for: now)
        let segs = outages.compactMap { o -> (Date, Date, Outage)? in
            let s = max(o.startDate, dayStart), e = min(o.endDate ?? now, now)
            return e > s ? (s, e, o) : nil
        }
        let total = segs.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        Card(title: "Сьогодні") {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) in CGFloat(d.timeIntervalSince(dayStart) / 86400) * w }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.track.opacity(0.6))
                    RoundedRectangle(cornerRadius: 6).fill(Theme.good.opacity(0.18)).frame(width: x(now))
                    ForEach(segs, id: \.2.id) { s, e, _ in
                        RoundedRectangle(cornerRadius: 4).fill(Theme.critical)
                            .frame(width: max(2, x(e) - x(s))).offset(x: x(s))
                    }
                    Rectangle().fill(.primary).frame(width: 2, height: 36).offset(x: x(now) - 1)
                }
            }
            .frame(height: 28)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                    Text(String(format: "%02d", h)).font(.caption2).foregroundStyle(.secondary)
                    if h != 24 { Spacer() }
                }
            }
            Text(total > 0 ? "сьогодні без світла \(Fmt.duration(total))" : "сьогодні відключень не було")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 7-day lines (one measure per chart, never a dual axis)

private struct OutageBands: ChartContent {
    let outages: [Outage]
    let from: Date
    let to: Date

    var body: some ChartContent {
        ForEach(outages) { o in
            let s = max(o.startDate, from), e = min(o.endDate ?? to, to)
            if e > s {
                RectangleMark(xStart: .value("Початок", s), xEnd: .value("Кінець", e))
                    .foregroundStyle(Theme.critical.opacity(0.14))
            }
        }
    }
}

/// Splits a series at data holes so the line doesn't bridge missing periods.
private func segments(_ pts: [SeriesPoint], _ value: (SeriesPoint) -> Double?) -> [(Int, SeriesPoint, Double)] {
    var seg = 0
    var prev: Double?
    var out: [(Int, SeriesPoint, Double)] = []
    for p in pts {
        guard let v = value(p) else { continue }
        if let prev, p.ts - prev > 1800 { seg += 1 }
        out.append((seg, p, v))
        prev = p.ts
    }
    return out
}

struct ChargeChart: View {
    let stats: Stats
    @State private var selected: Date?

    var body: some View {
        let pts = stats.series7 ?? []
        let rows = segments(pts) { $0.soc }
        Card(title: "Заряд батареї, %") {
            if rows.count < 2 {
                Text("BMS ще не передав даних за тиждень").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    OutageBands(outages: stats.outages ?? [], from: pts.first!.date, to: pts.last!.date)
                    ForEach(rows, id: \.1.id) { seg, p, v in
                        LineMark(x: .value("Час", p.date), y: .value("Заряд", v), series: .value("Відрізок", seg))
                            .foregroundStyle(Theme.series)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    if let selected, let hit = rows.min(by: { abs($0.1.date.timeIntervalSince(selected)) < abs($1.1.date.timeIntervalSince(selected)) }) {
                        RuleMark(x: .value("Час", hit.1.date)).foregroundStyle(.secondary.opacity(0.4))
                        PointMark(x: .value("Час", hit.1.date), y: .value("Заряд", hit.2))
                            .foregroundStyle(Theme.series)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                Tooltip(lines: ["\(Fmt.dayMonth(hit.1.date)), \(Fmt.time(hit.1.date))", "\(Int(hit.2))%"])
                            }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: pts.first!.date...pts.last!.date)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartXSelection(value: $selected)
                .frame(height: 150)
                Legend(items: [("заряд", Theme.series), ("без світла", Theme.critical.opacity(0.3))])
            }
        }
    }
}

struct LoadChart: View {
    let stats: Stats
    @State private var selected: Date?

    var body: some View {
        let pts = stats.series7 ?? []
        let rows = segments(pts) { $0.load }
        Card(title: "Споживання квартири, Вт") {
            if rows.count < 2 {
                Text("Ще замало даних").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    OutageBands(outages: stats.outages ?? [], from: pts.first!.date, to: pts.last!.date)
                    ForEach(rows, id: \.1.id) { seg, p, v in
                        LineMark(x: .value("Час", p.date), y: .value("Вт", v), series: .value("Відрізок", seg))
                            .foregroundStyle(Theme.series)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    if let selected, let hit = rows.min(by: { abs($0.1.date.timeIntervalSince(selected)) < abs($1.1.date.timeIntervalSince(selected)) }) {
                        RuleMark(x: .value("Час", hit.1.date)).foregroundStyle(.secondary.opacity(0.4))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                Tooltip(lines: ["\(Fmt.dayMonth(hit.1.date)), \(Fmt.time(hit.1.date))", "\(Int(hit.2)) Вт"])
                            }
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartXScale(domain: pts.first!.date...pts.last!.date)
                .chartXSelection(value: $selected)
                .frame(height: 130)
            }
        }
    }
}

// MARK: - Heatmap (sequential blue)

struct HeatmapCard: View {
    let rows: [[Double]]
    private let days = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]
    @State private var picked: (Int, Int)?

    var body: some View {
        Card(title: "Коли зазвичай немає світла · 4 тижні") {
            if rows.count == 7 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<7, id: \.self) { w in
                        HStack(spacing: 2) {
                            Text(days[w]).font(.caption2).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                            ForEach(0..<24, id: \.self) { h in
                                let v = rows[w][h]
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.seqColor(v))
                                    .frame(height: 16)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.primary, lineWidth: picked.map { $0 == (w, h) } ?? false ? 1.5 : 0))
                                    .onTapGesture { picked = (w, h) }
                            }
                        }
                    }
                    HStack {
                        Text("").frame(width: 20)
                        ForEach([0, 6, 12, 18, 23], id: \.self) { h in
                            Text("\(h)").font(.caption2).foregroundStyle(.secondary)
                            if h != 23 { Spacer() }
                        }
                    }
                }
                if let (w, h) = picked {
                    Text("\(days[w]), \(String(format: "%02d", h)):00–\(String(format: "%02d", h + 1)):00 — без світла \(Int(rows[w][h] * 100))% часу")
                        .font(.footnote).monospacedDigit()
                } else {
                    HStack(spacing: 6) {
                        Text("0%").font(.caption2).foregroundStyle(.secondary)
                        ForEach(0..<Theme.seq.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(Theme.seq[i]).frame(width: 14, height: 10)
                        }
                        Text("100% днів · торкнись клітинки").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Daily bars

struct DailyChart: View {
    let rows: [DayRow]
    @State private var selected: Date?

    var body: some View {
        Card(title: "Години без світла по днях · 30 днів") {
            Chart {
                ForEach(rows) { r in
                    if r.hasData == true {
                        BarMark(x: .value("День", r.day, unit: .day), y: .value("Години", (r.offMin ?? 0) / 60))
                            .foregroundStyle(Theme.series)
                            .cornerRadius(3)
                    } else {
                        BarMark(x: .value("День", r.day, unit: .day), y: .value("Години", 0.08))
                            .foregroundStyle(Theme.noData)
                    }
                }
                if let selected, let r = rows.min(by: { abs($0.day.timeIntervalSince(selected)) < abs($1.day.timeIntervalSince(selected)) }) {
                    RuleMark(x: .value("День", r.day, unit: .day)).foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Tooltip(lines: [Fmt.dayMonth(r.day),
                                            r.hasData == true ? "без світла \(Fmt.duration((r.offMin ?? 0) * 60))" : "немає даних"])
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day().month(.defaultDigits)) } }
            .frame(height: 120)
            Legend(items: [("без світла", Theme.series), ("немає даних", Theme.noData)])
        }
    }
}

// MARK: - Outages and details

struct OutageList: View {
    let outages: [Outage]

    var body: some View {
        let items = Array(outages.suffix(8).reversed())
        Card(title: "Останні відключення") {
            if items.isEmpty {
                Text("За 60 днів відключень не було 🎉").foregroundStyle(.secondary)
            }
            ForEach(items) { o in
                HStack {
                    Text(Fmt.dayMonth(o.startDate)).fontWeight(.semibold)
                    Text("\(Fmt.time(o.startDate))–\(o.endDate.map(Fmt.time) ?? "зараз")").foregroundStyle(.secondary)
                    Spacer()
                    if o.uncertain {
                        Text("≥").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.warning.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text(Fmt.duration(o.duration()))
                }
                .font(.subheadline).monospacedDigit()
                if o.id != items.last?.id { Divider() }
            }
            if items.contains(where: \.uncertain) {
                Text("≥ — поруч була дірка в даних Deye, реальне відключення могло бути довшим")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DetailsCard: View {
    let stats: Stats
    private let hints = ["F13": "зміна режиму", "F25": "батарея", "F47": "частота мережі",
                         "F56": "низька напруга батареї", "F58": "зв'язок з BMS", "F64": "перегрів"]

    var body: some View {
        let b = stats.battery, g = stats.grid30, e = stats.energy30
        Card(title: "Батарея і мережа · 30 днів") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                Tile(title: "Віддала батарея", value: "\(Fmt.number(b?.discharged30d)) кВт·год",
                     detail: "циклів за весь час \(Fmt.number(b?.cyclesTotal)) з ~6000")
                Tile(title: "Температура, макс.",
                     value: "\(b?.tempMax.map { "\(Int($0))°" } ?? "—") / \(b?.inverterTempMax.map { "\(Int($0))°" } ?? "—")",
                     detail: "батарея / інвертор")
                Tile(title: "Напруга мережі", value: "\(g?.vMin.map { "\(Int($0))" } ?? "—")–\(g?.vMax.map { "\(Int($0))" } ?? "—") В",
                     detail: "середня \(g?.vAvg.map { "\(Int($0))" } ?? "—") В")
                Tile(title: "Спожито квартирою", value: "\(Fmt.number(e?.loadKwh)) кВт·год",
                     detail: "тариф \(Fmt.number(e?.tariff, digits: 2)) ₴")
            }
            if let cov = b?.coverage, cov < 80 {
                Label("BMS передавав дані лише \(Int(cov))% часу", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).padding(8)
                    .background(Theme.warning.opacity(0.18), in: Capsule())
            }
            Text("АВАРІЇ DEYE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            let alerts = (stats.alerts30 ?? [:]).sorted { $0.value > $1.value }
            if alerts.isEmpty {
                Text("✅ аварій не було").font(.subheadline)
            } else {
                FlowRow(items: alerts.map { "⚠️ \($0.key) × \($0.value)" + (hints[$0.key].map { " · \($0)" } ?? "") })
            }
        }
    }
}

// MARK: - Small building blocks

struct Tooltip: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i]).font(i == lines.count - 1 ? .caption.weight(.bold) : .caption2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(Theme.page)
        .background(.primary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Legend: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(items[i].1).frame(width: 12, height: 10)
                    Text(items[i].0)
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

struct FlowRow: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { t in
                Text(t).font(.footnote).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.tile, in: Capsule()).overlay(Capsule().stroke(Theme.line))
            }
        }
    }
}
