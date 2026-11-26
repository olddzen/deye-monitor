import Foundation

/// Energy maths for the battery screen. Capacity comes from the BMS rating (Ah × 51.2 V nominal),
/// reduced by the measured health when we have it; the minimum charge is the inverter's
/// discharge cut-off, set by the user (Deye doesn't expose it over the cloud API).
struct BatteryMath {
    static let nominalVoltage = 51.2
    static let defaultMinSoc = 10.0

    let soc: Double?
    let powerW: Double          // + discharge, − charge
    let ratedKwh: Double
    let healthKwh: Double?
    let minSoc: Double
    /// Off-grid the battery is the only source, so any discharge counts (no idle threshold).
    let offGrid: Bool
    /// What the inverter itself burns off-grid, measured from real SOC drops (35 W until measured).
    let selfUseW: Double
    static let defaultSelfUseW = 35.0

    init(live: Live?, stats: Stats?, minSoc: Double) {
        soc = live?.soc
        powerW = live?.batteryPower ?? 0
        let rated = live?.battery?.ratedAh.map { $0 * Self.nominalVoltage / 1000 }
        ratedKwh = rated ?? stats?.battery?.nominalKwh ?? 11.8
        healthKwh = stats?.battery?.capacityKwh
        self.minSoc = minSoc
        offGrid = live?.gridOn == false
        selfUseW = live?.selfUseW ?? stats?.battery?.selfUseW ?? Self.defaultSelfUseW
    }

    /// Best estimate of what the pack holds when full.
    var capacityKwh: Double { healthKwh ?? ratedKwh }
    var storedKwh: Double? { soc.map { $0 / 100 * capacityKwh } }
    var usableKwh: Double? { soc.map { max(0, $0 - minSoc) / 100 * capacityKwh } }
    var isCharging: Bool { powerW < -20 }
    var isDischarging: Bool { powerW > (offGrid ? 0 : 20) }

    /// Hours until the cut-off at a given load in watts.
    func hours(atLoad watts: Double) -> Double? {
        guard let usable = usableKwh, watts > 1 else { return nil }
        return usable * 1000 / watts
    }

    /// What the battery really gives off-grid for a given flat load: the load plus the inverter's own use.
    /// The battery-power reading is noisy at low currents, so it only wins when it's clearly higher.
    func realDraw(flatLoad: Double) -> Double { max(flatLoad + selfUseW, isDischarging ? powerW : 0) }

    /// Hours until the cut-off if the grid went down with this flat load.
    func hours(flatLoad: Double) -> Double? { hours(atLoad: realDraw(flatLoad: flatLoad)) }

    /// Hours to 100 % at the current charge power.
    var hoursToFull: Double? {
        guard let soc, isCharging, soc < 99 else { return nil }
        return (100 - soc) / 100 * capacityKwh * 1000 / abs(powerW)
    }
}
