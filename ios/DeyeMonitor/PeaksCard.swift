import Charts
import SwiftUI

/// «Піки потужності»: the biggest draw of each day over 30 days against the inverter's limits,
/// so a moment like "boiler + charging + a power tool" is visible afterwards.
struct PeaksCard: View {
    let peaks: Peaks
    var sampleS: Double? = nil

    private var inverterKw: Double { (peaks.inverterW ?? 6000) / 1000 }
    private var bypassKw: Double { (peaks.bypassW ?? 8000) / 1000 }

    var body: some View {
        let days = (peaks.days ?? []).filter { $0.date != nil }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Піки потужності · 30 днів")
                Spacer()
            }
            if let maxW = peaks.maxW, let ts = peaks.maxTs {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.number(maxW / 1000, digits: 1)).font(.display(40, .bold)).monospacedDigit()
                        Text("кВт найбільше").font(.subheadline).foregroundStyle(.secondary)
                    }
                    let when = Date(timeIntervalSince1970: ts)
                    Text("\(Fmt.dayMonth(when)) о \(Fmt.time(when)) · " +
                         (peaks.maxOnGrid == true ? "з мережі (межа ~\(Fmt.number(bypassKw, digits: 0)) кВт)"
                                                  : "від батареї (межа \(Fmt.number(inverterKw, digits: 0)) кВт)"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !days.isEmpty {
                Chart {
                    ForEach(days) { d in
                        BarMark(x: .value("День", d.date!, unit: .day), y: .value("кВт", d.maxW / 1000), width: .fixed(6))
                            .foregroundStyle(d.nearLimit ? Theme.warning : Theme.series.opacity(0.75))
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("межа", inverterKw))
                        .foregroundStyle(Theme.critical.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(Fmt.number(inverterKw, digits: 0)) кВт — межа від батареї")
                                .font(.caption2).foregroundStyle(Theme.critical)
                        }
                }
                .chartYScale(domain: 0...max(bypassKw, (peaks.maxW ?? 0) / 1000 + 0.5))
                .chartYAxis { AxisMarks(values: [0, 2, 4, 6, 8]) { _ in AxisGridLine(); AxisValueLabel() } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .frame(height: 150)
            }
            let near = peaks.nearLimit ?? 0
            Label(near == 0 ? "Жодного разу не підходили до межі" : "Близько до межі: \(near) раз(и) — жовті дні",
                  systemImage: near == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(near == 0 ? Theme.good : Theme.warning)
            Text("Зі світлом інвертор пропускає з мережі ~\(Fmt.number(bypassKw, digits: 0)) кВт, без світла віддає до \(Fmt.number(inverterKw, digits: 0)) кВт. Deye записує дані \(Fmt.every(sampleS)), тож короткі кидки (пуск інструмента) сюди можуть не потрапити.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()
    }
}
