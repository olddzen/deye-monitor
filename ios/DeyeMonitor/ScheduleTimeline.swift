import SwiftUI

/// One day (00:00–24:00) of plan and what really happened, picked with Вчора / Сьогодні / Завтра.
/// Drag to scroll (with inertia), pinch or double-tap to zoom, tap a block for the details.
struct ScheduleTimeline: View {
    let plan: [DateInterval]
    let fact: [DateInterval]
    /// Local midnights that can be shown: yesterday, today and tomorrow once YASNO has published it.
    let days: [Date]
    let now: Date

    enum Kind { case plan, fact }
    struct Item: Equatable {
        let kind: Kind
        let interval: DateInterval
    }

    static let minSpan: TimeInterval = 3 * 3600

    @State private var left: TimeInterval = 0       // seconds from range.start at the left edge
    @State private var span: TimeInterval = 24 * 3600
    @State private var dragStartLeft: TimeInterval?
    @State private var pinchStart: (left: TimeInterval, span: TimeInterval)?
    @State private var selected: Item?
    @State private var ready = false
    @State private var dayIndex: Int?

    private var todayIndex: Int {
        days.firstIndex { Fmt.kyivCalendar.isDate($0, inSameDayAs: now) } ?? max(0, days.count - 1)
    }
    private var currentIndex: Int { min(dayIndex ?? todayIndex, max(0, days.count - 1)) }
    /// The day on screen: midnight to the next midnight (23 or 25 h on DST days).
    private var range: DateInterval {
        let start = days.isEmpty ? Fmt.kyivCalendar.startOfDay(for: now) : days[currentIndex]
        let end = Fmt.kyivCalendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }

