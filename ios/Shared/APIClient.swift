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
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw APIError.unauthorized }
        if code == 404 && missingIsNil { return nil }
        guard code == 200 else { throw APIError.http(code) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
