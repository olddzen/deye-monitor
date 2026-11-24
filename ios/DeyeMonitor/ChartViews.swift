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

// MARK: - Chart model (computed once per data refresh, not on every redraw)

struct LinePoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let segment: Int
}

struct ChartModel: Equatable {
    let version: Double
    let from: Date
    let to: Date
    let soc: [LinePoint]
    let load: [LinePoint]
    let bands: [(Date, Date)]
    let days: [(row: DayRow, day: Date)]
    let loadMax: Double

    static func == (a: ChartModel, b: ChartModel) -> Bool { a.version == b.version }

    /// 30-minute buckets: average charge, peak load. A gap > 45 min starts a new line segment.
    init(stats: Stats, version: Double) {
        self.version = version
        let pts = stats.series7 ?? []
        from = pts.first?.date ?? .now.addingTimeInterval(-7 * 86400)
        to = pts.last?.date ?? .now

        func bucketed(_ value: (SeriesPoint) -> Double?, _ combine: ([Double]) -> Double) -> [LinePoint] {
            var groups: [(ts: Double, vals: [Double])] = []
            for p in pts {
                guard let v = value(p) else { continue }
                let b = (p.ts / 1800).rounded(.down) * 1800
                if groups.last?.ts == b { groups[groups.count - 1].vals.append(v) } else { groups.append((b, [v])) }
            }
            var out: [LinePoint] = []
            var seg = 0
            var prev: Double?
            for (i, g) in groups.enumerated() {
                if let prev, g.ts - prev > 2700 { seg += 1 }
                out.append(LinePoint(id: i, date: Date(timeIntervalSince1970: g.ts + 900), value: combine(g.vals), segment: seg))
                prev = g.ts
            }
            return out
        }
        soc = bucketed({ $0.soc }) { $0.reduce(0, +) / Double($0.count) }
        load = bucketed({ $0.load }) { $0.max() ?? 0 }
        loadMax = load.map(\.value).max() ?? 0
        let lo = from, hi = to
        bands = (stats.outages ?? []).compactMap { o in
            let s = max(o.startDate, lo), e = min(o.endDate ?? hi, hi)
            return e > s ? (s, e) : nil
        }
        days = (stats.daily30 ?? []).map { ($0, $0.day) }
    }
}

private func nearest(_ pts: [LinePoint], to date: Date?) -> LinePoint? {
    guard let date else { return nil }
    return pts.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
}

// MARK: - 7-day lines (one measure per chart, never a dual axis)

struct ChargeChart: View, Equatable {
    let model: ChartModel
    @State private var selected: Date?

    static func == (a: ChargeChart, b: ChargeChart) -> Bool { a.model == b.model }

    var body: some View {
        Card(title: "Заряд батареї, %") {
            if model.soc.count < 2 {
                Text("BMS ще не передав даних за тиждень").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.bands.indices, id: \.self) { i in
                        RectangleMark(xStart: .value("Початок", model.bands[i].0), xEnd: .value("Кінець", model.bands[i].1))
                            .foregroundStyle(Theme.critical.opacity(0.14))
                    }
                    ForEach(model.soc) { p in
                        LineMark(x: .value("Час", p.date), y: .value("Заряд", p.value), series: .value("Відрізок", p.segment))
                            .foregroundStyle(Theme.series)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    if let hit = nearest(model.soc, to: selected) {
                        RuleMark(x: .value("Час", hit.date)).foregroundStyle(.secondary.opacity(0.4))
                        PointMark(x: .value("Час", hit.date), y: .value("Заряд", hit.value))
                            .foregroundStyle(Theme.series)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                Tooltip(lines: ["\(Fmt.dayMonth(hit.date)), \(Fmt.time(hit.date))", "\(Int(hit.value))%"])
                            }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: model.from...model.to)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartXSelection(value: $selected)
                .frame(height: 150)
                Legend(items: [("заряд", Theme.series), ("без світла", Theme.critical.opacity(0.3))])
            }
        }
    }
}

struct LoadChart: View, Equatable {
    let model: ChartModel
    @State private var selected: Date?

