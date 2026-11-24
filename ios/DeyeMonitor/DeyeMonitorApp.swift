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
    @Published var error: String?
    @Published var loading = false

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            response = try await APIClient.shared.fetch()
            error = nil
            WidgetCenter.shared.reloadAllTimelines()
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
                        ChargeChart(stats: stats)
                        LoadChart(stats: stats)
                        HeatmapCard(rows: stats.heatmap28 ?? [])
                        DailyChart(rows: stats.daily30 ?? [])
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
