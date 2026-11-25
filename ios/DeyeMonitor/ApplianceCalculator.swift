import SwiftUI

/// The flat's own appliances (models from the purchase history and SmartThings).
/// `watts` is the average draw while in use — what drains the battery; `peak` is the short maximum
/// that has to fit into the inverter's 6 kW. Values are typical figures for these models (≈).
struct Appliance: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let symbol: String
    let watts: Double
    var peak: Double? = nil
    /// Program-based appliances: typical cycle length (h) and energy (kWh).
    var cycleH: Double? = nil
    var cycleKwh: Double? = nil

    var peakW: Double { peak ?? watts }

    static let presets: [Appliance] = [
        .init(id: "fridge", name: "Холодильник", model: "Bosch KBN96ADD0", symbol: "refrigerator.fill", watts: 30, peak: 120),
        .init(id: "router", name: "Роутер", model: "Wi-Fi", symbol: "wifi.router.fill", watts: 15),
        .init(id: "monitor", name: "Монітор", model: "Dell U2725QE", symbol: "display", watts: 25, peak: 60),
        .init(id: "laptop", name: "Ноутбук", model: "зарядка", symbol: "laptopcomputer", watts: 45),
        .init(id: "lights", name: "Світло в кімнатах", model: "LED", symbol: "lightbulb.fill", watts: 40),
        .init(id: "tv", name: "Телевізор", model: "Samsung 55\" OLED S95D", symbol: "tv.fill", watts: 110, peak: 180),
        .init(id: "musicframe", name: "Music Frame ×2", model: "Samsung HW-LS60D", symbol: "hifispeaker.2.fill", watts: 30),
        .init(id: "freestyle", name: "Проєктор", model: "Samsung The Freestyle", symbol: "videoprojector.fill", watts: 45),
        .init(id: "ac12", name: "Кондиціонер 12K", model: "Samsung AR60F12 WindFree", symbol: "air.conditioner.horizontal.fill", watts: 600, peak: 1300),
        .init(id: "ac18", name: "Кондиціонер 18K", model: "Samsung AR60F18 WindFree", symbol: "air.conditioner.horizontal.fill", watts: 900, peak: 1900),
        .init(id: "boiler", name: "Бойлер", model: "Ariston Velis Pro Dry 100", symbol: "drop.degreesign.fill", watts: 1500),
        .init(id: "microwave", name: "Мікрохвильовка", model: "Bosch BFL7221B1", symbol: "microwave.fill", watts: 1200),
        .init(id: "hob", name: "Індукція, 1 конфорка", model: "Bosch PIF651HC1E (до 7,4 кВт)", symbol: "cooktop.fill", watts: 1500, peak: 2200),
        .init(id: "oven", name: "Духова шафа", model: "Bosch HBG7341B1", symbol: "oven.fill", watts: 1100, peak: 3600),
        .init(id: "dishwasher", name: "Посудомийка", model: "Bosch SMV8YCX02E", symbol: "dishwasher.fill", watts: 250, peak: 2400,
              cycleH: 3.5, cycleKwh: 0.9),
        .init(id: "washer", name: "Пральна машина", model: "Samsung", symbol: "washer.fill", watts: 350, peak: 2200,
              cycleH: 2, cycleKwh: 0.7),
        .init(id: "dryer", name: "Сушарка", model: "Samsung, тепловий насос", symbol: "dryer.fill", watts: 600, peak: 1000,
              cycleH: 3, cycleKwh: 1.6),
        .init(id: "kettle", name: "Чайник", model: "", symbol: "cup.and.saucer.fill", watts: 2000),
    ]

    static func byId(_ id: String) -> Appliance? { presets.first { $0.id == id } }
}

/// «Що можна ввімкнути?» — how long the battery lasts with the chosen appliances on.
struct ApplianceCalculator: View {
    let live: Live?
    let stats: Stats?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = ["fridge", "router"]
    @State private var includeCurrent = true

