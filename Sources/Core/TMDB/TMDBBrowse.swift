import Foundation

/// Item from TMDB's virtual catalog (does not live in the local DB).
struct DiscoverItem: Identifiable, Sendable, Hashable, Codable {
    let tmdbID: Int
    let isShow: Bool
    let title: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let year: Int?
    let rating: Double?
    var releaseDate: String?   // "yyyy-MM-dd" (lexicographic order = chronological)
    var inTheaters: Bool = false   // informational: in theaters, not playable yet
    var id: String { "\(isShow ? "tv" : "movie")-\(tmdbID)" }

    /// Already released? (no date = assumed available to avoid over-filtering)
    func isReleased(today: String) -> Bool {
        guard let d = releaseDate, !d.isEmpty else { return true }
        return d <= today
    }

    var posterURL: URL? {
        posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) }
    }
    var backdropURL: URL? {
        backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280" + $0) }
    }
    var mergeKey: String { "tmdb:\(isShow ? "show" : "movie"):\(tmdbID)" }
}

struct DiscoverRow: Identifiable, Codable {
    let id: String
    let title: String
    let items: [DiscoverItem]
}

/// Browsable category (genre) with a representative background image.
struct DiscoverCategory: Identifiable, Sendable, Hashable, Codable {
    let id: Int            // TMDB genre id
    let name: String
    let backdropPath: String?
    var backdropURL: URL? {
        backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w780" + $0) }
    }
}

enum TMDBBrowse {

    private struct ListResponse: Decodable {
        struct Item: Decodable {
            let id: Int
            let title: String?
            let name: String?
            let overview: String?
            let poster_path: String?
            let backdrop_path: String?
            let release_date: String?
            let first_air_date: String?
            let vote_average: Double?
        }
        let results: [Item]?
        let total_pages: Int?
    }

    private static func map(_ item: ListResponse.Item, isShow: Bool) -> DiscoverItem? {
        guard let title = item.title ?? item.name else { return nil }
        let dateStr = item.release_date ?? item.first_air_date
        let year = dateStr.flatMap { Int($0.prefix(4)) }
        return DiscoverItem(
            tmdbID: item.id,
            isShow: isShow,
            title: title,
            overview: item.overview ?? "",
            posterPath: item.poster_path,
            backdropPath: item.backdrop_path,
            year: year,
            rating: item.vote_average,
            releaseDate: dateStr
        )
    }

