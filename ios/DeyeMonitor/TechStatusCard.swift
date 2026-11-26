import SwiftUI

/// «Технічний стан зараз»: the raw Deye numbers, each with a plain-language verdict so it can be read
/// without knowing what a BMS or a bypass relay is.
struct TechStatusCard: View {
    let live: Live

    /// Deye single-phase LV hybrid, 6 kW: what it can give from the battery, and roughly what its
    /// grid bypass relay passes through (35–40 A depending on the version — the lower bound is used).
    static let inverterW = 6000.0
    static let bypassW = 8000.0

    enum Level { case ok, warn, bad, idle
        var color: Color {
            switch self {
            case .ok: Theme.good
            case .warn: Theme.warning
            case .bad: Theme.critical
            case .idle: .secondary
            }
        }
        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .warn: "exclamationmark.triangle.fill"
            case .bad: "xmark.octagon.fill"
            case .idle: "minus.circle.fill"
            }
        }
    }

    struct Row: Identifiable {
        let title: String
        let value: String
        let note: String
        let level: Level
        var id: String { title }
    }

    /// "40 Вт" below a kilowatt, "2,4 кВт" above.
    static func watts(_ w: Double) -> String {
        let w = max(w, 0)
        return w < 1000 ? "\(Int(w.rounded())) Вт" : "\(Fmt.number(w / 1000, digits: 1)) кВт"
    }

    private var gridOn: Bool { live.gridOn == true }

    var rows: [Row] {
        var r: [Row] = []

        // Grid voltage and frequency.
        if gridOn, let v = live.voltage {
            let level: Level = (207...253).contains(v) ? .ok : (v < 195 || v > 260 ? .bad : .warn)
            let note = level == .ok ? "у нормі (207–253 В)"
                : v < 207 ? "занизька — техніка з двигунами працює гірше" : "зависока — інвертор може відключитись від мережі"
            r.append(Row(title: "Напруга мережі", value: "\(Int(v.rounded())) В", note: note, level: level))
        } else {
            r.append(Row(title: "Напруга мережі", value: "—", note: "світла немає", level: .idle))
        }
        if gridOn, let f = live.freq, f > 0 {
            let ok = (49.5...50.5).contains(f)
            r.append(Row(title: "Частота мережі", value: "\(Fmt.number(f, digits: 2)) Гц",
                         note: ok ? "стабільна" : "нестабільна — мережа «гуляє»", level: ok ? .ok : .warn))
        }

        // Grid relay inside the inverter.
        if let relay = live.relay {
            let closed = relay.lowercased().contains("pull") || relay.lowercased().contains("close")
            r.append(Row(title: "Реле мережі", value: closed ? "замкнене" : "розімкнене",
                         note: closed ? "квартира живиться від мережі напряму" : "інвертор відʼєднався від мережі — квартира на батареї",
                         level: closed ? .ok : (gridOn ? .warn : .idle)))
        }

        // How close to the power limit we are right now.
        if gridOn, let p = live.gridPower {
            let share = max(p, 0) / Self.bypassW
            r.append(Row(title: "Запас потужності", value: "\(Self.watts(p)) з ~8 кВт",
                         note: share > 0.85 ? "майже межа — вимкни щось потужне" : "мережа йде через інвертор, запас є",
                         level: share > 0.85 ? .bad : share > 0.65 ? .warn : .ok))
        } else if let load = live.load {
            let share = load / Self.inverterW
            r.append(Row(title: "Запас потужності", value: "\(Self.watts(load)) з 6 кВт",
                         note: share > 0.85 ? "майже межа — інвертор може вимкнутись" : "від батареї: до 6 кВт одночасно",
                         level: share > 0.85 ? .bad : share > 0.65 ? .warn : .ok))
        }

        // Whether the battery's own BMS lets it charge.
        if let b = live.battery {
            if let limit = b.chargeLimitA {
                let blocked = limit <= 0
                let needsCharge = gridOn && (live.soc ?? 100) < 98
                r.append(Row(title: "Батарея дозволяє заряд", value: blocked ? "ні · 0 А" : "так · до \(Int(limit)) А",
                             note: blocked ? (needsCharge ? "BMS заблокувала заряд, хоча батарея не повна" : "BMS тимчасово не приймає заряд")
                                           : "BMS не обмежує заряд",
                             level: blocked ? (needsCharge ? .warn : .idle) : .ok))
            }
            if let v = b.voltage {
                let a = b.current ?? 0   // Deye: negative = charging
                let what = abs(a) < 0.3 ? "відпочиває" : a < 0 ? "заряджається" : "віддає енергію"
                r.append(Row(title: "Батарея зараз", value: "\(Fmt.number(v, digits: 1)) В · \(Fmt.number(abs(a), digits: 1)) А",
                             note: what + " · норма 48–57 В", level: (46...58).contains(v) ? .ok : .warn))
            }
        }

        // Temperatures.
        if let t = live.batteryTemp {
            let level: Level = (5...45).contains(t) ? .ok : (t < 0 || t > 50 ? .bad : .warn)
            r.append(Row(title: "Температура батареї", value: "\(Int(t.rounded()))°",
                         note: level == .ok ? "норма 5–45°" : t < 5 ? "холодно — заряд буде повільним" : "гаряче — провітрюй",
                         level: level))
        }
        if let t = live.inverterTemp {
            let level: Level = t < 65 ? .ok : t < 80 ? .warn : .bad
            r.append(Row(title: "Температура інвертора", value: "\(Int(t.rounded()))°",
                         note: level == .ok ? "норма до 65°" : "гарячий — перевір вентиляцію", level: level))
        }
        return r
    }

    var body: some View {
        let rows = rows
        let worst: Level = rows.contains { $0.level == .bad } ? .bad : rows.contains { $0.level == .warn } ? .warn : .ok
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Технічний стан зараз")
                Spacer()
                Label(worst == .ok ? "все в нормі" : worst == .warn ? "є на що глянути" : "потрібна увага",
                      systemImage: worst.symbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(worst.color)
            }
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: row.level.symbol).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(row.level.color).frame(width: 20).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.title).font(.subheadline)
                            Spacer()
                            Text(row.value).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        Text(row.note).font(.caption).foregroundStyle(row.level == .ok ? .secondary : row.level.color)
                    }
                }
            }
            if let u = live.updatedDate {
                Text("дані інвертора о \(Fmt.time(u)) · Deye оновлює їх раз на ~5 хв")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .glassCard()
    }
}
