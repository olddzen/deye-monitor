import SwiftUI
import WidgetKit

@main
struct DeyeMonitorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, Fmt.uk)
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var response: DashboardResponse?
    @Published var charts: ChartModel?
    @Published var error: String?
    private var lastWidgetReload = Date.distantPast
    private var lastGridOn: Bool?

    func refresh() async {
        do {
            let r = try await APIClient.shared.fetch()
            let version = r.generatedAt ?? 0
            // heavy chart prep only when the 5-minute statistics actually changed
            if let stats = r.data, charts?.version != version {
                charts = await Task.detached(priority: .userInitiated) { ChartModel(stats: stats, version: version) }.value
            }
            response = r
            error = nil
            let grid = r.live?.gridOn
            if grid != lastGridOn || Date.now.timeIntervalSince(lastWidgetReload) > 600 {
                WidgetCenter.shared.reloadAllTimelines()
                lastWidgetReload = .now
                lastGridOn = grid
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        let state = PowerState(store.response?.live)
        TabView {
            NowView(store: store)
                .background(AmbientBackground(state: state))
                .tabItem { Label("Зараз", systemImage: "bolt.fill") }
            HistoryView(store: store)
                .background(AmbientBackground(state: state))
                .tabItem { Label("Історія", systemImage: "chart.xyaxis.line") }
            SystemView(store: store)
                .background(AmbientBackground(state: state))
                .tabItem { Label("Система", systemImage: "gauge.with.dots.needle.67percent") }
        }
        .tint(state.accent)
        .sensoryFeedback(.impact(weight: .medium), trigger: store.response?.live?.gridOn)
        .task { await store.refresh() }
        .onReceive(timer) { _ in Task { await store.refresh() } }
        .onChange(of: phase) { _, new in if new == .active { Task { await store.refresh() } } }
    }
}
