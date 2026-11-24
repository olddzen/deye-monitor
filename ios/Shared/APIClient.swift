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
        guard let base, !base.isEmpty, !base.contains("$("), let token, !token.isEmpty,
              let url = URL(string: base + "/api/data") else { throw APIError.notConfigured }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw APIError.unauthorized }
        guard code == 200 else { throw APIError.http(code) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DashboardResponse.self, from: data)
    }
}
