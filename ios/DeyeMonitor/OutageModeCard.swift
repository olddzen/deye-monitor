import SwiftUI

/// «Режим без світла»: shown on the Now tab while the grid is down. Answers three questions:
/// until when does the battery last, how much longer if I cut back, and what to switch off.
struct OutageModeCard: View {
    let live: Live
    let stats: Stats?
    @AppStorage("minSoc") private var minSoc = BatteryMath.defaultMinSoc

    private var math: BatteryMath { BatteryMath(live: live, stats: stats, minSoc: minSoc) }
    /// What the battery feeds right now (load, or battery power when the inverter reports it higher).
    private var drawW: Double { max(live.load ?? 0, math.isDischarging ? math.powerW : 0) }
    /// Fridge, router, standby — the floor the flat can get down to.
    private var economyW: Double? {
        let base = stats?.insights?.baseLoadW ?? stats?.energy30?.baseLoadW
        guard let base, base > 20, base < drawW * 0.9 else { return nil }
        return base
    }

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
                    Text("вистачить до").font(.subheadline).foregroundStyle(.secondary)
                    Text(Fmt.time(now.addingTimeInterval(h * 3600)))
                        .font(.display(52, .bold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("ще ≈ \(Fmt.duration(h * 3600)) при \(Int(drawW)) Вт · до \(Int(minSoc))%")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    if let eco = economyW, let he = math.hours(atLoad: eco) {
                        scenario("leaf.fill", "Економно", "\(Int(eco)) Вт — тільки холодильник і роутер",
                                 he, gain: he - h, now: now)
                    }
                    ForEach(heavyHints, id: \.name) { a in
                        if let ha = math.hours(atLoad: drawW + a.watts) {
                            scenario(a.symbol, "+ \(a.name.lowercased())", "\(Int(a.watts)) Вт", ha, gain: ha - h, now: now)
                        }
                    }
                }
                if let tip { Text(tip).font(.footnote).foregroundStyle(.secondary) }
            } else {
                Text("Батарея зараз не розряджається — інвертор тримає навантаження іншим способом, або даних ще немає.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .glassCard()
    }

    /// Two common heavy appliances, to show what switching one on costs.
    private var heavyHints: [Appliance] {
        Appliance.presets.filter { ["kettle", "heater"].contains($0.id) }
    }

    private var tip: String? {
        guard let eco = economyW, drawW > eco * 2 else { return nil }
        return "Зараз квартира бере в \(Fmt.number(drawW / eco)) раза більше за фон. Бойлер, обігрівач і духовка — головні «їдці» батареї."
    }

    private func scenario(_ symbol: String, _ title: String, _ detail: String, _ hours: Double,
                          gain: Double, now: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(gain >= 0 ? Theme.good : Theme.warning)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("до \(Fmt.time(now.addingTimeInterval(hours * 3600)))").font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("\(gain >= 0 ? "+" : "−")\(Fmt.short(abs(gain) * 3600))").font(.caption).monospacedDigit()
                    .foregroundStyle(gain >= 0 ? Theme.good : Theme.warning)
            }
        }
    }
}
