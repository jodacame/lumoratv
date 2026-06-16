import Foundation
import GRDB

actor TMDBEnricher {
    static let shared = TMDBEnricher()

    private var running = false

    /// Full enrichment: localized metadata + logos, in the user's current language.
    func enrichAll() async {
        guard !running else { return }
        running = true
        defer { running = false }

        guard let key = await MainActor.run(body: { SettingsStore.shared.tmdbKey }) else { return }
        let lang = await MainActor.run { L10nStore.shared.effective }

        await enrichLocalizedMetadata(key: key, lang: lang)
        await enrichLogos(key: key, lang: lang)
        await enrichCast(key: key)
    }

    // MARK: Cast index (for "Because you like {actor}" and the people view)

    private func enrichCast(key: String) async {
        let pending: [MediaItem] = (try? await AppDatabase.shared.dbQueue.read { db in
            let indexed = try String.fetchSet(db, sql: "SELECT DISTINCT itemID FROM castEntry")
            return try MediaItem
                .filter(Column("tmdbID") != nil)
                .fetchAll(db)
                .filter { !indexed.contains($0.id) }
        }) ?? []
        guard !pending.isEmpty else { return }

        for chunk in pending.chunked(into: 10) {
            var entries: [CastEntry] = []
            await withTaskGroup(of: [CastEntry].self) { group in
                for item in chunk {
                    guard let tmdbID = item.tmdbID else { continue }
                    let isShow = item.type == "show"
                    let itemID = item.id
                    group.addTask {
                        let cast = await TMDBClient.credits(tmdbID: tmdbID, isShow: isShow, key: key)
                        return cast.prefix(10).map {
                            CastEntry(itemID: itemID, personID: $0.id, personName: $0.name)
                        }
                    }
                }
                for await result in group {
                    entries.append(contentsOf: result)
                }
            }
            guard !entries.isEmpty else { continue }
            let batch = entries
            try? await AppDatabase.shared.dbQueue.write { db in
                for entry in batch {
                    try entry.save(db)
                }
            }
        }
        await MainActor.run { SyncStatus.shared.generation += 1 }
    }

    // MARK: Localized metadata (title, overview, poster)

    private func enrichLocalizedMetadata(key: String, lang: String) async {
        let tmdbLang = lang == "es" ? "es-ES" : "en-US"
        let pending = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem
                .filter(Column("tmdbID") != nil && (Column("metaLang") == nil || Column("metaLang") != lang))
                .fetchAll(db)
        }) ?? []
        guard !pending.isEmpty else { return }

        for chunk in pending.chunked(into: 10) {
            var updates: [(String, String?, String?, String?, String?, String?)] = []
            await withTaskGroup(of: (String, String?, String?, String?, String?, String?)?.self) { group in
                for item in chunk {
                    guard let tmdbID = item.tmdbID else { continue }
                    let isShow = item.type == "show"
                    let itemID = item.id
                    group.addTask {
                        guard let details = await Self.fetchDetails(tmdbID: tmdbID, isShow: isShow, key: key, lang: tmdbLang) else {
                            return (itemID, nil, nil, nil, nil, nil) // still mark metaLang so we don't retry in a loop
                        }
                        return (itemID, details.title, details.overview, details.posterPath, details.originalLanguage, details.originCountry)
                    }
                }
                for await result in group {
                    if let result { updates.append(result) }
                }
            }
            guard !updates.isEmpty else { continue }
            let batch = updates
            try? await AppDatabase.shared.dbQueue.write { db in
                for update in batch {
                    try db.execute(
                        sql: "UPDATE mediaItem SET tmdbTitle = ?, tmdbSummary = ?, tmdbPosterPath = ?, metaLang = ?, originalLanguage = ?, originCountry = ? WHERE id = ?",
                        arguments: [update.1, update.2, update.3, lang, update.4, update.5, update.0]
                    )
                }
            }
            await MainActor.run { SyncStatus.shared.generation += 1 }
        }
    }

    private struct Details {
        let title: String?
        let overview: String?
        let posterPath: String?
        let originalLanguage: String?
        let originCountry: String?
    }

    private static func fetchDetails(tmdbID: Int, isShow: Bool, key: String, lang: String) async -> Details? {
        struct Response: Decodable {
            let title: String?
            let name: String?
            let overview: String?
            let poster_path: String?
            let original_language: String?
            let origin_country: [String]?
        }
        let kind = isShow ? "tv" : "movie"
        guard let data = await tmdbGET(path: "/3/\(kind)/\(tmdbID)", key: key, query: [URLQueryItem(name: "language", value: lang)]),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let title = resp.title ?? resp.name
        let overview = (resp.overview?.isEmpty ?? true) ? nil : resp.overview
        return Details(
            title: (title?.isEmpty ?? true) ? nil : title,
            overview: overview,
            posterPath: resp.poster_path,
            originalLanguage: resp.original_language,
            originCountry: resp.origin_country?.joined(separator: ",")
        )
    }

    // MARK: Logos

    private func enrichLogos(key: String, lang: String) async {
        let pending = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem
                .filter(Column("tmdbID") != nil && Column("logoURL") == nil)
                .fetchAll(db)
        }) ?? []
        guard !pending.isEmpty else { return }

        for chunk in pending.chunked(into: 10) {
            var updates: [(id: String, logo: String)] = []
            await withTaskGroup(of: (String, String)?.self) { group in
                for item in chunk {
                    guard let tmdbID = item.tmdbID else { continue }
                    let isShow = item.type == "show"
                    let itemID = item.id
                    group.addTask {
                        guard let logo = await Self.fetchLogoURL(tmdbID: tmdbID, isShow: isShow, key: key, lang: lang) else { return nil }
                        return (itemID, logo)
                    }
                }
                for await result in group {
                    if let result { updates.append((result.0, result.1)) }
                }
            }
            guard !updates.isEmpty else { continue }
            let batch = updates
            try? await AppDatabase.shared.dbQueue.write { db in
                for update in batch {
                    try db.execute(
                        sql: "UPDATE mediaItem SET logoURL = ? WHERE id = ?",
                        arguments: [update.logo, update.id]
                    )
                }
            }
            await MainActor.run { SyncStatus.shared.generation += 1 }
        }
    }

    private static func fetchLogoURL(tmdbID: Int, isShow: Bool, key: String, lang: String) async -> String? {
        struct ImagesResponse: Decodable {
            struct Img: Decodable {
                let file_path: String
                let iso_639_1: String?
            }
            let logos: [Img]?
        }
        let kind = isShow ? "tv" : "movie"
        let fallback = lang == "es" ? "en" : "es"
        guard let data = await tmdbGET(
            path: "/3/\(kind)/\(tmdbID)/images",
            key: key,
            query: [URLQueryItem(name: "include_image_language", value: "\(lang),\(fallback),null")]
        ),
              let images = try? JSONDecoder().decode(ImagesResponse.self, from: data),
              let logos = images.logos, !logos.isEmpty else { return nil }
        let pick = logos.first { $0.iso_639_1 == lang }
            ?? logos.first { $0.iso_639_1 == fallback }
            ?? logos[0]
        return "https://image.tmdb.org/t/p/w500" + pick.file_path
    }

    // MARK: HTTP

    private static func tmdbGET(path: String, key: String, query: [URLQueryItem]) async -> Data? {
        var comps = URLComponents(string: "https://api.themoviedb.org" + path)!
        var items = query
        var req: URLRequest
        if key.hasPrefix("eyJ") {
            comps.queryItems = items
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
        return data
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
