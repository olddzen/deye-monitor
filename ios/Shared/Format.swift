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

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = uk
        f.timeZone = kyiv
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func dayMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = uk
        f.timeZone = kyiv
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    static func number(_ x: Double?, digits: Int = 1) -> String {
        guard let x else { return "—" }
        let f = NumberFormatter()
        f.locale = uk
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: x)) ?? "—"
    }

    static var kyivCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kyiv
        c.locale = uk
        c.firstWeekday = 2
        return c
    }
}