    static func == (a: LoadChart, b: LoadChart) -> Bool { a.model == b.model }

    var body: some View {
        Card(title: "Споживання квартири, Вт (пік за 30 хв)") {
            if model.load.count < 2 {
                Text("Ще замало даних").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.bands.indices, id: \.self) { i in
                        RectangleMark(xStart: .value("Початок", model.bands[i].0), xEnd: .value("Кінець", model.bands[i].1))
                            .foregroundStyle(Theme.critical.opacity(0.14))
                    }
                    ForEach(model.load) { p in
                        LineMark(x: .value("Час", p.date), y: .value("Вт", p.value), series: .value("Відрізок", p.segment))
                            .foregroundStyle(Theme.series)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    if let hit = nearest(model.load, to: selected) {
                        RuleMark(x: .value("Час", hit.date)).foregroundStyle(.secondary.opacity(0.4))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                Tooltip(lines: ["\(Fmt.dayMonth(hit.date)), \(Fmt.time(hit.date))", "до \(Int(hit.value)) Вт"])
                            }
                    }
                }
                .chartXScale(domain: model.from...model.to)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .chartXSelection(value: $selected)
                .frame(height: 130)
            }
        }
    }
}

// MARK: - Heatmap (sequential blue), drawn in one Canvas

struct HeatmapCard: View, Equatable {
    let rows: [[Double]]
    let version: Double
    private let days = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]
    @State private var picked: (Int, Int)?

    static func == (a: HeatmapCard, b: HeatmapCard) -> Bool { a.version == b.version }

    var body: some View {
        Card(title: "Коли зазвичай немає світла · 4 тижні") {
            if rows.count == 7 {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<7, id: \.self) { w in
                            Text(days[w]).font(.caption2).foregroundStyle(.secondary).frame(height: 16)
                        }
                    }
                    GeometryReader { geo in
                        let cw = (geo.size.width - 23 * 2) / 24
                        Canvas { ctx, _ in
                            for w in 0..<7 {
                                for h in 0..<24 {
                                    let r = CGRect(x: CGFloat(h) * (cw + 2), y: CGFloat(w) * 18, width: cw, height: 16)
                                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Theme.seqColor(rows[w][h])))
                                    if let p = picked, p == (w, h) {
                                        ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.primary), lineWidth: 1.5)
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { loc in
                            let h = min(23, max(0, Int(loc.x / (cw + 2)))), w = min(6, max(0, Int(loc.y / 18)))
                            picked = (w, h)
                        }
                    }
                    .frame(height: 7 * 18)
                }
                HStack {
                    Text("").frame(width: 20)
                    ForEach([0, 6, 12, 18, 23], id: \.self) { h in
                        Text("\(h)").font(.caption2).foregroundStyle(.secondary)
                        if h != 23 { Spacer() }
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

struct DailyChart: View, Equatable {
    let model: ChartModel
    @State private var selected: Date?

    static func == (a: DailyChart, b: DailyChart) -> Bool { a.model == b.model }

    var body: some View {
        Card(title: "Години без світла по днях · 30 днів") {
            Chart {
                ForEach(model.days, id: \.row.id) { r, day in
                    if r.hasData == true {
                        BarMark(x: .value("День", day, unit: .day), y: .value("Години", (r.offMin ?? 0) / 60))
                            .foregroundStyle(Theme.series)
                            .cornerRadius(3)
                    } else {
                        BarMark(x: .value("День", day, unit: .day), y: .value("Години", 0.08))
                            .foregroundStyle(Theme.noData)
                    }
                }
                if let selected, let r = model.days.min(by: { abs($0.day.timeIntervalSince(selected)) < abs($1.day.timeIntervalSince(selected)) }) {
                    RuleMark(x: .value("День", r.day, unit: .day)).foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Tooltip(lines: [Fmt.dayMonth(r.day),
                                            r.row.hasData == true ? "без світла \(Fmt.duration((r.row.offMin ?? 0) * 60))" : "немає даних"])
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
