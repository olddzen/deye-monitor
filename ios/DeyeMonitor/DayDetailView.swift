import Charts
import SwiftUI

/// Any day in detail: power, battery and outages in 5-minute steps, plus the day's totals.
struct DayDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date
    @State private var detail: DayDetail?
    @State private var status: Status = .loading

    private enum Status { case loading, ready, missing, failed(String) }

    private let cal = Fmt.kyivCalendar
    private var today: Date { cal.startOfDay(for: .now) }
    private var earliest: Date { cal.date(byAdding: .day, value: -400, to: today) ?? today }

    init(day: Date = .now) {
        _day = State(initialValue: Fmt.kyivCalendar.startOfDay(for: day))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dayBar
                    switch status {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                    case .missing:
                        empty("Немає даних за цей день", "Архів наповнюється автоматично; дні до початку моніторингу недоступні.")
                    case .failed(let msg):
                        empty("Не вдалося завантажити", msg)
                    case .ready:
                        if let d = detail { DayContent(detail: d) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("День")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task(id: day) { await load() }
        }
    }

    private var dayBar: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(day <= earliest)
            Spacer()
            DatePicker("", selection: $day, in: earliest...today, displayedComponents: .date)
                .labelsHidden()
                .environment(\.timeZone, Fmt.kyiv)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(day >= today)
        }
        .font(.headline)
        .padding(.top, 4)
    }

    private func shift(_ n: Int) {
        if let d = cal.date(byAdding: .day, value: n, to: day) { day = min(max(d, earliest), today) }
    }

    private func empty(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func load() async {
        status = .loading
        let key = Fmt.isoDay.string(from: cal.startOfDay(for: day))
        do {
            if let d = try await APIClient.shared.fetchDay(key) {
                detail = d
                status = .ready
            } else {
                status = .missing
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

private struct DayContent: View {
    let detail: DayDetail

    private var start: Date { Date(timeIntervalSince1970: detail.start) }
    private var end: Date { start.addingTimeInterval(86400) }
    private var outs: [(Date, Date)] {
        detail.outages.compactMap { o in
            o.count == 2 ? (Date(timeIntervalSince1970: o[0]), Date(timeIntervalSince1970: o[1])) : nil
        }
    }

    var body: some View {
        let t = detail.totals
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                tile("Спожито", Fmt.number(t.loadKwh), "кВт·год", nil)
                tile("З мережі", Fmt.number(t.importKwh), "кВт·год", t.costUah.map { "≈ \(Int($0)) ₴" })
                tile("Без світла", (t.offMin ?? 0) > 0 ? Fmt.short((t.offMin ?? 0) * 60) : "0", "",
                     (t.outages ?? 0) > 0 ? "\(t.outages ?? 0) відкл." : "світло було весь день")
                tile("Батарея", range(t.socMin, t.socMax), "%", nil)
                tile("Пік", t.peakW.map { "\(Int($0))" } ?? "—", "Вт",
                     t.peakTs.map { "о " + Fmt.time(Date(timeIntervalSince1970: $0)) })
                tile("Напруга", range(t.vMin, t.vMax), "В", nil)
            }

            chartCard("Потужність", legend: [("Квартира", Theme.series), ("Мережа", Theme.good)]) {
                Chart {
                    outageMarks
                    ForEach(detail.points) { p in
                        if let w = p.loadW {
                            AreaMark(x: .value("Час", p.date), y: .value("Вт", w), series: .value("s", "load"))
                                .foregroundStyle(Theme.series.opacity(0.18))
                            LineMark(x: .value("Час", p.date), y: .value("Вт", w), series: .value("s", "load"))
                                .foregroundStyle(Theme.series).lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                        if let g = p.gridW {
                            LineMark(x: .value("Час", p.date), y: .value("Вт", max(g, 0)), series: .value("s", "grid"))
                                .foregroundStyle(Theme.good).lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                    }
                }
                .chartXScale(domain: start...end)
                .modifier(DayAxes())
                .frame(height: 170)
            }

            chartCard("Заряд батареї", legend: []) {
                Chart {
                    outageMarks
                    ForEach(detail.points) { p in
                        if let s = p.soc {
                            LineMark(x: .value("Час", p.date), y: .value("%", s))
                                .foregroundStyle(Theme.good).lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartXScale(domain: start...end)
                .chartYScale(domain: 0...100)
                .modifier(DayAxes())
                .frame(height: 130)
            }
        }
    }

    @ChartContentBuilder private var outageMarks: some ChartContent {
        ForEach(Array(outs.enumerated()), id: \.offset) { _, o in
            RectangleMark(xStart: .value("з", o.0), xEnd: .value("до", o.1))
                .foregroundStyle(Theme.critical.opacity(0.12))
        }
    }

    private func range(_ lo: Double?, _ hi: Double?) -> String {
        guard let lo else { return "—" }
        let a = Int(lo), b = Int(hi ?? lo)
        return a == b ? "\(a)" : "\(a)–\(b)"
    }

    private func tile(_ title: String, _ value: String, _ unit: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Metric(value: value, unit: unit, size: 24)
            Text(note ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .glassCard(radius: 18, padding: 12)
    }

    private func chartCard<C: View>(_ title: String, legend: [(String, Color)], @ViewBuilder _ chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                ForEach(legend, id: \.0) { name, color in
                    HStack(spacing: 4) {
                        Capsule().fill(color).frame(width: 10, height: 3)
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !outs.isEmpty {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.critical.opacity(0.25)).frame(width: 10, height: 8)
                        Text("без світла").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            chart()
        }
        .glassCard()
    }
}

private struct DayAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel().font(.caption2)
                }
            }
    }
}
