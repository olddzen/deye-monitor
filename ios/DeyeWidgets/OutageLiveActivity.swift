import ActivityKit
import SwiftUI
import WidgetKit

struct OutageLiveActivity: Widget {
    private let red = PowerState.off.accent
    private let green = PowerState.on.accent

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OutageAttributes.self) { context in
            LockScreenOutage(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let restored = s.restoredAt != nil
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(restored ? "Світло дали" : "Без світла", systemImage: restored ? "bolt.fill" : "bolt.slash.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(restored ? green : red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let soc = s.soc {
                        Label("\(Int(soc))%", systemImage: "battery.75percent").font(.caption.weight(.semibold)).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if let r = s.restoredAt {
                        Text("не було \(Fmt.duration(r.timeIntervalSince(s.since)))").font(.title3.weight(.semibold))
                    } else if let end = s.plannedEnd, end > .now {
                        VStack(spacing: 0) {
                            Text(timerInterval: Date.now...end, countsDown: true)
                                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                                .multilineTextAlignment(.center)
                            Text("увімкнуть о \(Fmt.time(end))").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(timerInterval: s.since...Date.distantFuture, countsDown: false)
                            .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            .multilineTextAlignment(.center)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !restored, let empty = s.emptyAt, empty > .now {
                        VStack(spacing: 4) {
                            ProgressView(timerInterval: Date.now...empty, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(red)
                            HStack {
                                Text("батареї вистачить до \(Fmt.time(empty))")
                                Spacer()
                                if let load = s.load { Text("\(Int(load)) Вт") }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: restored ? "bolt.fill" : "bolt.slash.fill").foregroundStyle(restored ? green : red)
            } compactTrailing: {
                if restored {
                    Text("є").foregroundStyle(green)
                } else if let end = s.plannedEnd, end > .now {
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .monospacedDigit().frame(maxWidth: 56).foregroundStyle(red)
                } else {
                    Text(timerInterval: s.since...Date.distantFuture, countsDown: false)
                        .monospacedDigit().frame(maxWidth: 56).foregroundStyle(red)
                }
            } minimal: {
                Image(systemName: restored ? "bolt.fill" : "bolt.slash.fill").foregroundStyle(restored ? green : red)
            }
        }
    }
}

private struct LockScreenOutage: View {
    let state: OutageAttributes.ContentState

    var body: some View {
        let restored = state.restoredAt != nil
        let tint = restored ? PowerState.on.accent : PowerState.off.accent
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(restored ? "Світло дали" : "Світла немає", systemImage: restored ? "bolt.fill" : "bolt.slash.fill")
                    .font(.headline).foregroundStyle(tint)
                Spacer()
                if let soc = state.soc {
                    Label("\(Int(soc))%", systemImage: "battery.75percent").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            if let r = state.restoredAt {
                Text("не було \(Fmt.duration(r.timeIntervalSince(state.since)))")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
            } else if let end = state.plannedEnd, end > .now {
                HStack(alignment: .firstTextBaseline) {
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("увімкнуть о \(Fmt.time(end))").font(.caption.weight(.semibold))
                        Text("за графіком · з \(Fmt.time(state.since))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let empty = state.emptyAt, empty > .now {
                    Text(empty > end ? "батареї вистачить з запасом (до \(Fmt.time(empty)))"
                                     : "⚠️ батареї вистачить лише до \(Fmt.time(empty))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                        .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text("з \(Fmt.time(state.since))").font(.caption).foregroundStyle(.secondary)
                }
                if let empty = state.emptyAt, empty > .now {
                    ProgressView(timerInterval: Date.now...empty, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(tint)
                    Text("батареї вистачить приблизно до \(Fmt.time(empty))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}