    private let laneLabel: CGFloat = 34
    private let height: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if days.count > 1 {
                Picker("День", selection: Binding(get: { currentIndex }, set: { pick($0) })) {
                    ForEach(days.indices, id: \.self) { i in Text(TimelineCanvas.dayName(days[i], now: now)).tag(i) }
                }
                .pickerStyle(.segmented)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: TimelineCanvas.headerH)
                    laneTitle("план").frame(height: TimelineCanvas.laneH)
                    Color.clear.frame(height: TimelineCanvas.gap)
                    laneTitle("факт").frame(height: TimelineCanvas.laneH)
                }
                .frame(width: laneLabel, alignment: .leading)
                GeometryReader { geo in
                    TimelineCanvas(plan: plan, fact: fact, range: range, now: now, selected: selected,
                                   left: left, span: span)
                        .contentShape(Rectangle())
                        .simultaneousGesture(drag(width: geo.size.width))
                        .simultaneousGesture(pinch(width: geo.size.width))
                        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { zoomToggle(at: $0.location.x, width: geo.size.width) })
                        .simultaneousGesture(SpatialTapGesture().onEnded { tap(at: $0.location, width: geo.size.width) })
                        .onAppear { if !ready { reset(); ready = true } }
                }
                .frame(height: height)
                .clipped()
            }
            controls
            if let selected {
                ScheduleItemDetail(item: selected, plan: plan, fact: fact, now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .animation(.snappy(duration: 0.25), value: selected)
    }

    private func laneTitle(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 8) {
            Text(spanLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            control("minus.magnifyingglass") { zoom(by: 1.6) }.disabled(span >= total - 60)
            control("plus.magnifyingglass") { zoom(by: 1 / 1.6) }.disabled(span <= Self.minSpan)
            Button {
                withAnimation(.snappy) { pick(todayIndex) }
            } label: {
                Label("Зараз", systemImage: "scope").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func control(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 28).background(.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var spanLabel: String {
        span >= total - 60 ? "уся доба" : "видно \(Int((span / 3600).rounded())) год"
    }

    // MARK: geometry

    private var total: TimeInterval { range.duration }

    private func clamp(left l: TimeInterval, span s: TimeInterval) -> TimeInterval {
        min(max(l, 0), max(0, total - s))
    }

    /// The whole day on screen.
    private func reset() {
        span = total
        left = 0
    }

    private func pick(_ i: Int) {
        dayIndex = i
        selected = nil
        reset()
    }

    private func zoom(by factor: Double, anchorFraction: Double = 0.5) {
        let newSpan = min(max(span * factor, Self.minSpan), total)
        let anchor = left + span * anchorFraction
        left = clamp(left: anchor - newSpan * anchorFraction, span: newSpan)
        span = newSpan
    }

    private func zoomToggle(at x: CGFloat, width: CGFloat) {
        let f = Double(x / max(width, 1))
        withAnimation(.snappy) { zoom(by: span > 8 * 3600 ? 6 * 3600 / span : total / span, anchorFraction: f) }
    }

    // MARK: gestures

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                // vertical drags belong to the page scroll
                guard abs(v.translation.width) > abs(v.translation.height) || dragStartLeft != nil else { return }
                if dragStartLeft == nil { dragStartLeft = left }
                let perPoint = span / Double(max(width, 1))
                left = clamp(left: dragStartLeft! - Double(v.translation.width) * perPoint, span: span)
            }
            .onEnded { v in
                guard dragStartLeft != nil else { return }
                dragStartLeft = nil
                let perPoint = span / Double(max(width, 1))
                // inertia, but never more than half a screen: a quick flick shouldn't throw you a day away
                let fling = max(-span / 2, min(span / 2, Double(v.predictedEndTranslation.width - v.translation.width) * perPoint))
                withAnimation(.easeOut(duration: 0.6)) { left = clamp(left: left - fling, span: span) }
            }
    }

    private func pinch(width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = (left, span) }
                guard let start = pinchStart else { return }
                let f = Double(v.startLocation.x / max(width, 1))
                let newSpan = min(max(start.span / Double(v.magnification), Self.minSpan), total)
                let anchor = start.left + start.span * f
                span = newSpan
                left = clamp(left: anchor - newSpan * f, span: newSpan)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func tap(at p: CGPoint, width: CGFloat) {
        let t = range.start.addingTimeInterval(left + Double(p.x / max(width, 1)) * span)
        let slop = span / Double(max(width, 1)) * 10   // forgiving for thin blocks
        let lane: Kind? = TimelineCanvas.lane(at: p.y)
        let list: [(Kind, DateInterval)] = (lane == .fact ? [] : plan.map { (.plan, $0) }) + (lane == .plan ? [] : fact.map { (.fact, $0) })
        let hit = list.first { $0.1.start.addingTimeInterval(-slop) <= t && t <= $0.1.end.addingTimeInterval(slop) }
        selected = hit.map { Item(kind: $0.0, interval: $0.1) }
    }
}

// MARK: - drawing

/// The drawing itself; animatable so a fling or a zoom button glides instead of jumping.
private struct TimelineCanvas: View, Animatable {
    let plan: [DateInterval]
    let fact: [DateInterval]
    let range: DateInterval
    let now: Date
    let selected: ScheduleTimeline.Item?
    var left: TimeInterval
    var span: TimeInterval

    static let headerH: CGFloat = 20, laneH: CGFloat = 28, gap: CGFloat = 8, axisH: CGFloat = 20
    static var planY: CGFloat { headerH }
    static var factY: CGFloat { headerH + laneH + gap }

    static func lane(at y: CGFloat) -> ScheduleTimeline.Kind? {
        if y < planY + laneH + gap / 2 { return y >= planY - 6 ? .plan : nil }
        return y <= factY + laneH + 6 ? .fact : nil
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(left, span) }
        set { left = newValue.first; span = newValue.second }
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let x0 = range.start.addingTimeInterval(left)
            let x = { (d: Date) -> CGFloat in CGFloat(d.timeIntervalSince(x0) / span) * w }
            let laneRect = { (y: CGFloat) in CGRect(x: 0, y: y, width: w, height: Self.laneH) }

            // lane backgrounds
            for y in [Self.planY, Self.factY] {
                ctx.fill(Path(roundedRect: laneRect(y), cornerRadius: 7), with: .color(.primary.opacity(0.06)))
            }

            // hour grid + labels, density follows the zoom
            let step = Self.tickStep(span: span)
            let cal = Fmt.kyivCalendar
            var t = cal.startOfDay(for: x0)
            while t < x0 { t = t.addingTimeInterval(step) }
            let end = x0.addingTimeInterval(span)
            while t <= end {
                let px = x(t)
                let midnight = cal.component(.hour, from: t) == 0 && cal.component(.minute, from: t) == 0
                var line = Path(); line.move(to: CGPoint(x: px, y: Self.planY)); line.addLine(to: CGPoint(x: px, y: Self.factY + Self.laneH))
                ctx.stroke(line, with: .color(.primary.opacity(midnight ? 0.35 : 0.1)), lineWidth: midnight ? 1.2 : 1)
                if px > 16 && px < w - 16 {  // a half-cut label reads as a different time
                    ctx.draw(Text(Fmt.time(t)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary),
                             at: CGPoint(x: px, y: Self.factY + Self.laneH + 11), anchor: .center)
                }
                t = t.addingTimeInterval(step)
            }

            let nx = x(now)

            // blocks
            func block(_ i: DateInterval, y: CGFloat, plan isPlan: Bool) {
                let a = x(i.start), b = x(i.end)
                guard b > 0, a < w else { return }
                let r = CGRect(x: a, y: y + 2, width: max(4, b - a), height: Self.laneH - 4)
                let path = Path(roundedRect: r, cornerRadius: 6)
                let isSel = selected?.interval == i && selected?.kind == (isPlan ? .plan : .fact)
                if isPlan {
                    ctx.fill(path, with: .color(Theme.critical.opacity(isSel ? 0.4 : 0.22)))
                    ctx.stroke(path, with: .color(Theme.critical.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 2]))
                } else {
                    ctx.fill(path, with: .color(Theme.critical.opacity(isSel ? 1 : 0.85)))
                }
                if isSel { ctx.stroke(path, with: .color(.primary), lineWidth: 2) }
                if r.width > 84 {
                    let label = "\(Fmt.time(i.start))–\(i.end > now && !isPlan ? "зараз" : Fmt.slotEnd(i))"
                    let visibleA = max(a, 0)
                    ctx.draw(Text(label).font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(isPlan ? Color.primary : Color.white),
                             at: CGPoint(x: min(visibleA + 6, b - 6), y: y + Self.laneH / 2), anchor: .leading)
                }
            }
            plan.forEach { block($0, y: Self.planY, plan: true) }
            fact.forEach { block($0, y: Self.factY, plan: false) }

            // now
            if nx >= 0 && nx <= w {
                var line = Path(); line.move(to: CGPoint(x: nx, y: Self.planY - 3)); line.addLine(to: CGPoint(x: nx, y: Self.factY + Self.laneH + 3))
                ctx.stroke(line, with: .color(.primary), lineWidth: 2.5)
                ctx.draw(Text("зараз").font(.caption2.weight(.bold)).foregroundStyle(.primary),
                         at: CGPoint(x: min(max(nx, 20), w - 20), y: 8), anchor: .center)
            }
        }
    }

    static func tickStep(span: TimeInterval) -> TimeInterval {
        let h = span / 3600
        return (h <= 4 ? 0.5 : h <= 8 ? 1 : h <= 16 ? 2 : h <= 30 ? 3 : 6) * 3600
    }

    static func dayName(_ d: Date, now: Date) -> String {
        let cal = Fmt.kyivCalendar
        if cal.isDate(d, inSameDayAs: now) { return "Сьогодні" }
        if cal.isDate(d, inSameDayAs: now.addingTimeInterval(86400)) { return "Завтра" }
        if cal.isDate(d, inSameDayAs: now.addingTimeInterval(-86400)) { return "Вчора" }
        return Fmt.dayMonth(d)
    }
}