    /// Today's date in "yyyy-MM-dd" format.
    static var todayString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Date (yyyy-MM-dd) marking the end of the theatrical window. A movie
    /// released after this is likely still in theaters and not on streaming yet,
    /// so it's excluded from the trending / Top 10 rows (TMDB "trending" has no
    /// release-type filter, unlike the genre rows).
    static var theatricalWindowCutoff: String {
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(byAdding: .day, value: -45, to: Date()) ?? Date()
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func list(path: String, isShow: Bool, key: String, lang: String, pages: Int = 1) async -> [DiscoverItem] {
        let tmdbLang = lang == "es" ? "es-ES" : "en-US"
        var all: [DiscoverItem] = []
        for page in 1...max(1, pages) {
            guard let data = await TMDBClient.rawGET(path: path, key: key, query: [
                URLQueryItem(name: "language", value: tmdbLang),
                URLQueryItem(name: "page", value: String(page)),
            ]), let resp = try? JSONDecoder().decode(ListResponse.self, from: data) else { break }
            let mapped = (resp.results ?? []).compactMap { map($0, isShow: isShow) }
            if mapped.isEmpty { break }
            all += mapped
        }
        return all
    }

    /// TMDB genres (fixed ids) with localized names.
    private static let movieGenres: [(id: Int, en: String, es: String)] = [
        (28, "Action", "Acción"), (12, "Adventure", "Aventura"), (16, "Animation", "Animación"),
        (35, "Comedy", "Comedia"), (80, "Crime", "Crimen"), (18, "Drama", "Drama"),
        (10751, "Family", "Familia"), (14, "Fantasy", "Fantasía"), (27, "Horror", "Terror"),
        (9648, "Mystery", "Misterio"), (10749, "Romance", "Romance"), (878, "Science Fiction", "Ciencia ficción"),
        (53, "Thriller", "Suspenso"), (10752, "War", "Bélica"), (37, "Western", "Western"),
        (99, "Documentary", "Documental"),
    ]
    private static let tvGenres: [(id: Int, en: String, es: String)] = [
        (10759, "Action & Adventure", "Acción y aventura"), (16, "Animation", "Animación"),
        (35, "Comedy", "Comedia"), (80, "Crime", "Crimen"), (18, "Drama", "Drama"),
        (10765, "Sci-Fi & Fantasy", "Ciencia ficción y fantasía"), (9648, "Mystery", "Misterio"),
        (10762, "Kids", "Infantil"), (99, "Documentary", "Documental"),
    ]

    // MARK: Trailer (TMDB videos → YouTube)

    private struct VideosResponse: Decodable {
        struct Video: Decodable {
            let key: String
            let site: String
            let type: String
            let official: Bool?
        }
        let results: [Video]?
    }

    /// Best YouTube trailer key for a title, preferring the app language then en.
    /// Returns nil if TMDB has no YouTube video. nonisolated — off-main work.
    nonisolated static func trailerKey(tmdbID: Int, isShow: Bool, key: String) async -> String? {
        let path = (isShow ? "/3/tv/" : "/3/movie/") + "\(tmdbID)/videos"
        let localized = L10n.effectiveLanguage() == "es" ? "es-ES" : "en-US"
        for lang in [localized, "en-US"] {
            let query = [URLQueryItem(name: "language", value: lang)]
            guard let data = await TMDBClient.rawGET(path: path, key: key, query: query),
                  let resp = try? JSONDecoder().decode(VideosResponse.self, from: data) else {
                if lang == "en-US" { break }
                continue
            }
            let youtube = (resp.results ?? []).filter { $0.site.lowercased() == "youtube" && !$0.key.isEmpty }
            if let best = bestTrailer(youtube) { return best.key }
            if lang == "en-US" { break }
        }
        return nil
    }

    /// Ranks: official trailer > trailer > official teaser > teaser > clip > other.
    private static func bestTrailer(_ videos: [VideosResponse.Video]) -> VideosResponse.Video? {
        func rank(_ v: VideosResponse.Video) -> Int {
            switch v.type.lowercased() {
            case "trailer": return v.official == true ? 0 : 1
            case "teaser":  return v.official == true ? 2 : 3
            case "clip":    return 4
            default:        return 5
            }
        }
        return videos.min { rank($0) < rank($1) }
    }

    private static func discoverByGenre(genreID: Int, isShow: Bool, key: String, lang: String) async -> [DiscoverItem] {
        let path = isShow ? "/3/discover/tv" : "/3/discover/movie"
        let tmdbLang = lang == "es" ? "es-ES" : "en-US"
        // Request only already-released content directly from TMDB.
        var query = [
            URLQueryItem(name: "language", value: tmdbLang),
            URLQueryItem(name: "with_genres", value: String(genreID)),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "vote_count.gte", value: isShow ? "100" : "200"),
        ]
        if isShow {
            query.append(URLQueryItem(name: "first_air_date.lte", value: todayString))
        } else {
            query.append(URLQueryItem(name: "release_date.lte", value: todayString))
            query.append(URLQueryItem(name: "with_release_type", value: "4|5")) // 4=digital, 5=physical
        }
        guard let data = await TMDBClient.rawGET(path: path, key: key, query: query),
              let resp = try? JSONDecoder().decode(ListResponse.self, from: data) else { return [] }
        return (resp.results ?? []).compactMap { map($0, isShow: isShow) }
    }

    /// Categories (movie genres) with a representative backdrop for the carousel.
    @MainActor
    static func movieCategories() async -> [DiscoverCategory] {
        guard let key = SettingsStore.shared.tmdbKey else { return [] }
        let lang = L10nStore.shared.effective
        let isES = lang == "es"
        // Each genre brings several backdrop candidates; we then assign a UNIQUE one
        // per category so background images don't repeat.
        let raw = await withTaskGroup(of: (offset: Int, id: Int, name: String, backdrops: [String]).self) { group -> [(offset: Int, id: Int, name: String, backdrops: [String])] in
            for (offset, genre) in movieGenres.enumerated() where genre.id != 99 {  // documentary has its own tab
                group.addTask {
                    let items = await discoverByGenre(genreID: genre.id, isShow: false, key: key, lang: lang)
                    let backdrops = items.compactMap(\.backdropPath)
                    return (offset, genre.id, isES ? genre.es : genre.en, backdrops)
                }
            }
            var collected: [(offset: Int, id: Int, name: String, backdrops: [String])] = []
            for await entry in group { collected.append(entry) }
            return collected.sorted { $0.offset < $1.offset }
        }

        var used = Set<String>()
        var result: [DiscoverCategory] = []
        for entry in raw {
            guard let pick = entry.backdrops.first(where: { !used.contains($0) }) ?? entry.backdrops.first else { continue }
            used.insert(pick)
            result.append(DiscoverCategory(id: entry.id, name: entry.name, backdropPath: pick))
        }
        return result
    }

