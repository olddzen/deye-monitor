import SwiftUI

/// Tab 3 — health of the battery, the grid and the money.
struct SystemView: View {
    @ObservedObject var store: Store
    private let hints = ["F13": "зміна режиму", "F25": "батарея", "F47": "частота мережі",
                         "F56": "низька напруга батареї", "F58": "зв'язок з BMS", "F64": "перегрів"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Система").font(.display(34, .bold)).padding(.top, 8)
                if let s = store.response?.data {
                    battery(s.battery)
                    HStack(spacing: 12) {
                        tile("Мережа", value: "\(s.grid30?.vMin.map { "\(Int($0))" } ?? "—")–\(s.grid30?.vMax.map { "\(Int($0))" } ?? "—")",
                             unit: "В", note: "середня \(s.grid30?.vAvg.map { "\(Int($0))" } ?? "—") В")
                        tile("Інвертор", value: s.battery?.inverterTempMax.map { "\(Int($0))" } ?? "—", unit: "°C", note: "макс. за 30 днів")
                    }
                    energy(s.energy30)
                    alerts(s.alerts30 ?? [:])
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                }
                about
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
    }

    private func battery(_ b: BatteryStats?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Здоров'я батареї")
            if let h = b?.health {
                Metric(value: "\(Int(h))", unit: "%", size: 44)
                CapsuleMeter(fraction: h / 100, tint: Theme.good)
                Text("ємність ≈ \(Fmt.number(b?.capacityKwh)) з \(Fmt.number(b?.nominalKwh)) кВт·год").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("ще оцінюється").font(.display(26)).foregroundStyle(.secondary)
                Text("Потрібен розряд глибше 15% під час відключення").font(.caption).foregroundStyle(.secondary)
            }
            Divider().opacity(0.4)
            HStack {
                stat("циклів", Fmt.number(b?.cyclesTotal, digits: 2), "з ~6000")
                Spacer()
                stat("віддала", Fmt.number(b?.discharged30d), "кВт·год / 30 д")
                Spacer()
                stat("макс.", b?.tempMax.map { "\(Int($0))°" } ?? "—", "батарея")
            }
            if let cov = b?.coverage, cov < 80 {
                Label("BMS передавав дані лише \(Int(cov))% часу", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .glassCard()
    }

    private func energy(_ e: EnergyStats?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Енергія · 30 днів")
            HStack(alignment: .firstTextBaseline) {
                Metric(value: "\(Int(e?.costUah ?? 0))", unit: "₴", size: 40)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Fmt.number(e?.importKwh)) кВт·год з мережі").font(.subheadline)
                    Text("спожито \(Fmt.number(e?.loadKwh)) · тариф \(Fmt.number(e?.tariff, digits: 2)) ₴").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .glassCard()
    }

    private func alerts(_ a: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Аварії Deye · 30 днів")
            if a.isEmpty {
                Label("Аварій не було", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good)
            } else {
                ForEach(a.sorted { $0.value > $1.value }, id: \.key) { code, n in
                    HStack {
                        Text(code).font(.subheadline.weight(.semibold).monospaced())
                        Text(hints[code] ?? "").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Text("× \(n)").font(.subheadline.weight(.medium)).monospacedDigit()
                    }
                }
            }
        }
        .glassCard()
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let u = store.response?.live?.updatedDate { Text("живі дані Deye на \(Fmt.time(u))") }
            if let g = store.response?.generatedAt { Text("статистика на \(Fmt.time(Date(timeIntervalSince1970: g)))") }
            if let e = store.error { Text(e).foregroundStyle(Theme.critical) }
        }
        .font(.caption).foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func tile(_ title: String, value: String, unit: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            Metric(value: value, unit: unit, size: 24)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .glassCard(radius: 24, padding: 16)
    }

    private func stat(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(20)).monospacedDigit()
            Text("\(title) · \(note)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
