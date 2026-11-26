import Foundation

/// Ukrainian formatting shared by the app and the widgets (times are always shown in Kyiv time).
enum Fmt {
    static let kyiv = TimeZone(identifier: "Europe/Kyiv") ?? .current
    static let uk = Locale(identifier: "uk_UA")

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "менше хвилини" }
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) д") }
        if h > 0 { parts.append("\(h) год") }
        if mm > 0 && d == 0 { parts.append("\(mm) хв") }
        return parts.joined(separator: " ")
    }

    /// Compact duration for small widgets: "45 хв", "3 год 20 хв", "1 д 4 год".
    static func short(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(max(m, 1)) хв" }
        if m < 1440 { return "\(m / 60) год" + (m % 60 >= 10 && m < 600 ? " \(m % 60) хв" : "") }
        return "\(m / 1440) д \(m % 1440 / 60) год"
    }

    // Formatters are expensive to create: build each once.
    private static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = uk
        f.timeZone = kyiv
        f.dateFormat = format
        return f
    }
    private static let hm = dateFormatter("HH:mm")
    private static let dm = dateFormatter("d MMM")
    static let isoDay = dateFormatter("yyyy-MM-dd")
    private static let numbers: [Int: NumberFormatter] = Dictionary(uniqueKeysWithValues: (0...2).map { d in
        let f = NumberFormatter()
        f.locale = uk
        f.maximumFractionDigits = d
        f.minimumFractionDigits = 0
        return (d, f)
    })

    static func time(_ date: Date) -> String { hm.string(from: date) }

    /// "21:40" today, "завтра 03:10", or "пн, 1 груд. 14:41" further away.
    static func until(_ date: Date, now: Date = .now) -> String {
        let cal = kyivCalendar
        if cal.isDate(date, inSameDayAs: now) { return time(date) }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) { return "завтра \(time(date))" }
        return wdm.string(from: date) + " " + time(date)
    }
    private static let wdm = dateFormatter("EE, d MMM")

    /// End of a planned slot: a slot that runs to midnight reads "24:00", not "00:00".
    static func slotEnd(_ i: DateInterval) -> String {
        kyivCalendar.component(.hour, from: i.end) == 0 && kyivCalendar.component(.minute, from: i.end) == 0
            && i.duration > 60 ? "24:00" : time(i.end)
    }

    /// "19:00–24:00"
    static func slot(_ i: DateInterval) -> String { "\(time(i.start))–\(slotEnd(i))" }
    static func dayMonth(_ date: Date) -> String { dm.string(from: date) }

    /// How old the inverter data is: "щойно", "4 хв тому", "1 год 10 хв тому".
    static func age(_ date: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(date)
        return s < 90 ? "щойно" : "\(duration(s)) тому"
    }

    /// Deye uploads about every 5 minutes; older than this means the picture may be out of date.
    static let staleAfter: TimeInterval = 12 * 60

    static func number(_ x: Double?, digits: Int = 1) -> String {
        guard let x else { return "—" }
        return numbers[min(max(digits, 0), 2)]?.string(from: NSNumber(value: x)) ?? "—"
    }

    static let kyivCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kyiv
        c.locale = uk
        c.firstWeekday = 2
        return c
    }()
}
