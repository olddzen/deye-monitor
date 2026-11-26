import Foundation

enum APIError: LocalizedError {
    case notConfigured, unauthorized, http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Апку не налаштовано: немає адреси або ключа (Config/Secrets.xcconfig)"
        case .unauthorized: return "Немає доступу: ключ апки не збігається з воркером"
        case .http(let code): return "Помилка сервера \(code)"
        }
    }
}

/// Talks to the Cloudflare worker. Base URL and token are baked in at build time from Secrets.xcconfig.
struct APIClient {
    static let shared = APIClient()

    private var base: String? { Bundle.main.object(forInfoDictionaryKey: "DeyeAPIBase") as? String }
    private var token: String? { Bundle.main.object(forInfoDictionaryKey: "DeyeAppToken") as? String }

    func fetch() async throws -> DashboardResponse {
        guard let r = try await get("/api/data", as: DashboardResponse.self) else { throw APIError.http(404) }
        return r
    }

    /// One day's 5-minute archive; nil when the server has no data for that day.
    func fetchDay(_ day: String) async throws -> DayDetail? {
        try await get("/api/day?date=\(day)", as: DayDetail.self, missingIsNil: true)
    }

    private func get<T: Decodable>(_ path: String, as: T.Type, missingIsNil: Bool = false) async throws -> T? {
        guard let base, !base.isEmpty, !base.contains("$("), let token, !token.isEmpty,
              let url = URL(string: base + path) else { throw APIError.notConfigured }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let exp = AppSignature.expires {   // the bot reminds a day before the app stops opening
            req.setValue(String(Int(exp.timeIntervalSince1970)), forHTTPHeaderField: "X-App-Expires")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw APIError.unauthorized }
        if code == 404 && missingIsNil { return nil }
        guard code == 200 else { throw APIError.http(code) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Self.demoOff(data, path: path))
    }

    /// Launch argument `-demoOff`: pretend the grid is down (to preview the outage screens).
    private static func demoOff(_ data: Data, path: String) -> Data {
        guard path == "/api/data", ProcessInfo.processInfo.arguments.contains("-demoOff"),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var live = root["live"] as? [String: Any] else { return data }
        live["gridOn"] = false
        live["voltage"] = 0
        live["gridPower"] = 0
        live["load"] = 640
        live["batteryPower"] = 660
        live["since"] = Date.now.timeIntervalSince1970 - 2400
        live["stale"] = false
        root["live"] = live
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }
}

/// When the provisioning profile the app was installed with runs out (free Apple teams: 7 days).
/// Nil on the simulator, in the App Store build, or if the profile can't be read.
enum AppSignature {
    static let expires: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>ExpirationDate</key>"),
              let open = text.range(of: "<date>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex) else { return nil }
        return ISO8601DateFormatter().date(from: String(text[open.upperBound..<close.lowerBound]))
    }()
}