// MARK: - details of the tapped block

private struct ScheduleItemDetail: View {
    let item: ScheduleTimeline.Item
    let plan: [DateInterval]
    let fact: [DateInterval]
    let now: Date

    var body: some View {
        let i = item.interval
        VStack(alignment: .leading, spacing: 6) {
            if item.kind == .plan {
                row("calendar", Theme.critical, "За графіком \(Fmt.slot(i))", "\(Fmt.dayMonth(i.start)) · \(Fmt.duration(i.duration))")
                if let f = fact.first(where: { $0.intersects(i) }) {
                    row("bolt.slash.fill", Theme.critical, "Фактично \(span(f))",
                        "вимкнули \(delta(f.start, i.start))" + (ongoing(f) ? "" : ", дали \(delta(f.end, i.end))"))
                } else if i.start > now {
                    row("clock", .secondary, "Почнеться через \(Fmt.duration(i.start.timeIntervalSince(now)))", nil)
                } else if i.end < now {
                    row("checkmark.circle.fill", Theme.good, "Світло так і не вимкнули", nil)
                } else {
                    row("checkmark.circle.fill", Theme.good, "Поки що світло є", "за графіком мали вимкнути о \(Fmt.time(i.start))")
                }
            } else {
                row("bolt.slash.fill", Theme.critical, "Без світла \(span(i))",
                    "\(Fmt.dayMonth(i.start)) · \(Fmt.duration((ongoing(i) ? now : i.end).timeIntervalSince(i.start)))" + (ongoing(i) ? " і триває" : ""))
                if let p = plan.first(where: { $0.intersects(i) }) {
                    row("calendar", .secondary, "За графіком \(Fmt.slot(p))",
                        "вимкнули \(delta(i.start, p.start))" + (ongoing(i) ? "" : ", дали \(delta(i.end, p.end))"))
                } else {
                    row("exclamationmark.triangle.fill", Theme.warning, "Поза графіком", "у плані на цей час відключення не було")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func ongoing(_ i: DateInterval) -> Bool { i.end >= now.addingTimeInterval(-60) }
    private func span(_ i: DateInterval) -> String { "\(Fmt.time(i.start))–\(ongoing(i) ? "зараз" : Fmt.time(i.end))" }

    /// "вчасно", "на 34 хв пізніше", "на 1 год раніше".
    private func delta(_ actual: Date, _ planned: Date) -> String {
        let d = actual.timeIntervalSince(planned)
        return abs(d) < 300 ? "вчасно" : "на \(Fmt.duration(abs(d))) \(d > 0 ? "пізніше" : "раніше")"
    }

    private func row(_ symbol: String, _ tint: Color, _ title: String, _ sub: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let sub { Text(sub).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }
}
