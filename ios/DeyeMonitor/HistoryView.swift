import SwiftUI

/// Tab 2 — patterns over time.
struct HistoryView: View {
    @ObservedObject var store: Store
    @State private var showDay = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Історія").font(.display(34, .bold)).padding(.top, 8)
                if let stats = store.response?.data {
                    summary(stats.week)
                    dayButton
                    if let ins = stats.insights, ins.weekKwh != nil {
                        ConsumptionCard(insights: ins, tariff: stats.energy30?.tariff)
                    }
                    if let charts = store.charts {
                        OutageCalendar(days: stats.daily30 ?? [], version: charts.version).equatable()
                        HeatmapCard(rows: stats.heatmap28 ?? [], version: charts.version).equatable()
                        ChargeChart(model: charts).equatable()
                        LoadChart(model: charts).equatable()
                        DailyChart(model: charts).equatable()
                    }
                    OutageList(outages: stats.outages ?? [])
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showDay) { DayDetailView() }
    }

    private var dayButton: some View {
        Button { showDay = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.series).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Будь-який день").font(.subheadline.weight(.semibold))
                    Text("графік потужності, батареї й відключень").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(radius: 22, padding: 14)
    }

    private func summary(_ w: WeekStats?) -> some View {
        let delta: String? = {
            guard let now = w?.offH, let prev = w?.prevOffH else { return nil }
            let d = now - prev
            return d == 0 ? "як минулого тижня" : "\(d > 0 ? "+" : "−")\(Fmt.number(abs(d))) год до минулого"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Останні 7 днів")
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Metric(value: Fmt.number(w?.offH), unit: "год", size: 40)
                Metric(value: "\(w?.count ?? 0)", unit: "відкл.", size: 40)
            }
            Text([delta, (w?.busy ?? []).isEmpty ? nil : "частіше о " + (w?.busy ?? []).map { "\(String(format: "%02d", $0[0]))–\(String(format: "%02d", $0[1]))" }.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .glassCard()
    }
}
