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
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let live = store.response?.live {
                        HeroCard(live: live, stats: store.response?.data)
                        HStack(alignment: .top, spacing: 12) {
                            BatteryRing(live: live)
                            PowerFlow(live: live)
                        }
                    } else if store.error == nil {
                        ProgressView().padding(60)
                    }
                    if let error = store.error, store.response == nil {
                        Card { Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                    }
                    if let stats = store.response?.data {
                        WeekTiles(stats: stats)
                        TodayStrip(outages: stats.outages ?? [])
                        if let charts = store.charts {
                            ChargeChart(model: charts).equatable()
                            LoadChart(model: charts).equatable()
                            HeatmapCard(rows: stats.heatmap28 ?? [], version: charts.version).equatable()
                            DailyChart(model: charts).equatable()
                        }
                        OutageList(outages: stats.outages ?? [])
                        DetailsCard(stats: stats)
                    }
                    footer
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("Deye монітор")
            .refreshable { await store.refresh() }
        }
        .task { await store.refresh() }
        .onReceive(timer) { _ in Task { await store.refresh() } }
        .onChange(of: phase) { _, new in if new == .active { Task { await store.refresh() } } }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if let u = store.response?.live?.updatedDate { Text("живі дані Deye на \(Fmt.time(u))") }
            if let g = store.response?.generatedAt { Text("статистика на \(Fmt.time(Date(timeIntervalSince1970: g)))") }
            if let e = store.error, store.response != nil { Text("⚠️ \(e)") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}