    /// Full discovery board: trending + genre categories, all from TMDB.
    /// Only already-available content; what's in theaters goes in its own informational row.
    @MainActor
    static func discoverRows() async -> [DiscoverRow] {
        guard let key = SettingsStore.shared.tmdbKey else { return [] }
        let lang = L10nStore.shared.effective
        let today = todayString

        // In theaters (informational): excluded from the rest of the board.
        let nowPlayingRaw = await list(path: "/3/movie/now_playing", isShow: false, key: key, lang: lang)
        let inTheaters = nowPlayingRaw.map { item -> DiscoverItem in
            var copy = item; copy.inTheaters = true; return copy
        }
        let theaterIDs = Set(inTheaters.map(\.tmdbID))

        // Filter: already released and not in theaters.
        func clean(_ items: [DiscoverItem]) -> [DiscoverItem] {
            items.filter { $0.isReleased(today: today) && !theaterIDs.contains($0.tmdbID) }
        }

        // Two pages: after dropping in-theater / recent-release titles there are
        // still enough trending movies to fill the Top 10 plus the trending row.
        async let trendingMovies = list(path: "/3/trending/movie/week", isShow: false, key: key, lang: lang, pages: 2)
        async let trendingShows = list(path: "/3/trending/tv/week", isShow: true, key: key, lang: lang)
        async let popularShows = list(path: "/3/tv/popular", isShow: true, key: key, lang: lang)
        async let topMovies = list(path: "/3/movie/top_rated", isShow: false, key: key, lang: lang)

        // Upcoming releases (informational): not yet released, sorted by nearest date.
        let upcomingRaw = await list(path: "/3/movie/upcoming", isShow: false, key: key, lang: lang)
        let upcoming = upcomingRaw
            .filter { !$0.isReleased(today: today) && !theaterIDs.contains($0.tmdbID) }
            .map { item -> DiscoverItem in var c = item; c.inTheaters = true; return c }  // informational, not playable
            .sorted { ($0.releaseDate ?? "") < ($1.releaseDate ?? "") }

        var rows: [DiscoverRow] = []
        // Trending movies: also drop titles still in their theatrical window
        // (recently released, likely in theaters and not streamable yet) so the
        // Top 10 and trending rows only show watchable films.
        let theaterCutoff = theatricalWindowCutoff
        let tm = clean(await trendingMovies).filter { ($0.releaseDate ?? "") <= theaterCutoff }
        // Top 10: the first ten trending titles get the giant-numeral row;
        // the big-card trending row continues with the rest.
        if !tm.isEmpty { rows.append(DiscoverRow(id: "top10", title: tr(L.top10Title), items: Array(tm.prefix(10)))) }
        let tmRest = Array(tm.dropFirst(10))
        if !tmRest.isEmpty { rows.append(DiscoverRow(id: "tmovies", title: tr(L.trendingMovies), items: tmRest)) }
        let ts = clean(await trendingShows)
        if !ts.isEmpty { rows.append(DiscoverRow(id: "tshows", title: tr(L.trendingShows), items: ts)) }
        let ps = clean(await popularShows)
        if !ps.isEmpty { rows.append(DiscoverRow(id: "pshows", title: tr(L.popularShows), items: ps)) }
        let topm = clean(await topMovies)
        if !topm.isEmpty { rows.append(DiscoverRow(id: "topmovies", title: tr(L.topRatedMovies), items: topm)) }

        // In theaters / upcoming: informational, right before the genre rows.
        if !inTheaters.isEmpty {
            rows.append(DiscoverRow(id: "intheaters", title: tr(L.inTheaters), items: inTheaters))
        }
        if !upcoming.isEmpty {
            rows.append(DiscoverRow(id: "upcoming", title: tr(L.upcoming), items: upcoming))
        }

        // Genre rows were intentionally removed — the category cards below the
        // hero already let the user filter by genre in a dedicated view, so the
        // long list of "Action / Thriller / …" rows here was redundant.
        return rows
    }

