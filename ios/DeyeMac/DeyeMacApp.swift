import ServiceManagement
import SwiftUI

/// Menu bar app: ⚡ + battery % next to the clock; click for a glass panel with the details.
@main
struct DeyeMacApp: App {
    @StateObject private var store = MacStore()

    var body: some Scene {
        MenuBarExtra {
            MacPanel(store: store)
                .environment(\.locale, Fmt.uk)
        } label: {
            MenuLabel(live: store.live)
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MacStore: ObservableObject {
    @Published var response: DashboardResponse?
    @Published var error: String?
    private var timer: Timer?

    var live: Live? { response?.live }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        do {
            response = try await APIClient.shared.fetch()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Menu bar label

private struct MenuLabel: View {
    let live: Live?

    var body: some View {
        let state = PowerState(live)
        HStack(spacing: 3) {
            Image(systemName: state.symbol)
            if let soc = live?.soc {
                Text("\(Int(soc))%").monospacedDigit()
            } else if live == nil {
                Text("…")
            }
        }
    }
}

// MARK: - Panel

private struct MacPanel: View {
    @ObservedObject var store: MacStore
    @AppStorage("minSoc") private var minSoc = BatteryMath.defaultMinSoc
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let live = store.live
        let stats = store.response?.data
        let state = PowerState(live)
        let math = BatteryMath(live: live, stats: stats, minSoc: minSoc)
        VStack(alignment: .leading, spacing: 12) {
            // status + ticking counter
            HStack(spacing: 8) {
                Image(systemName: state.symbol).foregroundStyle(state.accent).font(.title3.weight(.semibold))
                Text(state.title).font(.display(18))
                Spacer()
                if let u = live?.updatedDate {
                    Text(Fmt.time(u)).font(.caption).foregroundStyle(.secondary).help("час останніх даних Deye")
                }
            }
            if let since = live?.sinceDate, state != .unknown {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.display(40)).monospacedDigit()
                Text("\(state == .on ? "з" : "вимкнули о") \(Fmt.time(since))"
                     + (live?.voltage.map { state == .on ? " · \(Int($0)) В" : "" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let e = store.error {
                Text(e).font(.caption).foregroundStyle(.secondary)
            }

            // battery
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Батарея")
                    Spacer()
                    Metric(value: math.soc.map { "\(Int($0))" } ?? "—", unit: "%", size: 22)
                }
                CapsuleMeter(fraction: (math.soc ?? 0) / 100,
                             tint: (math.soc ?? 100) < 20 ? Theme.critical : (math.soc ?? 100) < 40 ? Theme.warning : state.accent,
                             height: 6)
                HStack {
                    Text(batteryLine(math, live: live)).font(.caption)
                    Spacer()
                    if let kwh = math.usableKwh {
                        Text("\(Fmt.number(kwh)) кВт·год").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .glassCard(radius: 18, padding: 12)

            // flow
            HStack {
                flow("bolt.fill", live?.gridOn == true ? "\(Int(live?.gridPower ?? 0)) Вт" : "немає", "мережа")
                Spacer()
                flow("battery.100percent", live?.batteryPower.map { abs($0) > 20 ? "\(Int(abs($0))) Вт" : "0 Вт" } ?? "—",
                     (live?.batteryPower ?? 0) < -20 ? "заряд" : (live?.batteryPower ?? 0) > 20 ? "розряд" : "батарея")
                Spacer()
                flow("house.fill", "\(Int(live?.load ?? 0)) Вт", "квартира")
            }
            .glassCard(radius: 18, padding: 12)

            if let stats {
                TodayStripMini(outages: stats.outages ?? [])
                HStack {
                    Text("7 днів: \(Fmt.number(stats.week?.offH)) год без світла · \(stats.week?.count ?? 0) відкл.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Divider()
            HStack {
                Toggle("Запускати при вході", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox).font(.caption)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Оновити")
                Button("Вийти") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(AmbientBackground(state: state))
    }

    private func batteryLine(_ m: BatteryMath, live: Live?) -> String {
        if m.soc == nil { return "немає даних від BMS" }
        if m.isDischarging, let h = m.hours(atLoad: m.powerW) { return "розряд · вистачить ≈ \(Fmt.duration(h * 3600))" }
        if let h = m.hoursToFull { return "заряд · повна через \(Fmt.duration(h * 3600))" }
        if let h = m.hours(atLoad: live?.load ?? 0) { return "без світла вистачить ≈ \(Fmt.duration(h * 3600))" }
        return ""
    }

    private func flow(_ symbol: String, _ value: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 80)
    }
}

private struct TodayStripMini: View {
    let outages: [Outage]

    var body: some View {
        let cal = Fmt.kyivCalendar, now = Date.now, dayStart = cal.startOfDay(for: now)
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Сьогодні")
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) in CGFloat(d.timeIntervalSince(dayStart) / 86400) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(Theme.good.opacity(0.4)).frame(width: max(4, x(now)))
                    ForEach(outages.filter { ($0.endDate ?? now) > dayStart }) { o in
                        let s = max(o.startDate, dayStart), e = min(o.endDate ?? now, now)
                        if e > s { Capsule().fill(Theme.critical).frame(width: max(3, x(e) - x(s))).offset(x: x(s)) }
                    }
                }
            }
            .frame(height: 6)
        }
    }
}