    private let inverterLimit = 6000.0
    private var capacityKwh: Double { stats?.battery?.capacityKwh ?? stats?.battery?.nominalKwh ?? 11.8 }
    private var soc: Double { live?.soc ?? 100 }
    private var usableWh: Double { max(0, soc - 10) / 100 * capacityKwh * 1000 }
    private var baseLoad: Double { includeCurrent ? (live?.load ?? stats?.battery?.typicalLoadW ?? 0) : 0 }
    private var chosen: [Appliance] { Appliance.presets.filter { selected.contains($0.id) } }
    private var extra: Double { chosen.reduce(0) { $0 + $1.watts } }
    private var total: Double { baseLoad + extra }
    /// What the inverter must deliver if everything chosen peaks at once.
    private var peakTotal: Double { baseLoad + chosen.reduce(0) { $0 + $1.peakW } }
    private var hours: Double { total > 0 ? usableWh / total : 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    result
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: $includeCurrent) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Те, що вже працює")
                                Text("\(Int(live?.load ?? stats?.battery?.typicalLoadW ?? 0)) Вт зараз").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(PowerState.on.accent)
                    }
                    .glassCard(radius: 22, padding: 14)

                    SectionLabel(text: "Додати")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(Appliance.presets) { a in
                            let on = selected.contains(a.id)
                            Button {
                                withAnimation(.snappy) { if on { selected.remove(a.id) } else { selected.insert(a.id) } }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: a.symbol).font(.title3)
                                        .foregroundStyle(on ? PowerState.on.accent : .secondary)
                                    Text(a.name).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                                    Text(a.peakW < 500 ? "≈ \(Int(a.watts)) Вт" : "≈ \(Int(a.watts)) Вт · пік \(Fmt.number(a.peakW / 1000)) кВт")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                                    if !a.model.isEmpty {
                                        Text(a.model).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(on ? PowerState.on.accent.opacity(0.14) : Color.primary.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(on ? PowerState.on.accent.opacity(0.6) : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .sensoryFeedback(.selection, trigger: on)
                        }
                    }
                    Text("Оцінка: ємність \(Fmt.number(capacityKwh)) кВт·год, розряд до 10%. Вати — типові для твоїх моделей (≈): холодильник, бойлер і кондиціонери працюють циклами, посудомийка й пральна гріють воду лише частину програми. Інвертор живить одну фазу — прилади на інших фазах без світла не працюють.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(20)
            }
            .background(AmbientBackground(state: total > inverterLimit ? .off : .on))
            .navigationTitle("Що можна ввімкнути?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }

    private var untilText: String {
        let end = Date.now.addingTimeInterval(hours * 3600)
        if Fmt.kyivCalendar.isDate(end, inSameDayAs: .now) { return Fmt.time(end) }
        return end.formatted(.dateTime.weekday(.abbreviated).locale(Fmt.uk)) + " " + Fmt.time(end)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: live?.soc == nil ? "Батарея (немає даних — рахую від 100%)" : "Батарея \(Int(soc))%")
            if total > inverterLimit {
                Label("\(Fmt.number(total / 1000)) кВт — більше, ніж тягне інвертор (6 кВт)", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(PowerState.off.accent)
            } else if total <= 0 {
                Text("Нічого не ввімкнено").font(.display(28)).foregroundStyle(.secondary)
            } else {
                Text("≈ \(Fmt.duration(hours * 3600))")
                    .font(.display(44)).contentTransition(.numericText()).monospacedDigit()
                Text("до \(untilText) · навантаження \(Int(total)) Вт")
                    .font(.subheadline).foregroundStyle(.secondary)
                CapsuleMeter(fraction: total / inverterLimit, tint: total > inverterLimit * 0.8 ? Theme.warning : PowerState.on.accent, height: 6)
                Text("\(Int(total / inverterLimit * 100))% потужності інвертора").font(.caption2).foregroundStyle(.secondary)
                if peakTotal > inverterLimit {
                    Label("У піку (нагрів води, розігрів духовки) — до \(Fmt.number(peakTotal / 1000)) кВт: не вмикай це одночасно, інвертор відключиться від перевантаження",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
        }
        .glassCard()
        .animation(.snappy, value: total)
    }
}

/// Entry card on the «Зараз» tab.
struct CalculatorCard: View {
    let live: Live?
    let stats: Stats?
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "powerplug.portrait.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .modifier(GlassCircle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Що можна ввімкнути?").font(.headline)
                    Text("на скільки вистачить батареї").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .glassCard(radius: 24, padding: 14)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) { ApplianceCalculator(live: live, stats: stats).presentationDetents([.large]) }
    }
}
