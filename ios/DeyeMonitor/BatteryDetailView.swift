import SwiftUI

/// Detailed battery screen: capacity and what's left, live charge/discharge, runtime planner,
/// BMS readings, today's and lifetime energy.
struct BatteryDetailView: View {
    let live: Live?
    let stats: Stats?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("minSoc") private var minSoc = BatteryMath.defaultMinSoc
    @State private var sliderPos = 0.35   // 0…1 on a log scale 30 W … 6 kW

    private var math: BatteryMath { BatteryMath(live: live, stats: stats, minSoc: minSoc) }
    private var state: PowerState { PowerState(live) }
    private var customWatts: Double { (30 * pow(200, sliderPos) / 10).rounded() * 10 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    capacityCard
                    flowCard
                    plannerCard
                    todayCard
                    bmsCard
                    lifetimeCard
                    settingsCard
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground(state: state))
            .navigationTitle("Батарея")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }

    // MARK: capacity & remaining

    private var capacityCard: some View {
        let m = math
        return VStack(spacing: 14) {
            ZStack {
                Circle().stroke(.primary.opacity(0.08), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: CGFloat((m.soc ?? 0) / 100))
                    .stroke(m.soc.map { $0 < 20 ? Theme.critical : $0 < 40 ? Theme.warning : state.accent } ?? Theme.noData,
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Capsule()  // reserve marker at the cut-off level
                    .fill(.primary.opacity(0.85))
                    .frame(width: 3, height: 24)
                    .offset(y: -105)
                    .rotationEffect(.degrees(minSoc / 100 * 360))
                VStack(spacing: 2) {
                    Text(m.soc.map { "\(Int($0))%" } ?? "—").font(.display(48)).monospacedDigit()
                    Text(m.storedKwh.map { "\(Fmt.number($0)) з \(Fmt.number(m.capacityKwh)) кВт·год" } ?? "немає даних від BMS")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 210, height: 210)
            .animation(.spring(duration: 0.8), value: m.soc)
            HStack {
                stat("Доступно", m.usableKwh.map { Fmt.number($0) } ?? "—", "кВт·год до \(Int(minSoc))%")
                Spacer()
                stat("Ємність", Fmt.number(m.capacityKwh), m.healthKwh == nil ? "кВт·год, паспорт" : "кВт·год, реальна")
                Spacer()
                stat("Резерв ▎", "\(Int(minSoc))%", "не розряджається")
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    // MARK: live flow

    private var flowCard: some View {
        let m = math
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Зараз")
            if m.soc == nil {
                Text("BMS не передає дані").font(.display(22)).foregroundStyle(.secondary)
            } else if m.isCharging, (m.soc ?? 0) >= 99 {
                Label("Повна · підтримується", systemImage: "battery.100percent.bolt").font(.headline).foregroundStyle(state.accent)
                Text("Інвертор подає \(Int(abs(m.powerW))) Вт, щоб тримати 100%").font(.subheadline).foregroundStyle(.secondary)
            } else if m.isCharging {
                Label("Заряджається", systemImage: "bolt.batteryblock.fill").font(.headline).foregroundStyle(state.accent)
                HStack(alignment: .firstTextBaseline) {
                    Metric(value: "\(Int(abs(m.powerW)))", unit: "Вт", size: 36)
                    Spacer()
                    if let h = m.hoursToFull {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("повна через").font(.caption).foregroundStyle(.secondary)
                            Text(Fmt.duration(h * 3600)).font(.display(20)).monospacedDigit()
                        }
                    }
                }
                if live?.battery?.chargeLimitA == 0 {
                    Text("BMS тримає заряд на максимумі, інвертор лише підживлює").font(.caption).foregroundStyle(.secondary)
                }
            } else if m.isDischarging {
                Label("Розряджається", systemImage: "battery.25percent").font(.headline).foregroundStyle(Theme.warning)
                HStack(alignment: .firstTextBaseline) {
                    Metric(value: "\(Int(m.powerW))", unit: "Вт", size: 36)
                    Spacer()
                    if let h = m.hours(flatLoad: live?.load ?? 0) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("вистачить на").font(.caption).foregroundStyle(.secondary)
                            Text(Fmt.duration(h * 3600)).font(.display(20)).monospacedDigit()
                            Text("до \(until(h))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Label("У спокої", systemImage: "battery.100percent").font(.headline)
                Text("Мережа живить квартиру напряму").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .glassCard()
    }

    // MARK: runtime planner (EcoFlow-style "remaining time")

    private var plannerCard: some View {
        let m = math
        let current = live?.load ?? 0
        let typical = stats?.battery?.typicalLoadW ?? 0
        let night = stats?.energy30?.baseLoadW ?? 0
        let rows: [(String, String, Double)] = [
            ("house.fill", "Як зараз", current),
            ("moon.fill", "Вночі", night >= 5 ? night : 0),
            ("clock.arrow.circlepath", "Як зазвичай під час відключень", typical),
            ("refrigerator.fill", "Мінімум: холодильник + роутер", 165),
        ].filter { $0.2 > 1 }
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "На скільки вистачить")
            if m.usableKwh == nil {
                Text("Рахую від повної батареї, бо BMS зараз не передає заряд").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.1) { icon, title, watts in
                HStack(spacing: 12) {
                    Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.subheadline)
                        Text("\(Int(watts)) Вт").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(runtime(watts)).font(.display(18)).monospacedDigit()
                }
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Своє навантаження").font(.subheadline)
                    Spacer()
                    Text("\(Int(customWatts)) Вт").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Slider(value: $sliderPos, in: 0...1).tint(state.accent)
                HStack(alignment: .firstTextBaseline) {
                    Text(runtime(customWatts)).font(.display(30)).monospacedDigit().contentTransition(.numericText())
                    Spacer()
                    if customWatts > 6000 {
                        Text("більше 6 кВт інвертора").font(.caption).foregroundStyle(Theme.critical)
                    } else if let h = hoursFromFullIfNeeded(customWatts) {
                        Text("до \(until(h))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .glassCard()
    }

    // MARK: today & lifetime

    private var todayCard: some View {
        let b = live?.battery, t = live?.today
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Сьогодні")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    energy("arrow.down.circle.fill", "Заряджено", b?.todayChargedKwh, state.accent)
                    energy("arrow.up.circle.fill", "Віддано", b?.todayDischargedKwh, Theme.warning)
                }
                GridRow {
                    energy("house.circle.fill", "Спожито", t?.consumptionKwh, Theme.series)
                    energy("bolt.circle.fill", "З мережі", t?.importedKwh, .secondary)
                }
            }
        }
        .glassCard()
    }

    private var bmsCard: some View {
        let b = live?.battery
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "BMS і інвертор")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    reading("Напруга", b?.voltage.map { Fmt.number($0, digits: 1) }, "В")
                    reading("Струм", b?.current.map { Fmt.number($0, digits: 1) }, "А")
                    reading("Потужність", live?.batteryPower.map { "\(Int(abs($0)))" }, "Вт")
                }
                GridRow {
                    reading("Темп. батареї", live?.batteryTemp.map { "\(Int($0))" }, "°C")
                    reading("Інвертор DC", live?.inverterTemp.map { "\(Int($0))" }, "°C")
                    reading("Інвертор AC", live?.acTemp.map { "\(Int($0))" }, "°C")
                }
                GridRow {
                    reading("Ліміт заряду", b?.chargeLimitA.map { "\(Int($0))" }, "А")
                    reading("Ліміт розряду", b?.dischargeLimitA.map { "\(Int($0))" }, "А")
                    reading("Напруга заряду", b?.chargeVoltage.map { Fmt.number($0, digits: 1) }, "В")
                }
            }
        }
        .glassCard()
    }

    private var lifetimeCard: some View {
        let b = live?.battery, m = math
        let cycles = b?.totalDischargedKwh.map { $0 / m.ratedKwh }
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "За весь час")
            HStack {
                stat("Заряджено", b?.totalChargedKwh.map { Fmt.number($0) } ?? "—", "кВт·год")
                Spacer()
                stat("Віддано", b?.totalDischargedKwh.map { Fmt.number($0) } ?? "—", "кВт·год")
                Spacer()
                stat("Цикли", cycles.map { Fmt.number($0, digits: 2) } ?? "—", "з ~6000")
            }
            if let h = stats?.battery?.health {
                CapsuleMeter(fraction: h / 100, tint: Theme.good, height: 6)
                Text("Здоров'я \(Int(h))% · оцінка за глибокими розрядами").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Здоров'я оціниться після розряду глибше 15% під час відключення").font(.caption).foregroundStyle(.secondary)
            }
            if let ah = b?.ratedAh {
                Text("Паспорт: \(Int(ah)) А·год × \(Fmt.number(BatteryMath.nominalVoltage)) В = \(Fmt.number(ah * BatteryMath.nominalVoltage / 1000)) кВт·год LiFePO₄")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .glassCard()
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Мінімальний заряд")
                Spacer()
                Text("\(Int(minSoc))%").font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Slider(value: $minSoc, in: 0...50, step: 5).tint(state.accent)
            Text("Нижче цього рівня інвертор не розряджає батарею (налаштування Deye «Shutdown/Low batt»). Усі розрахунки враховують цей резерв.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()
    }

    // MARK: helpers

    private func runtime(_ watts: Double) -> String {
        guard watts <= 6000 else { return "—" }
        let usable = math.usableKwh ?? (100 - minSoc) / 100 * math.capacityKwh
        return "≈ " + Fmt.duration(usable * 1000 / max(watts, 1) * 3600)
    }

    private func hoursFromFullIfNeeded(_ watts: Double) -> Double? {
        let usable = math.usableKwh ?? (100 - minSoc) / 100 * math.capacityKwh
        return watts > 1 ? usable * 1000 / watts : nil
    }

    private func until(_ hours: Double) -> String {
        let end = Date.now.addingTimeInterval(hours * 3600)
        if Fmt.kyivCalendar.isDate(end, inSameDayAs: .now) { return Fmt.time(end) }
        return end.formatted(.dateTime.weekday(.abbreviated).locale(Fmt.uk)) + " " + Fmt.time(end)
    }

    private func stat(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.display(22)).monospacedDigit()
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func energy(_ icon: String, _ title: String, _ kwh: Double?, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Metric(value: kwh.map { Fmt.number($0) } ?? "—", unit: "кВт·год", size: 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reading(_ title: String, _ value: String?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Metric(value: value ?? "—", unit: unit, size: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
