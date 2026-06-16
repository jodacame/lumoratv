import Foundation

// MARK: - Models

struct PlexPin: Decodable, Sendable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexResource: Decodable, Sendable {
    let name: String
    let provides: String
    let owned: Bool
    let clientIdentifier: String
    let accessToken: String?
    let connections: [PlexConnection]
}

struct PlexConnection: Decodable, Sendable {
    let uri: String
    let address: String
    let port: Int
    let local: Bool
    let relay: Bool
}

struct ResolvedServer: Identifiable, Sendable, Hashable {
    let serverID: String
    let name: String
    let baseURL: String
    let displayAddress: String
    let token: String
    let isLocal: Bool
    let owned: Bool
    var id: String { baseURL }
}

struct PlexLibrary: Identifiable, Sendable, Hashable {
    let key: String
    let title: String
    let type: String
    var id: String { key }
}

enum PlexError: LocalizedError {
    case badResponse
    case unreachable

    var errorDescription: String? {
        switch self {
        case .badResponse: tr(L.serverBadResponse)
        case .unreachable: tr(L.serverUnreachable)
        }
    }
}

// MARK: - Client

enum PlexClient {
    static let product = "LumoraTV"

    static var clientID: String {
        if let id = UserDefaults.standard.string(forKey: "plexClientID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "plexClientID")
        return id
    }

    static func request(_ url: URL, token: String? = nil, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        req.setValue(clientID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue("1.0", forHTTPHeaderField: "X-Plex-Version")
        req.setValue("Apple TV", forHTTPHeaderField: "X-Plex-Device")
        req.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        if let token { req.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return req
    }

    // MARK: plex.tv/link PIN flow

    static func createPin() async throws -> PlexPin {
        var comps = URLComponents(string: "https://plex.tv/api/v2/pins")!
        comps.queryItems = [URLQueryItem(name: "strong", value: "false")]
        let req = request(comps.url!, method: "POST")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlexError.badResponse
        }
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    static func checkPin(id: Int) async throws -> PlexPin {
        let req = request(URL(string: "https://plex.tv/api/v2/pins/\(id)")!)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlexError.badResponse
        }
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    // MARK: Server discovery

    static func fetchResources(accountToken: String) async throws -> [PlexResource] {
        var comps = URLComponents(string: "https://plex.tv/api/v2/resources")!
        comps.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "0"),
            URLQueryItem(name: "includeIPv6", value: "0"),
        ]
        let req = request(comps.url!, token: accountToken)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlexError.badResponse
        }
        let resources = try JSONDecoder().decode([PlexResource].self, from: data)
        return resources.filter { $0.provides.contains("server") }
    }

    /// Tries a server's connections (local first) and returns the first one that responds.
    static func resolve(resource: PlexResource, accountToken: String) async -> ResolvedServer? {
        let token = resource.accessToken ?? accountToken
        let candidates = resource.connections
            .filter { !$0.relay }
            .sorted { $0.local && !$1.local }
        for conn in candidates {
            if await isReachable(baseURL: conn.uri, token: token) {
                return ResolvedServer(
                    serverID: resource.clientIdentifier,
                    name: resource.name,
                    baseURL: conn.uri,
                    displayAddress: "\(conn.address):\(conn.port)",
                    token: token,
                    isLocal: conn.local,
                    owned: resource.owned
                )
            }
        }
        return nil
    }

    static func isReachable(baseURL: String, token: String) async -> Bool {
        guard let url = URL(string: baseURL + "/identity") else { return false }
        var req = request(url, token: token)
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: Server API

    private struct RootContainer: Decodable {
        struct MC: Decodable { let friendlyName: String? }
        let MediaContainer: MC
    }

    static func serverName(baseURL: String, token: String) async -> String? {
        guard let url = URL(string: baseURL + "/") else { return nil }
        var req = request(url, token: token)
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(RootContainer.self, from: data))?.MediaContainer.friendlyName
    }

    private struct SectionsContainer: Decodable {
        struct MC: Decodable {
            struct Directory: Decodable {
                let key: String
                let title: String
                let type: String
            }
            let Directory: [Directory]?
        }
        let MediaContainer: MC
    }

    static func libraries(baseURL: String, token: String) async throws -> [PlexLibrary] {
        guard let url = URL(string: baseURL + "/library/sections") else { throw PlexError.unreachable }
        let req = request(url, token: token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PlexError.badResponse }
        let container = try JSONDecoder().decode(SectionsContainer.self, from: data)
        return (container.MediaContainer.Directory ?? []).map {
            PlexLibrary(key: $0.key, title: $0.title, type: $0.type)
        }
    }
}
