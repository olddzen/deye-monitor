import Foundation

/// Response of the worker's GET /api/data (same payload the Telegram dashboard uses).
struct DashboardResponse: Decodable {
    let live: Live?
    let data: Stats?
    let generatedAt: Double?
    let schedule: Schedule?
    let appliances: ApplianceSnapshot?
}

/// SmartThings appliances right now (worker, cached 60 s).
struct ApplianceSnapshot: Decodable {
    let at: Double?
    let devices: [ApplianceLive]?
}

struct ApplianceLive: Decodable, Identifiable {
    let id: String
    let label: String?
    let kind: String?
    let on: Bool?
    let power: Double?
    let energyWh: Double?
    let state: String?
    let job: String?
    let remainingMin: Double?
    let watched: Bool?
}

/// Per-appliance energy from the collected history (GitHub workflow).
struct ApplianceStat: Decodable, Identifiable {
    let id: String
    let label: String?
    let kind: String?
    let todayKwh: Double?
    let weekKwh: Double?
    let monthKwh: Double?
    let dailyKwh: [Double]?
    let since: Double?
}

/// Planned outages for our YASNO group (today / tomorrow), minutes from local midnight.
struct Schedule: Decodable {
    let group: String
    let updatedOn: String?
    let today: ScheduleDay?
    let tomorrow: ScheduleDay?
}

struct ScheduleDay: Decodable {
    let date: String
    let status: String
    let off: [[Double]]

    var applies: Bool { status == "ScheduleApplies" }
    var statusText: String {
        switch status {
        case "ScheduleApplies": return "діє графік"
        case "WaitingForSchedule": return "графік ще не опубліковано"
        case "EmergencyShutdowns": return "екстрені відключення"
        default: return status
        }
    }
    /// Local midnight of this day (the API sends an ISO date with the Kyiv offset).
    var start: Date? { ScheduleDay.iso.date(from: date) }
    /// Planned outages as absolute intervals.
    var intervals: [DateInterval] {
        guard let start else { return [] }
        return off.compactMap { o in
            o.count == 2 && o[1] > o[0] ? DateInterval(start: start.addingTimeInterval(o[0] * 60),
                                                         end: start.addingTimeInterval(o[1] * 60)) : nil
        }
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

struct Live: Decodable {
    let now: Double?
    let updated: Double?
    let stale: Bool?
    let gridOn: Bool?
    let since: Double?
    let beyondDay: Bool?
    let voltage: Double?
    let freq: Double?
    let gridPower: Double?
    let load: Double?
    let soc: Double?
    let batteryPower: Double?
    let runtimeH: Double?
    let batteryTemp: Double?
    let inverterTemp: Double?
    let error: String?
    let battery: BatteryLive?
    let today: TodayLive?
    let acTemp: Double?

    var isStale: Bool { stale ?? (updated == nil) }
    var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }
    var updatedDate: Date? { updated.map { Date(timeIntervalSince1970: $0) } }
}

struct BatteryLive: Decodable {
    let voltage: Double?
    let current: Double?
    let bmsVoltage: Double?
    let bmsCurrent: Double?
    let chargeVoltage: Double?
    let chargeLimitA: Double?
    let dischargeLimitA: Double?
    let ratedAh: Double?
    let todayChargedKwh: Double?
    let todayDischargedKwh: Double?
    let totalChargedKwh: Double?
    let totalDischargedKwh: Double?
}

struct TodayLive: Decodable {
    let consumptionKwh: Double?
    let importedKwh: Double?
}

struct Outage: Decodable, Identifiable {
    let start: Double
    let end: Double?
    let uncertain: Bool
    var id: Double { start }

    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date? { end.map { Date(timeIntervalSince1970: $0) } }
    func duration(now: Date = .now) -> TimeInterval { (end ?? now.timeIntervalSince1970) - start }

    init(from decoder: Decoder) throws {  // [start, end|null, uncertain]
        var c = try decoder.unkeyedContainer()
        start = try c.decode(Double.self)
        end = try c.decodeIfPresent(Double.self)
        uncertain = (try? c.decode(Bool.self)) ?? false
    }
}

struct SeriesPoint: Decodable, Identifiable {
    let ts: Double
    let soc: Double?
    let load: Double?
    let voltage: Double?
    var id: Double { ts }
    var date: Date { Date(timeIntervalSince1970: ts) }

