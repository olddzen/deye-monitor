import Charts
import SwiftUI

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

// MARK: - Charts (one measure per chart, no dual axis, minimal ink)

private struct ChartCard<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .glassCard()
    }
}

private extension View {
    func minimalAxes(showY: Bool = true) -> some View {
        self
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                if showY {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.primary.opacity(0.12))
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
            }
    }
}

struct ChargeChart: View, Equatable {
    let model: ChartModel
    @State private var selected: Date?
    static func == (a: ChargeChart, b: ChargeChart) -> Bool { a.model == b.model }

    var body: some View {
        ChartCard(title: "Заряд батареї", trailing: "7 днів") {
            if model.soc.count < 2 {
                Text("BMS ще не передав даних за тиждень").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.bands.indices, id: \.self) { i in
                        RectangleMark(xStart: .value("Початок", model.bands[i].0), xEnd: .value("Кінець", model.bands[i].1))
                            .foregroundStyle(Theme.critical.opacity(0.12))
                    }
                    ForEach(model.soc) { p in
                        LineMark(x: .value("Час", p.date), y: .value("Заряд", p.value), series: .value("Відрізок", p.segment))
                            .foregroundStyle(Theme.series)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let hit = nearest(model.soc, to: selected) {
                        RuleMark(x: .value("Час", hit.date)).foregroundStyle(.primary.opacity(0.2))
                        PointMark(x: .value("Час", hit.date), y: .value("Заряд", hit.value))
                            .foregroundStyle(Theme.series).symbolSize(60)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                Tooltip(lines: ["\(Fmt.dayMonth(hit.date)), \(Fmt.time(hit.date))", "\(Int(hit.value))%"])
                            }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: model.from...model.to)
                .minimalAxes()
                .chartXSelection(value: $selected)
                .frame(height: 160)
                Legend(items: [("заряд, %", Theme.series), ("без світла", Theme.critical.opacity(0.35))])
            }
        }
    }
}

struct LoadChart: View, Equatable {
    let model: ChartModel
    @State private var selected: Date?
    static func == (a: LoadChart, b: LoadChart) -> Bool { a.model == b.model }

    var body: some View {
        ChartCard(title: "Споживання", trailing: "пік за 30 хв, Вт") {
            if model.load.count < 2 {
                Text("Ще замало даних").font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.bands.indices, id: \.self) { i in
                        RectangleMark(xStart: .value("Початок", model.bands[i].0), xEnd: .value("Кінець", model.bands[i].1))
                            .foregroundStyle(Theme.critical.opacity(0.12))
                    }
                    ForEach(model.load) { p in
                        LineMark(x: .value("Час", p.date), y: .value("Вт", p.value), series: .value("Відрізок", p.segment))
                            .foregroundStyle(Theme.series)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                    if let hit = nearest(model.load, to: selected) {
                        RuleMark(x: .value("Час", hit.date)).foregroundStyle(.primary.opacity(0.2))
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                Tooltip(lines: ["\(Fmt.dayMonth(hit.date)), \(Fmt.time(hit.date))", "до \(Int(hit.value)) Вт"])
                            }
                    }
                }
                .chartXScale(domain: model.from...model.to)
                .minimalAxes()
                .chartXSelection(value: $selected)
                .frame(height: 130)
            }
        }
    }
}

struct HeatmapCard: View, Equatable {
    let rows: [[Double]]
    let version: Double
    private let days = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]
    @State private var picked: (Int, Int)?
    static func == (a: HeatmapCard, b: HeatmapCard) -> Bool { a.version == b.version }

    var body: some View {
        ChartCard(title: "Коли зазвичай немає світла", trailing: "4 тижні") {
            if rows.count == 7 {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<7, id: \.self) { w in
                            Text(days[w]).font(.caption2).foregroundStyle(.secondary).frame(height: 14)
                        }
                    }
                    GeometryReader { geo in
                        let cw = (geo.size.width - 23 * 3) / 24
                        Canvas { ctx, _ in
                            for w in 0..<7 {
                                for h in 0..<24 {
                                    let r = CGRect(x: CGFloat(h) * (cw + 3), y: CGFloat(w) * 17, width: cw, height: 14)
                                    let v = rows[w][h]
                                    let fill: Color = v > 0 ? Theme.seqColor(v) : Color.primary.opacity(0.06)
                                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(fill))
                                    if let p = picked, p == (w, h) {
                                        ctx.stroke(Path(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 5),
                                                   with: .color(.primary), lineWidth: 1.5)
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { loc in
                            picked = (min(6, max(0, Int(loc.y / 17))), min(23, max(0, Int(loc.x / (cw + 3)))))
                        }
                    }
                    .frame(height: 7 * 17)
                }
                Group {
                    if let (w, h) = picked {
                        Text("\(days[w]) \(String(format: "%02d", h)):00–\(String(format: "%02d", h + 1)):00 · без світла \(Int(rows[w][h] * 100))% днів")
                    } else {
                        Text("Торкнись клітинки · темніше — частіше без світла")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct DailyChart: View, Equatable {
    let model: ChartModel
    @State private var selected: Date?
    static func == (a: DailyChart, b: DailyChart) -> Bool { a.model == b.model }

    var body: some View {
        ChartCard(title: "Години без світла", trailing: "30 днів") {
            Chart {
                ForEach(model.days, id: \.row.id) { r, day in
                    BarMark(x: .value("День", day, unit: .day),
                            y: .value("Години", r.hasData == true ? max((r.offMin ?? 0) / 60, 0.05) : 0.05))
                        .foregroundStyle(r.hasData == true && (r.offMin ?? 0) > 0 ? Theme.series : Color.primary.opacity(0.1))
                        .cornerRadius(3)
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
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day().month(.defaultDigits)).foregroundStyle(Color.secondary) } }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel().foregroundStyle(Color.secondary) } }
            .frame(height: 120)
        }
    }
}

// MARK: - Outages

struct OutageList: View {
    let outages: [Outage]

    var body: some View {
        let items = Array(outages.suffix(10).reversed())
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Відключення")
            if items.isEmpty {
                Text("За 60 днів відключень не було").foregroundStyle(.secondary)
            }
            ForEach(items) { o in
                HStack(spacing: 12) {
                    Capsule().fill(o.end == nil ? Theme.critical : Theme.critical.opacity(0.5)).frame(width: 4, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Fmt.dayMonth(o.startDate)).font(.subheadline.weight(.semibold))
                        Text("\(Fmt.time(o.startDate)) – \(o.endDate.map(Fmt.time) ?? "зараз")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text((o.uncertain ? "≥ " : "") + Fmt.duration(o.duration()))
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                }
            }
            if items.contains(where: \.uncertain) {
                Text("≥ — поруч була дірка в даних Deye, реальне відключення могло бути довшим")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .glassCard()
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
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Legend: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    Capsule().fill(items[i].1).frame(width: 12, height: 6)
                    Text(items[i].0)
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
