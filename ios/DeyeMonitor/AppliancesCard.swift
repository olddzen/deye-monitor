import SwiftUI

/// «Техніка»: SmartThings appliances — what's on right now, a running cycle, and how much each one
/// used today and over 30 days (history collected every 5 minutes since the connection).
struct AppliancesCard: View {
    let live: ApplianceSnapshot?
    let stats: [ApplianceStat]
    let tariff: Double?

    private struct Row: Identifiable {
        let id: String
        let label: String
        let kind: String
        let live: ApplianceLive?
        let stat: ApplianceStat?
    }

    private var rows: [Row] {
        let liveById = Dictionary((live?.devices ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let statById = Dictionary(stats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = stats.map(\.id) + (live?.devices ?? []).map(\.id).filter { statById[$0] == nil }
        return ids.map { id in
            let l = liveById[id], s = statById[id]
            return Row(id: id, label: l?.label ?? s?.label ?? "Прилад", kind: l?.kind ?? s?.kind ?? "other", live: l, stat: s)
        }
    }

    var body: some View {
        let rows = rows
        let maxMonth = max(rows.compactMap { $0.stat?.monthKwh }.max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Техніка · SmartThings")
                Spacer()
                if let since = stats.compactMap(\.since).min() {
                    Text("дані з \(Fmt.dayMonth(Date(timeIntervalSince1970: since)))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(rows) { r in
                row(r, maxMonth: maxMonth)
            }
            if let total = totalMonth, total > 0 {
                Divider().opacity(0.4)
                HStack {
                    Text("Разом за 30 днів").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Fmt.number(total)) кВт·год" + (tariff.map { " · ≈ \(Int(total * $0)) ₴" } ?? ""))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
        }
        .glassCard()
    }

    private var totalMonth: Double? {
        let v = stats.compactMap(\.monthKwh)
        return v.isEmpty ? nil : v.reduce(0, +)
    }

    private func row(_ r: Row, maxMonth: Double) -> some View {
        let on = r.live?.on == true
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(r.kind, label: r.label))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Theme.series : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? Theme.series.opacity(0.14) : Color.primary.opacity(0.05)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(status(r)).font(.caption).foregroundStyle(on ? Theme.series : .secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(r.stat?.todayKwh.map { "\(Fmt.number($0, digits: 2)) кВт·год" } ?? "—")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(r.stat?.monthKwh.map { "30 д: \(Fmt.number($0)) кВт·год" } ?? "сьогодні")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let m = r.stat?.monthKwh, m > 0 {
                CapsuleMeter(fraction: m / maxMonth, tint: Theme.series.opacity(0.7), height: 4)
                    .padding(.leading, 46)
            }
        }
    }

    private func status(_ r: Row) -> String {
        guard let l = r.live else { return "немає зв'язку" }
        if let state = l.state, state == "run" || state == "running" {
            let left = l.remainingMin.map { " · ще \(Fmt.duration($0 * 60))" } ?? ""
            return (r.kind == "dryer" ? "сушить" : "пере") + left
        }
        if l.on == true {
            if let p = l.power, p > 0 { return "увімкнено · \(Int(p)) Вт" }
            return "увімкнено"
        }
        return "вимкнено"
    }

    static func symbol(_ kind: String, label: String = "") -> String {
        let l = label.lowercased()
        if l.contains("нагрів") || l.contains("бойлер") { return "drop.degreesign.fill" }
        switch kind {
        case "ac": return "air.conditioner.horizontal.fill"
        case "washer": return "washer.fill"
        case "dryer": return "dryer.fill"
        case "dishwasher": return "dishwasher.fill"
        case "fridge": return "refrigerator.fill"
        case "tv": return "tv.fill"
        case "plug": return "powerplug.fill"
        default: return "bolt.fill"
        }
    }
}
