import SwiftUI

/// «Точність графіка»: how well DTEK keeps the published YASNO schedule — measured, not predicted.
struct ScheduleAccuracyCard: View {
    let acc: ScheduleAccuracy

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Точність графіка")
                Spacer()
                if let since = acc.since {
                    Text("з \(Fmt.dayMonth(Date(timeIntervalSince1970: since)))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if (acc.planned ?? 0) == 0 && (acc.unplanned ?? 0) == 0 {
                Text("Збираю дані: графік архівується щодня, порівняння з фактом з'явиться після першого завершеного відключення.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let p = acc.planned, p > 0 {
                    let h = acc.happened ?? 0
                    row("calendar.badge.checkmark", "Відключення за графіком",
                        "\(h) з \(p)", note: h < p ? "\(p - h) не відбулось" : "усі відбулись")
                }
                if let d = acc.startDeltaMin {
                    row("bolt.slash", "Вимикають", shift(d), note: "у середньому")
                }
                if let d = acc.endDeltaMin {
                    row("bolt", "Вмикають", shift(d),
                        note: acc.endLateMaxMin.map { $0 > 5 ? "найбільше запізнення \(Fmt.duration($0 * 60))" : "у середньому" } ?? "у середньому",
                        tint: d > 15 ? Theme.warning : nil)
                }
                let u = acc.unplanned ?? 0
                row(u > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill", "Поза графіком",
                    u > 0 ? "\(u) відкл." : "не було",
                    note: u > 0 ? "\(Fmt.number(acc.unplannedH)) год без світла" : nil,
                    tint: u > 0 ? Theme.critical : Theme.good)
            }
        }
        .glassCard()
    }

    private func shift(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if abs(m) < 3 { return "вчасно" }
        return "на \(Fmt.duration(Double(abs(m)) * 60)) \(m > 0 ? "пізніше" : "раніше")"
    }

    private func row(_ symbol: String, _ title: String, _ value: String, note: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? .secondary).frame(width: 28)
            Text(title).font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
