import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Hero

struct HeroCard: View {
    let live: Live
    let stats: Stats?
    @State private var pulse = false

    private var tint: Color { live.isStale ? Theme.warning : (live.gridOn == true ? Theme.good : Theme.critical) }

    private var headline: String {
        if live.error != nil { return "Дані недоступні" }
        if live.isStale { return "Deye мовчить" }
        return live.gridOn == true ? "Світло є" : "Світла немає"
    }

    private var sinceDate: Date? {
        if let s = live.sinceDate { return s }
        if live.gridOn == false, let open = stats?.outages?.last(where: { $0.end == nil }) { return open.startDate }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(tint, lineWidth: 2).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 0.8))
                    Text(live.isStale ? "Немає свіжих даних" : live.gridOn == true ? "Мережа є" : "Мережі немає")
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
                Spacer()
                Text(live.isStale ? "📵" : live.gridOn == true ? "💡" : "🕯️").font(.system(size: 52))
            }
            Text(headline).font(.system(size: 36, weight: .bold, design: .rounded))
            if live.isStale, let u = live.updatedDate {
                Text("останні дані о \(Fmt.time(u))").font(.title3.weight(.semibold))
                Text("Найімовірніше, у квартирі немає світла й інтернету").font(.footnote).foregroundStyle(.secondary)
            } else if let since = sinceDate {
                // auto-updating "6 год 18 хв"
                (Text("вже ") + Text(since, style: .relative)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("\(live.gridOn == true ? "дали" : "вимкнули") о \(Fmt.time(since))"
                     + (live.voltage.map { " · \(Int($0)) В" } ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if live.beyondDay == true {
                Text("понад добу").font(.title3.weight(.semibold))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [tint.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery ring

struct BatteryRing: View {
    let live: Live

    private var mode: String {
        guard live.soc != nil, let bp = live.batteryPower else { return "немає даних від BMS" }
        if bp < -20 { return "заряджається · \(Int(-bp)) Вт" }
        if bp > 20 { return "розряджається · \(Int(bp)) Вт" }
        return "у спокої"
    }

    var body: some View {
        Card {
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Theme.track, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: CGFloat((live.soc ?? 0) / 100))
                        .stroke(Theme.batteryColor(live.soc), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.8), value: live.soc)
                    Text(live.soc.map { "\(Int($0))%" } ?? "—")
                        .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 104, height: 104)
                Text(mode).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let h = live.runtimeH, h > 0 {
                    Text("вистачить ≈ \(Fmt.duration(h * 3600))").font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 150)
        .accessibilityLabel("Батарея \(live.soc.map { "\(Int($0)) відсотків" } ?? "немає даних"), \(mode)")
    }
}

// MARK: - Power flow

struct PowerFlow: View {
    let live: Live

    var body: some View {
        Card(title: "Потоки енергії") {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 14
                GeometryReader { geo in
                    let w = geo.size.width, grid = CGPoint(x: 22, y: 26), inv = CGPoint(x: w / 2, y: 26)
                    let home = CGPoint(x: w - 22, y: 26), bat = CGPoint(x: w / 2, y: 96)
                    let gp = live.gridPower ?? 0, load = live.load ?? 0, bp = live.batteryPower ?? 0
                    ZStack {
                        wire(grid, inv, active: live.gridOn == true && abs(gp) > 5, reverse: gp < 0, phase: phase)
                        wire(inv, home, active: load > 5, reverse: false, phase: phase)
                        wire(inv, bat, active: live.soc != nil && abs(bp) > 20, reverse: bp > 0, phase: phase)
                        node(grid, live.gridOn == true ? "⚡️" : "✖️", label: "Мережа",
                             value: live.gridOn == true ? "\(Int(gp)) Вт" : "немає")
                        node(inv, "🔄", label: nil, value: nil)
                        node(home, "🏠", label: "Квартира", value: "\(Int(load)) Вт")
                        node(bat, "🔋", label: nil, value: nil)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Батарея").font(.caption2).foregroundStyle(.secondary)
                            Text(batteryText(bp)).font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        .position(x: bat.x + 58, y: bat.y)
                    }
                }
                .frame(height: 122)
            }
        }
    }

    private func batteryText(_ bp: Double) -> String {
        guard live.soc != nil else { return "немає даних" }
        if abs(bp) <= 20 { return "у спокої" }
        return "\(bp < 0 ? "заряд" : "розряд") \(Int(abs(bp))) Вт"
    }

    private func wire(_ a: CGPoint, _ b: CGPoint, active: Bool, reverse: Bool, phase: Double) -> some View {
        ZStack {
            Path { p in p.move(to: a); p.addLine(to: b) }
                .stroke(Theme.line, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            if active {
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .stroke(Theme.series, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 9],
                                                             dashPhase: reverse ? phase : -phase))
            }
        }
    }

    private func node(_ p: CGPoint, _ icon: String, label: String?, value: String?) -> some View {
        VStack(spacing: 2) {
            Text(icon).font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(Theme.tile, in: Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1.5))
            if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
            if let value { Text(value).font(.caption.weight(.semibold)).monospacedDigit() }
        }
        .fixedSize()
        .position(x: p.x, y: p.y + (label == nil ? 0 : 18))
    }
}

// MARK: - Tiles

struct Tile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}

struct WeekTiles: View {
    let stats: Stats

    var body: some View {
        let w = stats.week, b = stats.battery, e = stats.energy30
        let delta: String? = {
            guard let now = w?.offH, let prev = w?.prevOffH else { return nil }
            let d = now - prev
            return "\(d > 0 ? "▲" : d < 0 ? "▼" : "=") \(Fmt.number(abs(d))) год до мин. тижня"
        }()
        Card(title: "Останні 7 днів") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                Tile(title: "Без світла", value: "\(Fmt.number(w?.offH)) год",
                     detail: delta ?? "\(Fmt.number(w?.share))% часу")
                Tile(title: "Відключень", value: "\(w?.count ?? 0)",
                     detail: (w?.count ?? 0) > 0 ? "найдовше \(Fmt.number(w?.longestH)) год" : "жодного 🎉")
                Tile(title: "Батарея", value: b?.health.map { "\(Int($0))%" } ?? "\(Fmt.number(b?.cyclesTotal, digits: 2)) цикл.",
                     detail: b?.health != nil ? "ємність \(Fmt.number(b?.capacityKwh)) кВт·год" : "ємність ще оцінюється")
                Tile(title: "Енергія, 30 днів", value: "\(Fmt.number(e?.importKwh)) кВт·год",
                     detail: "≈ \(Int(e?.costUah ?? 0)) ₴ з мережі")
            }
        }
    }
}
