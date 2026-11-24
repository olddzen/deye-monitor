import SwiftUI

struct Appliance: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let watts: Double

    static let presets: [Appliance] = [
        .init(id: "fridge", name: "Холодильник", symbol: "refrigerator.fill", watts: 150),
        .init(id: "router", name: "Роутер", symbol: "wifi.router.fill", watts: 15),
        .init(id: "laptop", name: "Ноутбук", symbol: "laptopcomputer", watts: 60),
        .init(id: "tv", name: "Телевізор", symbol: "tv.fill", watts: 100),
        .init(id: "lights", name: "Світло в кімнатах", symbol: "lightbulb.fill", watts: 40),
        .init(id: "washer", name: "Пральна машина", symbol: "washer.fill", watts: 500),
        .init(id: "microwave", name: "Мікрохвильовка", symbol: "microwave.fill", watts: 1200),
        .init(id: "heater", name: "Обігрівач", symbol: "heater.vertical.fill", watts: 1000),
        .init(id: "boiler", name: "Бойлер", symbol: "drop.degreesign.fill", watts: 1500),
        .init(id: "kettle", name: "Чайник", symbol: "cup.and.saucer.fill", watts: 2000),
    ]
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
    private var extra: Double { Appliance.presets.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.watts } }
    private var total: Double { baseLoad + extra }
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
                                    Text("\(Int(a.watts)) Вт").font(.caption).foregroundStyle(.secondary)
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
                    Text("Оцінка: ємність \(Fmt.number(capacityKwh)) кВт·год, розряд до 10%. Реальний час залежить від того, як часто вмикаються прилади (холодильник, бойлер працюють циклами).")
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
