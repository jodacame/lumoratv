import Foundation

/// Low-level Trakt HTTP core: builds requests, injects the API key + optional
/// bearer token, decodes JSON. Shared by the read service and the auth flow.
/// Best-effort by design (social data) — failures return nil rather than throw.
enum TraktHTTP {
    static let base = "https://api.trakt.tv"

    static func request(_ path: String, method: String = "GET",
                        clientID: String, accessToken: String? = nil,
                        body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        if let accessToken { req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        return req
    }

    /// GET + decode JSON. Returns nil on any failure.
    static func get<T: Decodable>(_ path: String, as type: T.Type,
                                  clientID: String, accessToken: String? = nil) async -> T? {
        guard let req = request(path, clientID: clientID, accessToken: accessToken),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// POST a JSON body. Returns the HTTP status code (nil on transport failure).
    @discardableResult
    static func post(_ path: String, json: [String: Any],
                     clientID: String, accessToken: String? = nil) async -> Int? {
        guard let body = try? JSONSerialization.data(withJSONObject: json),
              let req = request(path, method: "POST", clientID: clientID, accessToken: accessToken, body: body),
              let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }

    /// POST returning (body, status) — for the device-code & token exchange.
    static func postRaw(_ path: String, json: [String: Any], clientID: String) async -> (Data, Int)? {
        guard let body = try? JSONSerialization.data(withJSONObject: json),
              let req = request(path, method: "POST", clientID: clientID, body: body),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        return (data, code)
    }
}