    init(from decoder: Decoder) throws {  // [ts, soc, load, grid_v]
        var c = try decoder.unkeyedContainer()
        ts = try c.decode(Double.self)
        soc = try c.decodeIfPresent(Double.self)
        load = try c.decodeIfPresent(Double.self)
        voltage = try c.decodeIfPresent(Double.self)
    }
}

struct DayRow: Decodable, Identifiable {
    let date: String
    let offMin: Double?
    let loadKwh: Double?
    let importKwh: Double?
    let hasData: Bool?
    var id: String { date }
    var day: Date { Fmt.isoDay.date(from: date) ?? .now }
}

struct WeekStats: Decodable {
    let count: Int?
    let offH: Double?
    let longestH: Double?
    let avgH: Double?
    let share: Double?
    let prevCount: Int?
    let prevOffH: Double?
    let busy: [[Int]]?
}

struct BatteryStats: Decodable {
    let nominalKwh: Double?
    let capacityKwh: Double?
    let health: Double?
    let cyclesTotal: Double?
    let discharged30d: Double?
    let tempMax: Double?
    let inverterTempMax: Double?
    let coverage: Double?
    let typicalLoadW: Double?

    // convertFromSnakeCase turns "discharged_30d" into "discharged30D"
    enum CodingKeys: String, CodingKey {
        case nominalKwh, capacityKwh, health, cyclesTotal, tempMax, inverterTempMax, coverage, typicalLoadW
        case discharged30d = "discharged30D"
    }
}

struct EnergyStats: Decodable {
    let loadKwh: Double?
    let importKwh: Double?
    let costUah: Double?
    let tariff: Double?
    let baseLoadW: Double?
}

struct GridStats: Decodable {
    let vMin: Double?
    let vMax: Double?
    let vAvg: Double?
    let lowPct: Double?
    let fMin: Double?
    let fMax: Double?
}

struct Stats: Decodable {
    let generatedAt: Double?
    let outages: [Outage]?
    let series7: [SeriesPoint]?
    let heatmap28: [[Double]]?
    let daily30: [DayRow]?
    let week: WeekStats?
    let battery: BatteryStats?
    let energy30: EnergyStats?
    let grid30: GridStats?
    let alerts30: [String: Int]?
    let insights: Insights?
    let appliances: [ApplianceStat]?
}

/// What eats the energy (last 14 days).
struct Insights: Decodable {
    let hourlyW: [Double?]?
    let baseLoadW: Double?
    let weekKwh: Double?
    let prevWeekKwh: Double?
    let importDayKwh: Double?
    let monthCostUah: Double?
    let standbyMonthKwh: Double?
    let standbyMonthUah: Double?
    let peakHour: Int?
    let eveningShare: Double?
}

/// GET /api/day?date=YYYY-MM-DD — one local day in 5-minute points.
struct DayDetail: Decodable {
    let date: String
    let start: Double
    let points: [DayPoint]
    let outages: [[Double]]
    let totals: DayTotals
}

struct DayPoint: Decodable, Identifiable {
    let ts: Double
    let voltage: Double?
    let gridW: Double?
    let loadW: Double?
    let soc: Double?
    let batteryW: Double?
    var id: Double { ts }
    var date: Date { Date(timeIntervalSince1970: ts) }

    init(from decoder: Decoder) throws {  // [ts, grid_v, grid_w, load_w, soc, battery_w]
        var c = try decoder.unkeyedContainer()
        ts = try c.decode(Double.self)
        voltage = try c.decodeIfPresent(Double.self)
        gridW = try c.decodeIfPresent(Double.self)
        loadW = try c.decodeIfPresent(Double.self)
        soc = try c.decodeIfPresent(Double.self)
        batteryW = try c.decodeIfPresent(Double.self)
    }
}

struct DayTotals: Decodable {
    let loadKwh: Double?
    let importKwh: Double?
    let costUah: Double?
    let offMin: Double?
    let outages: Int?
    let socMin: Double?
    let socMax: Double?
    let peakW: Double?
    let peakTs: Double?
    let vMin: Double?
    let vMax: Double?
}
