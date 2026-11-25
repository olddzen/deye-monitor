import SwiftUI

/// «Потік енергії»: the inverter in the middle of a line-drawn house, the grid, the battery and the
/// flat around it, connected by elbow lines along which soft pulses travel in the direction of power.
struct PowerFlowCard: View {
    let live: Live

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(text: "Потік енергії")
                Spacer()
                if let u = live.updatedDate {
                    Text(Fmt.time(u)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            PowerFlowDiagram(live: live).frame(height: 300)
        }
        .glassCard()
    }
}

private struct Flow {
    var active: Bool
    var forward: Bool   // along the path as drawn (source → inverter → sink)
    var color: Color
}

struct PowerFlowDiagram: View {
    let live: Live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var gridOn: Bool { live.gridOn == true }
    private var gp: Double { live.gridPower ?? 0 }
    private var bp: Double { live.batteryPower ?? 0 }
    private var load: Double { live.load ?? 0 }

    // grid → inverter (import), battery ↔ inverter, inverter → flat
    private var gridFlow: Flow { Flow(active: gridOn && abs(gp) > 5, forward: gp >= 0, color: Theme.good) }
    private var batteryFlow: Flow {
        Flow(active: live.soc != nil && abs(bp) > 20, forward: bp > 0, color: bp > 0 ? Theme.warning : Theme.good)
    }
    private var loadFlow: Flow { Flow(active: load > 5, forward: true, color: Theme.series) }

    var body: some View {
        GeometryReader { geo in
            let L = Layout(size: geo.size)
            ZStack {
                HouseOutline().stroke(.primary.opacity(0.07), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    .frame(width: L.size.width * 0.86, height: L.size.height * 0.82)
                    .position(x: L.size.width / 2, y: L.size.height * 0.52)

                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { t in
                    let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                    Canvas { ctx, _ in
                        draw(&ctx, L.gridPath, gridFlow, phase)
                        draw(&ctx, L.batteryPath, batteryFlow, phase)
                        draw(&ctx, L.loadPath, loadFlow, phase)
                    }
                }

                node(symbol: "bolt.fill", value: gridOn ? "\(Int(abs(gp))) Вт" : "—", caption: "Мережа",
                     chip: gridOn ? ("В мережі", Theme.good) : ("Немає", Theme.critical), dim: !gridOn)
                    .position(L.grid)
                node(symbol: batterySymbol, value: live.soc.map { "\(Int($0))%" } ?? "—",
                     caption: batteryCaption, chip: nil, dim: live.soc == nil)
                    .position(L.battery)
                node(symbol: "house.fill", value: "\(Int(load)) Вт", caption: "Квартира", chip: nil, dim: false)
                    .position(L.load)
                inverter.position(L.inverter)
            }
        }
    }

    private var batterySymbol: String {
        guard let s = live.soc else { return "battery.0percent" }
        return s > 87 ? "battery.100percent" : s > 62 ? "battery.75percent" : s > 37 ? "battery.50percent" : "battery.25percent"
    }

    private var batteryCaption: String {
        guard live.soc != nil else { return "Батарея" }
        if bp < -20 { return "заряд \(Int(-bp)) Вт" }
        if bp > 20 { return "розряд \(Int(bp)) Вт" }
        return "Батарея"
    }

    private func draw(_ ctx: inout GraphicsContext, _ path: Path, _ f: Flow, _ phase: Double) {
        let base = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: f.active ? [] : [3, 4])
        ctx.stroke(path, with: .color(f.active ? f.color.opacity(0.35) : Color.primary.opacity(0.15)), style: base)
        guard f.active else { return }
        // two soft pulses per path, travelling with the energy
        for k in 0..<2 {
            var p = (phase + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
            if !f.forward { p = 1 - p }
            let tail = 0.14
            let from = f.forward ? max(0, p - tail) : p, to = f.forward ? p : min(1, p + tail)
            let piece = path.trimmedPath(from: from, to: to)
            ctx.stroke(piece, with: .color(f.color.opacity(0.9)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            let head = path.trimmedPath(from: f.forward ? max(0, p - 0.001) : p, to: f.forward ? p : min(1, p + 0.001))
            if let pt = head.currentPoint {
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(f.color))
            }
        }
    }

    private func node(symbol: String, value: String, caption: String, chip: (String, Color)?, dim: Bool) -> some View {
        VStack(spacing: 5) {
            if let chip {
                Text(chip.0).font(.caption2.weight(.semibold)).foregroundStyle(chip.1)
            }
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: 54, height: 54)
                .modifier(GlassTile())
            Text(value).font(.display(17)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 96)
    }

    private var inverter: some View {
        VStack(spacing: 3) {
            Image(systemName: "rectangle.portrait.inset.filled")
                .font(.system(size: 22, weight: .regular))
                .frame(width: 60, height: 60)
                .modifier(GlassTile(stroke: Theme.series))
            Text("Інвертор").font(.caption2).foregroundStyle(.secondary)
        }
        .offset(y: 8)  // keep the tile itself on the line junction
    }
}

/// Positions and connector paths, all derived from the available size.
private struct Layout {
    let size: CGSize
    var inverter: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.5) }
    var grid: CGPoint { CGPoint(x: size.width * 0.84, y: size.height * 0.2) }
    var load: CGPoint { CGPoint(x: size.width * 0.84, y: size.height * 0.8) }
    var battery: CGPoint { CGPoint(x: size.width * 0.16, y: size.height * 0.5) }

