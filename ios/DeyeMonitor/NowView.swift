import SwiftUI

/// Tab 1 — the one question that matters, answered at a glance.
struct NowView: View {
    @ObservedObject var store: Store

    var body: some View {
        let live = store.response?.live
        let stats = store.response?.data
        let state = PowerState(live)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let live {
                    Hero(live: live, stats: stats, state: state)
                        .padding(.vertical, 18)
                    BatteryCard(live: live, stats: stats, state: state)
                    CalculatorCard(live: live, stats: stats)
                    FlowCard(live: live)
                } else if let error = store.error {
                    Text(error).foregroundStyle(.secondary).glassCard()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                }
                if let stats {
                    TodayCard(outages: stats.outages ?? [], accent: state.accent)
                    WeekGlance(week: stats.week)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
    }

    private var header: some View {
        HStack {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Fmt.uk)))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let u = store.response?.live?.updatedDate {
                Label(Fmt.time(u), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Hero: state word + a ticking counter

private struct Hero: View {
    let live: Live
    let stats: Stats?
    let state: PowerState

    private var since: Date? {
        if let s = live.sinceDate { return s }
        if live.gridOn == false, let open = stats?.outages?.last(where: { $0.end == nil }) { return open.startDate }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: state != .on)
                    .frame(width: 40, height: 40)
                    .modifier(GlassCircle())
                Text(state.title)
                    .font(.display(22))
            }
            if state == .unknown, let u = live.updatedDate {
                Text("останні дані о \(Fmt.time(u))").font(.display(40)).monospacedDigit()
                Text("Схоже, у квартирі немає світла й інтернету").font(.subheadline).foregroundStyle(.secondary)
            } else if let since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false, showsHours: true)
                    .font(.display(64, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("\(state == .on ? "з" : "вимкнули о") \(Fmt.time(since))"
                     + (live.voltage.map { state == .on ? " · \(Int($0)) В" : "" } ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if live.beyondDay == true {
                Text("понад добу").font(.display(44))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - Battery

private struct BatteryCard: View {
    let live: Live
    let stats: Stats?
    let state: PowerState
    @AppStorage("minSoc") private var minSoc = BatteryMath.defaultMinSoc
    @State private var open = false

    var body: some View {
        let soc = live.soc
        let bp = live.batteryPower ?? 0
        let math = BatteryMath(live: live, stats: stats, minSoc: minSoc)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Батарея")
                Spacer()
                if let t = live.batteryTemp {
                    Label("\(Int(t))°", systemImage: "thermometer.medium").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if let soc {
                HStack(alignment: .lastTextBaseline) {
                    Metric(value: "\(Int(soc))", unit: "%", size: 44)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(bp < -20 ? "заряджається" : bp > 20 ? "розряджається" : "у спокої")
                            .font(.subheadline.weight(.medium))
                        if abs(bp) > 20 { Text("\(Int(abs(bp))) Вт").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                CapsuleMeter(fraction: soc / 100, tint: soc < 20 ? Theme.critical : soc < 40 ? Theme.warning : state.accent)
                HStack {
                    if math.isDischarging, let h = math.hours(atLoad: bp) {
                        Label("вистачить ≈ \(Fmt.duration(h * 3600))", systemImage: "hourglass")
                    } else if let h = math.hoursToFull {
                        Label("повна через \(Fmt.duration(h * 3600))", systemImage: "bolt.fill")
                    } else if let h = math.hours(atLoad: live.load ?? 0) {
                        Label("без світла вистачить ≈ \(Fmt.duration(h * 3600))", systemImage: "hourglass")
                    }
                    Spacer()
                    if let kwh = math.usableKwh {
                        Text("\(Fmt.number(kwh)) кВт·год").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.subheadline.weight(.medium))
            } else {
                Text("немає даних від BMS").font(.display(22)).foregroundStyle(.secondary)
            }
        }
        .glassCard()
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .sheet(isPresented: $open) { BatteryDetailView(live: live, stats: stats) }
    }
}

// MARK: - Power flow

private struct FlowCard: View {
    let live: Live
    @State private var phase: CGFloat = 0

    var body: some View {
        let gp = live.gridPower ?? 0, load = live.load ?? 0, bp = live.batteryPower ?? 0
        let gridOn = live.gridOn == true
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Енергія зараз")
            HStack(spacing: 0) {
                node("bolt.fill", gridOn ? "\(Int(gp)) Вт" : "немає", "мережа", dim: !gridOn)
                link(active: gridOn && abs(gp) > 5, reverse: gp < 0)
                node("battery.100percent.bolt", live.soc == nil ? "—" : abs(bp) <= 20 ? "0 Вт" : "\(Int(abs(bp))) Вт",
                     bp < -20 ? "заряд" : bp > 20 ? "розряд" : "батарея", dim: live.soc == nil)
                link(active: load > 5, reverse: false)
                node("house.fill", "\(Int(load)) Вт", "квартира", dim: false)
            }
        }
        .glassCard()
        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = 16 } }
    }

    private func node(_ symbol: String, _ value: String, _ caption: String, dim: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .modifier(GlassCircle())
                .opacity(dim ? 0.4 : 1)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 78)
    }

    private func link(active: Bool, reverse: Bool) -> some View {
        Capsule()
            .stroke(active ? AnyShapeStyle(Theme.series) : AnyShapeStyle(.primary.opacity(0.12)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: active ? [1.5, 6] : [],
                                       dashPhase: reverse ? phase : -phase))
            .frame(height: 2.5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 38)
            .drawingGroup()
    }
}

// MARK: - Today

struct TodayCard: View {
    let outages: [Outage]
    let accent: Color

    var body: some View {
        let cal = Fmt.kyivCalendar
        let now = Date.now
        let dayStart = cal.startOfDay(for: now)
        let segs = outages.compactMap { o -> (Date, Date)? in
            let s = max(o.startDate, dayStart), e = min(o.endDate ?? now, now)
            return e > s ? (s, e) : nil
        }
        let total = segs.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Сьогодні")
                Spacer()
                Text(total > 0 ? "без світла \(Fmt.duration(total))" : "без відключень")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) in CGFloat(d.timeIntervalSince(dayStart) / 86400) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule().fill(Theme.good.opacity(0.35)).frame(width: max(6, x(now)))
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        Capsule().fill(Theme.critical).frame(width: max(4, x(seg.1) - x(seg.0))).offset(x: x(seg.0))
                    }
                    Circle().fill(.primary).frame(width: 6, height: 6).offset(x: x(now) - 3)
                }
            }
            .frame(height: 12)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { h in
                    Text(h).font(.caption2).foregroundStyle(.tertiary)
                    if h != "24" { Spacer() }
                }
            }
        }
        .glassCard()
    }
}

private struct WeekGlance: View {
    let week: WeekStats?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "7 днів")
                Metric(value: Fmt.number(week?.offH), unit: "год", size: 26)
                Text("без світла").font(.caption).foregroundStyle(.secondary)
            }
            .glassCard(radius: 24, padding: 16)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Відключень")
                Metric(value: "\(week?.count ?? 0)", unit: "", size: 26)
                Text((week?.count ?? 0) > 0 ? "найдовше \(Fmt.number(week?.longestH)) год" : "жодного")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .glassCard(radius: 24, padding: 16)
        }
    }
}
