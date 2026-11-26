import Combine
import SwiftUI
import WidgetKit

@main
struct DeyeWatchApp: App {
    var body: some Scene {
        WindowGroup { WatchStatusView().environment(\.locale, Fmt.uk) }
    }
}

@MainActor
final class WatchStore: ObservableObject {
    @Published var live: Live?
    @Published var error: String?

    func refresh() async {
        do {
            live = try await APIClient.shared.fetch().live
            error = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct WatchStatusView: View {
    @StateObject private var store = WatchStore()
    @Environment(\.scenePhase) private var phase
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let state = PowerState(store.live)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label(state.title, systemImage: state.symbol)
                    .font(.headline)
                    .foregroundStyle(state.accent)
                if let since = store.live?.sinceDate, state != .unknown {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("з \(Fmt.time(since))").font(.caption2).foregroundStyle(.secondary)
                } else if let u = store.live?.updatedDate {
                    Text("дані о \(Fmt.time(u))").font(.caption).foregroundStyle(.secondary)
                }
                if let soc = store.live?.soc {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(soc))").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("%").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let h = store.live?.runtimeH, h > 0 {
                            Text("≈ \(Fmt.short(h * 3600))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                    CapsuleMeter(fraction: soc / 100, tint: soc < 20 ? Theme.critical : soc < 40 ? Theme.warning : state.accent, height: 6)
                } else if store.live != nil {
                    Text("немає даних від BMS").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                if let load = store.live?.load {
                    Label("\(Int(load)) Вт", systemImage: "house.fill").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
                if let e = store.error, store.live == nil {
                    Text(e).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(state.accent.gradient.opacity(0.35), for: .navigation)
        .task { await store.refresh() }
        .onReceive(timer) { _ in Task { await store.refresh() } }
        .onChange(of: phase) { _, new in if new == .active { Task { await store.refresh() } } }
    }
}