    private var bus: CGFloat { size.width * 0.66 }  // vertical trunk between the inverter and the right column
    private let r: CGFloat = 12

    /// grid → inverter: left from the grid tile, down the trunk, into the inverter's right side.
    var gridPath: Path {
        elbow(from: CGPoint(x: grid.x - 29, y: grid.y + 12), via: bus, to: CGPoint(x: inverter.x + 31, y: inverter.y - 6))
    }
    /// battery → inverter.
    var batteryPath: Path {
        var p = Path()
        p.move(to: CGPoint(x: battery.x + 29, y: battery.y - 4))
        p.addLine(to: CGPoint(x: inverter.x - 31, y: inverter.y - 4))
        return p
    }
    /// inverter → flat.
    var loadPath: Path {
        elbow(from: CGPoint(x: inverter.x + 31, y: inverter.y + 6), via: bus, to: CGPoint(x: load.x - 29, y: load.y - 12))
    }

    /// Horizontal → vertical at x = via → horizontal, with rounded corners.
    private func elbow(from a: CGPoint, via x: CGFloat, to b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        p.addArc(tangent1End: CGPoint(x: x, y: a.y), tangent2End: CGPoint(x: x, y: b.y), radius: r)
        p.addArc(tangent1End: CGPoint(x: x, y: b.y), tangent2End: b, radius: r)
        p.addLine(to: b)
        return p
    }
}

/// A quiet line drawing of a house: two gabled volumes and a few windows. Our own, deliberately simple.
private struct HouseOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        // main volume
        let wall = CGRect(x: w * 0.18, y: h * 0.38, width: w * 0.64, height: h * 0.6)
        p.addRect(wall)
        p.move(to: CGPoint(x: w * 0.12, y: h * 0.42))
        p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.06))
        p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.42))
        // chimney
        p.move(to: CGPoint(x: w * 0.7, y: h * 0.25))
        p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.12))
        p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.12))
        p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.31))
        // door
        p.addRoundedRect(in: CGRect(x: w * 0.44, y: h * 0.74, width: w * 0.12, height: h * 0.24), cornerSize: CGSize(width: 4, height: 4))
        // windows
        for x in [0.24, 0.62] {
            let win = CGRect(x: w * x, y: h * 0.5, width: w * 0.14, height: h * 0.14)
            p.addRect(win)
            p.move(to: CGPoint(x: win.midX, y: win.minY)); p.addLine(to: CGPoint(x: win.midX, y: win.maxY))
            p.move(to: CGPoint(x: win.minX, y: win.midY)); p.addLine(to: CGPoint(x: win.maxX, y: win.midY))
        }
        // ground
        p.move(to: CGPoint(x: 0, y: h * 0.98)); p.addLine(to: CGPoint(x: w, y: h * 0.98))
        return p
    }
}

/// Rounded-square glass tile used for the diagram's nodes.
private struct GlassTile: ViewModifier {
    var stroke: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay(shape.strokeBorder(stroke ?? .clear, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}
