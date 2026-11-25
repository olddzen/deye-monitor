import Charts
import SwiftUI

/// «Що їсть енергію»: typical day profile, standby cost, week-over-week and the projected bill.
struct ConsumptionCard: View {
    let insights: Insights
    let tariff: Double?

    private struct Bar: Identifiable {
        let hour: Int
        let watts: Double
        var id: Int { hour }
    }

    /// The inverter reports ~0 W at night when nothing is on its output: no standby to talk about then.
    private var base: Double? { insights.baseLoadW.flatMap { $0 >= 5 ? $0 : nil } }

    private var bars: [Bar] {
        (insights.hourlyW ?? []).enumerated().compactMap { h, w in w.map { Bar(hour: h, watts: $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Що їсть енергію · 14 днів")
            if !bars.isEmpty {
                Chart(bars) { b in
                    BarMark(x: .value("Година", b.hour), y: .value("Вт", b.watts), width: .fixed(9))
                        .foregroundStyle(b.hour == insights.peakHour ? Theme.warning : Theme.series.opacity(0.75))
                        .cornerRadius(3)
                    if let base {
                        RuleMark(y: .value("Фон", base))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXScale(domain: -0.5...23.5)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0):00").font(.caption2) }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel().font(.caption2)
                    }
                }
                .frame(height: 140)
                Text(profileLine).font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                if let base {
                    row("moon.zzz.fill", "Фонове споживання", "\(Int(base)) Вт цілодобово",
                        insights.standbyMonthUah.map { "≈ \(Int($0)) ₴/міс" })
                }
                if let w = insights.weekKwh {
                    row("calendar", "Цей тиждень", "\(Fmt.number(w)) кВт·год", weekDelta)
                }
                if let cost = insights.monthCostUah, let day = insights.importDayKwh {
                    row("banknote.fill", "Прогноз рахунку", "\(Fmt.number(day)) кВт·год з мережі на день",
                        "≈ \(Int(cost)) ₴/міс")
                }
            }

            if let tip { Text(tip).font(.footnote).foregroundStyle(.secondary) }
        }
        .glassCard()
    }

    private var profileLine: String {
        var parts: [String] = []
        if let h = insights.peakHour { parts.append("найбільше о \(h):00") }
        if let e = insights.eveningShare { parts.append("вечір 18–23 — \(Int(e))% споживання") }
        if base != nil { parts.append("пунктир — фон") }
        return parts.joined(separator: " · ")
    }

    private var weekDelta: String? {
        guard let w = insights.weekKwh, let p = insights.prevWeekKwh, p > 0 else { return nil }
        let pct = Int(((w - p) / p * 100).rounded())
        return pct == 0 ? "як минулого" : "\(pct > 0 ? "+" : "−")\(abs(pct))% до минулого"
    }

    private var tip: String? {
        guard let base else { return nil }
        if base >= 150 {
            let saved = 50.0 * 24 * 30 / 1000  // kWh a month per 50 W of standby
            let uah = tariff.map { " (≈ \(Int(saved * $0)) ₴)" } ?? ""
            return "Фон \(Int(base)) Вт — це багато: щось працює й уночі. Кожні 50 Вт фону — це \(Int(saved)) кВт·год на місяць\(uah) і мінус години роботи від батареї."
        }
        return "Фон \(Int(base)) Вт — у нормі. Без світла саме він визначає, скільки протримається батарея вночі."
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, _ trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing { Text(trailing).font(.subheadline.weight(.semibold)).monospacedDigit() }
        }
    }
}
