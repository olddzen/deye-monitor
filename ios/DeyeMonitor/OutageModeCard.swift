import SwiftUI

/// «Режим без світла»: shown on the Now tab while the grid is down. Only measured numbers — the load the
/// battery feeds right now and the energy it has left; no guesses about what else might be switched on.
struct OutageModeCard: View {
    let live: Live
    let stats: Stats?
    var schedule: Schedule? = nil
    @AppStorage("minSoc") private var minSoc = BatteryMath.defaultMinSoc

    private var math: BatteryMath { BatteryMath(live: live, stats: stats, minSoc: minSoc) }
    /// What the battery feeds right now (load, or battery power when the inverter reports it higher).
    private var drawW: Double { max(live.load ?? 0, math.isDischarging ? math.powerW : 0) }

    var body: some View {
        let now = Date.now
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Режим без світла")
                Spacer()
                Image(systemName: "bolt.slash.fill").font(.caption).foregroundStyle(Theme.critical)
            }
            if let h = math.hours(atLoad: drawW) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("при поточному навантаженні вистачить до").font(.subheadline).foregroundStyle(.secondary)
                    Text(Fmt.until(now.addingTimeInterval(h * 3600), now: now))
                        .font(.display(h < 24 ? 52 : 34, .bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text("ще ≈ \(Fmt.duration(h * 3600)) · змінюється разом із навантаженням")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    row("house.fill", "Навантаження зараз", "\(Int(drawW)) Вт")
                    if let usable = math.usableKwh {
                        row("battery.75percent", "Доступно в батареї", "\(Fmt.number(usable)) кВт·год",
                            note: "\(Int(math.soc ?? 0))% → \(Int(minSoc))%")
                    }
                    if let end = schedule?.plannedEnd(since: live.sinceDate), end > now, let usable = math.usableKwh {
                        let need = drawW * end.timeIntervalSince(now) / 3600 / 1000
                        row(need <= usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            "До включення о \(Fmt.time(end))", "≈ \(Fmt.number(need, digits: need < 1 ? 2 : 1)) кВт·год",
                            note: need <= usable ? "вистачить" : "не вистачить при такому навантаженні",
                            tint: need <= usable ? Theme.good : Theme.warning)
                    }
                }
            } else {
                Text("Батарея зараз не розряджається — інвертор тримає навантаження іншим способом, або даних ще немає.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .glassCard()
    }

    private func row(_ symbol: String, _ title: String, _ value: String, note: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 28)
            Text(title).font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let note { Text(note).font(.caption).foregroundStyle(tint ?? .secondary) }
            }
        }
    }
}