    /// Release dates for a movie: theatrical (type 3) and digital (type 4).
    static func releaseDates(movieID: Int, key: String) async -> (theatrical: String?, digital: String?) {
        struct Response: Decodable {
            struct Result: Decodable {
                struct RD: Decodable { let type: Int?; let release_date: String? }
                let iso_3166_1: String?
                let release_dates: [RD]?
            }
            let results: [Result]?
        }
        guard let data = await TMDBClient.rawGET(path: "/3/movie/\(movieID)/release_dates", key: key, query: []),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return (nil, nil) }
        // Prefer US; otherwise the first entry that has each type.
        let all = resp.results ?? []
        let preferred = all.first { $0.iso_3166_1 == "US" }?.release_dates ?? []
        let pool = preferred.isEmpty ? all.flatMap { $0.release_dates ?? [] } : preferred
        let theatrical = pool.first { $0.type == 3 }?.release_date ?? pool.first { $0.type == 2 }?.release_date
        let digital = pool.first { $0.type == 4 }?.release_date
        return (theatrical.map { String($0.prefix(10)) }, digital.map { String($0.prefix(10)) })
    }

    /// Multi search (movies + shows).
    @MainActor
    static func search(_ query: String) async -> [DiscoverItem] {
        guard let key = SettingsStore.shared.tmdbKey,
              query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let lang = L10nStore.shared.effective == "es" ? "es-ES" : "en-US"
        guard let data = await TMDBClient.rawGET(path: "/3/search/multi", key: key, query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: lang),
        ]) else { return [] }
        struct MultiResponse: Decodable {
            struct Item: Decodable {
                let id: Int
                let media_type: String?
                let title: String?
                let name: String?
                let overview: String?
                let poster_path: String?
                let backdrop_path: String?
                let release_date: String?
                let first_air_date: String?
                let vote_average: Double?
            }
            let results: [Item]?
        }
        guard let resp = try? JSONDecoder().decode(MultiResponse.self, from: data) else { return [] }
        return (resp.results ?? []).compactMap { item in
            guard item.media_type == "movie" || item.media_type == "tv" else { return nil }
            let isShow = item.media_type == "tv"
            guard let title = item.title ?? item.name else { return nil }
            let dateStr = item.release_date ?? item.first_air_date
            return DiscoverItem(
                tmdbID: item.id,
                isShow: isShow,
                title: title,
                overview: item.overview ?? "",
                posterPath: item.poster_path,
                backdropPath: item.backdrop_path,
                year: dateStr.flatMap { Int($0.prefix(4)) },
                rating: item.vote_average
            )
        }
    }

    // MARK: - Seasons and episodes (shows)

    struct DiscoverSeason: Identifiable, Sendable, Hashable {
        let seasonNumber: Int
        let name: String
        let episodeCount: Int
        let posterPath: String?
        var id: Int { seasonNumber }
        var posterURL: URL? {
            posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w300" + $0) }
        }
    }

    struct DiscoverEpisode: Identifiable, Sendable, Hashable {
        let seasonNumber: Int
        let episodeNumber: Int
        let name: String
        let overview: String
        let stillPath: String?
        let airDate: String?
        let runtime: Int?
        var id: String { "s\(seasonNumber)e\(episodeNumber)" }
        /// Code like "S01E02" used to build the search query for torrent indexers.
        var code: String { String(format: "S%02dE%02d", seasonNumber, episodeNumber) }
        var stillURL: URL? {
            stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) }
        }
        var aired: Bool {
            guard let airDate, !airDate.isEmpty else { return true }
            return airDate <= TMDBBrowse.todayString
        }
    }

    /// Seasons of a show (excludes "Specials" = season 0 without real episodes).
    @MainActor
    static func seasons(showID: Int, key: String) async -> [DiscoverSeason] {
        struct Response: Decodable {
            struct S: Decodable {
                let season_number: Int?
                let name: String?
                let episode_count: Int?
                let poster_path: String?
            }
            let seasons: [S]?
        }
        let lang = L10nStore.shared.effective == "es" ? "es-ES" : "en-US"
        guard let data = await TMDBClient.rawGET(path: "/3/tv/\(showID)", key: key, query: [
            URLQueryItem(name: "language", value: lang),
        ]), let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (resp.seasons ?? []).compactMap { s in
            guard let n = s.season_number, (s.episode_count ?? 0) > 0 else { return nil }
            return DiscoverSeason(
                seasonNumber: n,
                name: s.name ?? "T\(n)",
                episodeCount: s.episode_count ?? 0,
                posterPath: s.poster_path
            )
        }.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    /// Episodes of a season.
    @MainActor
    static func episodes(showID: Int, season: Int, key: String) async -> [DiscoverEpisode] {
        struct Response: Decodable {
            struct E: Decodable {
                let episode_number: Int?
                let name: String?
                let overview: String?
                let still_path: String?
                let air_date: String?
                let runtime: Int?
            }
            let episodes: [E]?
        }
        let lang = L10nStore.shared.effective == "es" ? "es-ES" : "en-US"
        guard let data = await TMDBClient.rawGET(path: "/3/tv/\(showID)/season/\(season)", key: key, query: [
            URLQueryItem(name: "language", value: lang),
        ]), let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return (resp.episodes ?? []).compactMap { e in
            guard let n = e.episode_number else { return nil }
            return DiscoverEpisode(
                seasonNumber: season,
                episodeNumber: n,
                name: e.name ?? "Episodio \(n)",
                overview: e.overview ?? "",
                stillPath: e.still_path,
                airDate: e.air_date,
                runtime: e.runtime
            )
        }.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    /// Extra details to materialize a TMDB item into a full MediaItem.
    struct Details: Sendable {
        var genres: String          // names separated by "|"
        var runtimeMs: Int?
        var originalLanguage: String?
        var originCountry: String?
        var logoURL: String?
    }

    /// Latest aired episode of a show + basic show data, for "new episodes" detection.
    struct ShowAirStatus: Sendable {
        let lastSeason: Int
        let lastEpisode: Int
        let lastAirDate: String        // "yyyy-MM-dd"
        let item: DiscoverItem         // for virtual mapping when there's no local copy
    }

    static func showAirStatus(tmdbID: Int, key: String) async -> ShowAirStatus? {
        let lang = L10n.effectiveLanguage() == "es" ? "es-ES" : "en-US"
        struct Resp: Decodable {
            struct Ep: Decodable { let season_number: Int?; let episode_number: Int?; let air_date: String? }
            let name: String?
            let overview: String?
            let poster_path: String?
            let backdrop_path: String?
            let first_air_date: String?
            let vote_average: Double?
            let last_episode_to_air: Ep?
        }
        guard let data = await TMDBClient.rawGET(path: "/3/tv/\(tmdbID)", key: key, query: [
            URLQueryItem(name: "language", value: lang),
        ]), let resp = try? JSONDecoder().decode(Resp.self, from: data),
              let ep = resp.last_episode_to_air,
              let season = ep.season_number, let number = ep.episode_number,
              let air = ep.air_date, !air.isEmpty else { return nil }
        let item = DiscoverItem(
            tmdbID: tmdbID, isShow: true, title: resp.name ?? "",
            overview: resp.overview ?? "",
            posterPath: resp.poster_path, backdropPath: resp.backdrop_path,
            year: (resp.first_air_date?.prefix(4)).flatMap { Int($0) },
            rating: resp.vote_average,
            releaseDate: resp.first_air_date
        )
        return ShowAirStatus(lastSeason: season, lastEpisode: number, lastAirDate: air, item: item)
    }

    /// The collection ("saga") a movie belongs to, with all its parts in
    /// chronological order — e.g. the full "John Wick Collection".
    static func collection(forMovie tmdbID: Int, key: String) async -> (name: String, items: [DiscoverItem])? {
        let lang = L10n.effectiveLanguage() == "es" ? "es-ES" : "en-US"
        struct MovieResp: Decodable {
            struct Coll: Decodable { let id: Int?; let name: String? }
            let belongs_to_collection: Coll?
        }
        guard let data = await TMDBClient.rawGET(path: "/3/movie/\(tmdbID)", key: key, query: [
            URLQueryItem(name: "language", value: lang),
        ]), let movie = try? JSONDecoder().decode(MovieResp.self, from: data),
              let collID = movie.belongs_to_collection?.id else { return nil }

        struct CollResp: Decodable {
            struct Part: Decodable {
                let id: Int?
                let title: String?
                let overview: String?
                let poster_path: String?
                let backdrop_path: String?
                let release_date: String?
                let vote_average: Double?
            }
            let name: String?
            let parts: [Part]?
        }
        guard let collData = await TMDBClient.rawGET(path: "/3/collection/\(collID)", key: key, query: [
            URLQueryItem(name: "language", value: lang),
        ]), let coll = try? JSONDecoder().decode(CollResp.self, from: collData) else { return nil }

        let items = (coll.parts ?? [])
            .compactMap { p -> DiscoverItem? in
                guard let id = p.id, let title = p.title, !title.isEmpty else { return nil }
                return DiscoverItem(
                    tmdbID: id, isShow: false, title: title,
                    overview: p.overview ?? "",
                    posterPath: p.poster_path, backdropPath: p.backdrop_path,
                    year: (p.release_date?.prefix(4)).flatMap { Int($0) },
                    rating: p.vote_average,
                    releaseDate: p.release_date
                )
            }
            // Chronological; unreleased parts (no date) go last.
            .sorted { ($0.releaseDate?.isEmpty == false ? $0.releaseDate! : "9999") < ($1.releaseDate?.isEmpty == false ? $1.releaseDate! : "9999") }
        guard items.count > 1 else { return nil }   // a "saga" of one is noise
        return (coll.name ?? movie.belongs_to_collection?.name ?? "", items)
    }

    @MainActor
    static func details(tmdbID: Int, isShow: Bool, key: String) async -> Details {
        let lang = L10nStore.shared.effective == "es" ? "es-ES" : "en-US"
        struct Response: Decodable {
            struct Genre: Decodable { let name: String? }
            struct Episode: Decodable { let runtime: Int? }
            struct ImagesBox: Decodable { struct Logo: Decodable { let file_path: String?; let iso_639_1: String? }; let logos: [Logo]? }
            let genres: [Genre]?
            let runtime: Int?                       // movie (min)
            let episode_run_time: [Int]?            // show (min)
            let original_language: String?
            let origin_country: [String]?
            let images: ImagesBox?
        }
        let path = isShow ? "/3/tv/\(tmdbID)" : "/3/movie/\(tmdbID)"
        guard let data = await TMDBClient.rawGET(path: path, key: key, query: [
            URLQueryItem(name: "language", value: lang),
            URLQueryItem(name: "append_to_response", value: "images"),
            URLQueryItem(name: "include_image_language", value: "en,es,null"),
        ]), let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            return Details(genres: "", runtimeMs: nil, originalLanguage: nil, originCountry: nil, logoURL: nil)
        }
        let genres = (resp.genres ?? []).compactMap(\.name).joined(separator: "|")
        let runtimeMin = resp.runtime ?? resp.episode_run_time?.first
        // Transparent PNG logo: prefer es/en.
        let logo = resp.images?.logos?.first { $0.iso_639_1 == (L10nStore.shared.effective == "es" ? "es" : "en") }
            ?? resp.images?.logos?.first { $0.iso_639_1 == "en" }
            ?? resp.images?.logos?.first
        let logoURL = logo?.file_path.map { "https://image.tmdb.org/t/p/w500" + $0 }
        return Details(
            genres: genres,
            runtimeMs: runtimeMin.map { $0 * 60_000 },
            originalLanguage: resp.original_language,
            originCountry: resp.origin_country?.joined(separator: ","),
            logoURL: logoURL
        )
    }

    /// Builds a DiscoverItem (title/poster/overview…) from a TMDB id — used to
    /// turn external rankings (e.g. Trakt trending) into browsable cards.
    static func discoverItem(tmdbID: Int, isShow: Bool, key: String) async -> DiscoverItem? {
        let lang = L10n.effectiveLanguage() == "es" ? "es-ES" : "en-US"
        struct R: Decodable {
            let title: String?; let name: String?
            let overview: String?
            let poster_path: String?; let backdrop_path: String?
            let release_date: String?; let first_air_date: String?
            let vote_average: Double?
        }
        let path = isShow ? "/3/tv/\(tmdbID)" : "/3/movie/\(tmdbID)"
        guard let data = await TMDBClient.rawGET(path: path, key: key, query: [
            URLQueryItem(name: "language", value: lang),
        ]), let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        let title = r.title ?? r.name ?? ""
        guard !title.isEmpty, r.poster_path != nil else { return nil }
        let date = r.release_date ?? r.first_air_date
        return DiscoverItem(
            tmdbID: tmdbID, isShow: isShow, title: title, overview: r.overview ?? "",
            posterPath: r.poster_path, backdropPath: r.backdrop_path,
            year: date.flatMap { Int($0.prefix(4)) }, rating: r.vote_average, releaseDate: date
        )
    }

    /// Age classification (PG / content rating). Prefers US, then the first available.
    static func certification(tmdbID: Int, isShow: Bool, key: String) async -> String? {
        if isShow {
            struct Response: Decodable {
                struct R: Decodable { let iso_3166_1: String?; let rating: String? }
                let results: [R]?
            }
            guard let data = await TMDBClient.rawGET(path: "/3/tv/\(tmdbID)/content_ratings", key: key, query: []),
                  let resp = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
            let all = resp.results ?? []
            let pick = all.first { $0.iso_3166_1 == "US" }?.rating
                ?? all.first { !($0.rating ?? "").isEmpty }?.rating
            return pick.flatMap { $0.isEmpty ? nil : $0 }
        } else {
            struct Response: Decodable {
                struct Result: Decodable {
                    struct RD: Decodable { let certification: String? }
                    let iso_3166_1: String?
                    let release_dates: [RD]?
                }
                let results: [Result]?
            }
            guard let data = await TMDBClient.rawGET(path: "/3/movie/\(tmdbID)/release_dates", key: key, query: []),
                  let resp = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
            let all = resp.results ?? []
            func cert(_ r: Response.Result?) -> String? {
                r?.release_dates?.first { !($0.certification ?? "").isEmpty }?.certification
            }
            let pick = cert(all.first { $0.iso_3166_1 == "US" })
                ?? all.lazy.compactMap { cert($0) }.first
            return pick.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    // MARK: - Catalog browsing with filters (tabs)

    enum CatalogSort: String, CaseIterable, Sendable {
        case recent, popular, rating, oldest
    }

    struct CatalogFilters: Equatable, Sendable {
        var genreID: Int? = nil
        var year: Int? = nil
        var minRating: Double? = nil   // vote_average >=
        var sort: CatalogSort = .recent
    }

    /// Is this tab served from the TV endpoint?
    static func isTVCatalog(_ kind: CatalogKind) -> Bool {
        switch kind {
        case .movie, .documentary: false
        case .series, .anime, .dorama: true
        }
    }

    /// Genre options for the filter, depending on the tab.
    @MainActor
    static func genreOptions(kind: CatalogKind) -> [(id: Int, name: String)] {
        let isES = L10nStore.shared.effective == "es"
        let table = isTVCatalog(kind) ? tvGenres : movieGenres
        return table.map { (id: $0.id, name: isES ? $0.es : $0.en) }
    }

    /// TMDB catalog page for a tab, with filters. Returns items and total page count.
    @MainActor
    static func discover(kind: CatalogKind, filters: CatalogFilters, page: Int) async -> (items: [DiscoverItem], totalPages: Int) {
        guard let key = SettingsStore.shared.tmdbKey else { return ([], 0) }
        let isTV = isTVCatalog(kind)
        let path = isTV ? "/3/discover/tv" : "/3/discover/movie"
        let lang = L10nStore.shared.effective == "es" ? "es-ES" : "en-US"
        let today = todayString

        // Sort order.
        let sortBy: String
        switch filters.sort {
        case .recent: sortBy = isTV ? "first_air_date.desc" : "primary_release_date.desc"
        case .oldest: sortBy = isTV ? "first_air_date.asc" : "primary_release_date.asc"
        case .popular: sortBy = "popularity.desc"
        case .rating: sortBy = "vote_average.desc"
        }

        var q: [URLQueryItem] = [
            URLQueryItem(name: "language", value: lang),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        // Avoid noise: minimum vote count (stricter when sorting by rating).
        q.append(URLQueryItem(name: "vote_count.gte", value: filters.sort == .rating ? "150" : "20"))

        // Genres: tab base + user filter (AND).
        var genres: [Int] = []
        switch kind {
        case .anime: genres.append(16)            // Animation
        case .documentary: genres.append(99)      // Documentary
        default: break
        }
        if let g = filters.genreID { genres.append(g) }
        if !genres.isEmpty {
            q.append(URLQueryItem(name: "with_genres", value: genres.map(String.init).joined(separator: ",")))
        }

        // Per-tab rules (language/origin) so each tab stays coherent.
        switch kind {
        case .anime:
            q.append(URLQueryItem(name: "with_original_language", value: "ja"))
        case .dorama:
            q.append(URLQueryItem(name: "with_origin_country", value: "KR|CN|TW|HK|TH"))
            q.append(URLQueryItem(name: "without_genres", value: "16"))   // excludes anime
        case .series:
            q.append(URLQueryItem(name: "without_genres", value: "16"))   // anime has its own tab
        default: break
        }

        // Year.
        if let year = filters.year {
            q.append(URLQueryItem(name: isTV ? "first_air_date_year" : "primary_release_year", value: String(year)))
        } else {
            // No year selected: don't show unreleased content.
            q.append(URLQueryItem(name: isTV ? "first_air_date.lte" : "primary_release_date.lte", value: today))
        }
        if let minRating = filters.minRating {
            q.append(URLQueryItem(name: "vote_average.gte", value: String(minRating)))
        }

        guard let data = await TMDBClient.rawGET(path: path, key: key, query: q),
              let resp = try? JSONDecoder().decode(ListResponse.self, from: data) else { return ([], 0) }
        let items = (resp.results ?? []).compactMap { map($0, isShow: isTV) }
        return (items, min(resp.total_pages ?? 1, 500))   // TMDB caps at 500 pages
    }

    /// Full filmography of a person from TMDB (everything available, not just
    /// the local library). Sorted by popularity and deduplicated.
    @MainActor
    static func personFilmography(personID: Int, key: String) async -> [DiscoverItem] {
        struct Response: Decodable {
            struct Credit: Decodable {
                let id: Int
                let media_type: String?
                let title: String?
                let name: String?
                let overview: String?
                let poster_path: String?
                let backdrop_path: String?
                let release_date: String?
                let first_air_date: String?
                let vote_average: Double?
                let popularity: Double?
            }
            let cast: [Credit]?
        }
        let lang = L10nStore.shared.effective == "es" ? "es-ES" : "en-US"
        guard let data = await TMDBClient.rawGET(path: "/3/person/\(personID)/combined_credits", key: key, query: [
            URLQueryItem(name: "language", value: lang),
        ]), let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }

        var seen = Set<String>()
        return (resp.cast ?? [])
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .compactMap { c -> DiscoverItem? in
                guard c.media_type == "movie" || c.media_type == "tv",
                      let title = c.title ?? c.name, c.poster_path != nil else { return nil }
                let isShow = c.media_type == "tv"
                guard seen.insert("\(isShow ? "tv" : "movie")-\(c.id)").inserted else { return nil }
                let dateStr = c.release_date ?? c.first_air_date
                return DiscoverItem(
                    tmdbID: c.id, isShow: isShow, title: title, overview: c.overview ?? "",
                    posterPath: c.poster_path, backdropPath: c.backdrop_path,
                    year: dateStr.flatMap { Int($0.prefix(4)) }, rating: c.vote_average
                )
            }
    }

    /// TMDB recommendations for a title (similar items from the virtual catalog).
    @MainActor
    static func recommendations(tmdbID: Int, isShow: Bool, key: String) async -> [DiscoverItem] {
        let lang = L10nStore.shared.effective
        let path = isShow ? "/3/tv/\(tmdbID)/recommendations" : "/3/movie/\(tmdbID)/recommendations"
        return await list(path: path, isShow: isShow, key: key, lang: lang)
    }

    /// IMDb id of a title (refines the Prowlarr search).
    static func imdbID(tmdbID: Int, isShow: Bool, key: String) async -> String? {
        struct IDs: Decodable { let imdb_id: String? }
        let path = isShow ? "/3/tv/\(tmdbID)/external_ids" : "/3/movie/\(tmdbID)/external_ids"
        guard let data = await TMDBClient.rawGET(path: path, key: key, query: []),
              let ids = try? JSONDecoder().decode(IDs.self, from: data) else { return nil }
        return ids.imdb_id
    }
}
