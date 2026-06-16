import Foundation

/// In-memory cache of TMDB responses (TTL) to avoid repeating requests — keyed
/// by path+query. Keeps browsing huge catalogs fast and cheap.
actor TMDBResponseCache {
    static let shared = TMDBResponseCache()
    private var entries: [String: (data: Data, expires: Date)] = [:]
    private let ttl: TimeInterval = 3600   // 1 hour
    private let maxEntries = 500

    func get(_ key: String) -> Data? {
        guard let e = entries[key] else { return nil }
        guard e.expires > Date() else { entries[key] = nil; return nil }
        return e.data
    }

    func set(_ key: String, _ data: Data) {
        if entries.count >= maxEntries {
            // Simple purge: drop expired entries and, if that's not enough, clear all.
            let now = Date()
            entries = entries.filter { $0.value.expires > now }
            if entries.count >= maxEntries { entries.removeAll() }
        }
        entries[key] = (data, Date().addingTimeInterval(ttl))
    }
}

struct CastMember: Identifiable, Sendable, Hashable {
    let id: Int
    let name: String
    let character: String?
    let profileURL: URL?
}

struct TVSeasonInfo: Sendable, Hashable {
    let number: Int
    let episodeCount: Int
}

enum TMDBClient {

    /// Main cast (max 12).
    static func credits(tmdbID: Int, isShow: Bool, key: String) async -> [CastMember] {
        struct Response: Decodable {
            struct Member: Decodable {
                let id: Int
                let name: String
                let character: String?
                let profile_path: String?
            }
            let cast: [Member]?
        }
        let kind = isShow ? "tv" : "movie"
        guard let data = await get(path: "/3/\(kind)/\(tmdbID)/credits", key: key, query: []),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (resp.cast ?? []).prefix(12).map {
            CastMember(
                id: $0.id,
                name: $0.name,
                character: $0.character,
                profileURL: $0.profile_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w185" + $0) }
            )
        }
    }

    /// Official seasons of a show (excluding specials).
    static func tvSeasons(tmdbID: Int, key: String) async -> [TVSeasonInfo] {
        struct Response: Decodable {
            struct Season: Decodable {
                let season_number: Int
                let episode_count: Int
            }
            let seasons: [Season]?
        }
        guard let data = await get(path: "/3/tv/\(tmdbID)", key: key, query: []),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (resp.seasons ?? [])
            .filter { $0.season_number > 0 }
            .map { TVSeasonInfo(number: $0.season_number, episodeCount: $0.episode_count) }
    }

    struct EpisodeMeta: Sendable {
        let name: String?
        let airDate: String?   // "yyyy-MM-dd"
    }

    /// Name and air date of a season's episodes (for missing/unaired detection).
    static func seasonEpisodes(tmdbID: Int, season: Int, key: String, lang: String) async -> [Int: EpisodeMeta] {
        struct Response: Decodable {
            struct Ep: Decodable {
                let episode_number: Int
                let name: String?
                let air_date: String?
            }
            let episodes: [Ep]?
        }
        let tmdbLang = lang == "es" ? "es-ES" : "en-US"
        guard let data = await get(
            path: "/3/tv/\(tmdbID)/season/\(season)",
            key: key,
            query: [URLQueryItem(name: "language", value: tmdbLang)]
        ),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [:] }
        return (resp.episodes ?? []).reduce(into: [:]) {
            $0[$1.episode_number] = EpisodeMeta(name: $1.name, airDate: $1.air_date)
        }
    }

    /// Combined credits of a person: TMDB IDs of movies and shows they act in.
    static func personCredits(personID: Int, key: String) async -> (movies: Set<Int>, shows: Set<Int>) {
        struct Response: Decodable {
            struct Credit: Decodable {
                let id: Int
                let media_type: String?
            }
            let cast: [Credit]?
        }
        guard let data = await get(path: "/3/person/\(personID)/combined_credits", key: key, query: []),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return ([], []) }
        var movies = Set<Int>()
        var shows = Set<Int>()
        for credit in resp.cast ?? [] {
            switch credit.media_type {
            case "movie": movies.insert(credit.id)
            case "tv": shows.insert(credit.id)
            default: break
            }
        }
        return (movies, shows)
    }

    /// Short biography of a person in the user's language.
    static func personBio(personID: Int, key: String, lang: String) async -> String? {
        await personDetails(personID: personID, key: key, lang: lang).biography
    }

    struct PersonDetails: Sendable {
        var biography: String?
        var birthday: String?       // "yyyy-MM-dd"
        var deathday: String?
        var placeOfBirth: String?
        var knownForDepartment: String?
    }

    /// Full profile of a person (bio, birth date, place, profession).
    static func personDetails(personID: Int, key: String, lang: String) async -> PersonDetails {
        struct Response: Decodable {
            let biography: String?
            let birthday: String?
            let deathday: String?
            let place_of_birth: String?
            let known_for_department: String?
        }
        let tmdbLang = lang == "es" ? "es-ES" : "en-US"
        guard let data = await get(
            path: "/3/person/\(personID)",
            key: key,
            query: [URLQueryItem(name: "language", value: tmdbLang)]
        ),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            return PersonDetails()
        }
        let bio = (resp.biography?.isEmpty == false) ? resp.biography : nil
        return PersonDetails(
            biography: bio,
            birthday: resp.birthday,
            deathday: resp.deathday,
            placeOfBirth: resp.place_of_birth,
            knownForDepartment: resp.known_for_department
        )
    }

    /// Generic GET exposed for the browse module (TMDBBrowse).
    static func rawGET(path: String, key: String, query: [URLQueryItem]) async -> Data? {
        await get(path: path, key: key, query: query)
    }

    private static func get(path: String, key: String, query: [URLQueryItem]) async -> Data? {
        // Cache key: path + query (without the api_key). Avoids repeating requests.
        let cacheKey = path + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        if let cached = await TMDBResponseCache.shared.get(cacheKey) { return cached }

        var comps = URLComponents(string: "https://api.themoviedb.org" + path)!
        var items = query
        var req: URLRequest
        if key.hasPrefix("eyJ") {
            comps.queryItems = items.isEmpty ? nil : items
            req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            items.append(URLQueryItem(name: "api_key", value: key))
            comps.queryItems = items
            req = URLRequest(url: comps.url!)
        }
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        await TMDBResponseCache.shared.set(cacheKey, data)
        return data
    }
    /// Validates a v3 key (`api_key`) or a v4 read token (`eyJ...`).
    static func validate(key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var req: URLRequest
        if trimmed.hasPrefix("eyJ") {
            req = URLRequest(url: URL(string: "https://api.themoviedb.org/3/configuration")!)
            req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        } else {
            guard let url = URL(string: "https://api.themoviedb.org/3/configuration?api_key=\(trimmed)") else { return false }
            req = URLRequest(url: url)
        }
        req.timeoutInterval = 10
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Tests the TMDB connection with the stored key.
    @MainActor
    static func testConnection() async -> ServiceTest {
        guard let key = SettingsStore.shared.tmdbKey, !key.isEmpty else {
            return .fail(tr(L.tmdbKeyMissing))
        }
        return await validate(key: key) ? .ok(tr(L.keyValid)) : .fail(tr(L.keyInvalid))
    }
}
