import Foundation

/// High-level Trakt service. Self-contained social module — the rest of the app
/// only talks to this. Reads are public (Client ID only); writes require a
/// per-user OAuth token (see `TraktAuth`, wired in phase 2).
enum TraktClient {

    // MARK: - Slug / id resolution (tmdb → trakt, cached)

    static func slug(_ ref: TraktRef, clientID: String) async -> String? {
        let type = ref.isShow ? "show" : "movie"
        let cacheKey = "traktSlug-\(type)-\(ref.tmdbID)"
        if let cached = UserDefaults.standard.string(forKey: cacheKey) { return cached }
        struct Ids: Decodable { let slug: String? }
        struct Node: Decodable { let ids: Ids }
        struct Row: Decodable { let movie: Node?; let show: Node? }
        guard let rows = await TraktHTTP.get("/search/tmdb/\(ref.tmdbID)?type=\(type)",
                                             as: [Row].self, clientID: clientID) else { return nil }
        let found = ref.isShow ? rows.first?.show?.ids.slug : rows.first?.movie?.ids.slug
        if let found { UserDefaults.standard.set(found, forKey: cacheKey) }
        return found
    }

    /// The episode's Trakt id (needed to comment/scrobble on an episode), cached.
    private static func episodeTraktID(_ ref: TraktRef, slug: String, clientID: String) async -> Int? {
        guard let s = ref.season, let e = ref.episode else { return nil }
        let cacheKey = "traktEp-\(slug)-\(s)-\(e)"
        let cached = UserDefaults.standard.integer(forKey: cacheKey)
        if cached > 0 { return cached }
        struct Ids: Decodable { let trakt: Int? }
        struct Ep: Decodable { let ids: Ids }
        let ep = await TraktHTTP.get("/shows/\(slug)/seasons/\(s)/episodes/\(e)",
                                     as: Ep.self, clientID: clientID)
        if let id = ep?.ids.trakt, id > 0 { UserDefaults.standard.set(id, forKey: cacheKey) }
        return ep?.ids.trakt
    }

    private static func basePath(_ ref: TraktRef, slug: String) -> String {
        if ref.isShow, let s = ref.season, let e = ref.episode {
            return "/shows/\(slug)/seasons/\(s)/episodes/\(e)"
        }
        return ref.isShow ? "/shows/\(slug)" : "/movies/\(slug)"
    }

    // MARK: - READ (phase 1, public)

    /// Convenience entry used by the player (keeps a flat signature).
    static func load(tmdbID: Int, isShow: Bool, season: Int?, episode: Int?,
                     clientID: String, preferredLang: String) async -> TraktContent {
        await community(TraktRef(tmdbID: tmdbID, isShow: isShow, season: season, episode: episode),
                        clientID: clientID, preferredLang: preferredLang)
    }

    /// Aggregate rating + comments for a ref, user's language surfaced first.
    static func community(_ ref: TraktRef, clientID: String, preferredLang: String) async -> TraktContent {
        guard !clientID.isEmpty, let slug = await slug(ref, clientID: clientID) else { return .none }
        let path = basePath(ref, slug: slug)
        async let commentsResult = comments(path: path, clientID: clientID, preferredLang: preferredLang)
        async let ratingResult = rating(path: path, clientID: clientID)
        var (cs, r) = await (commentsResult, ratingResult)
        // Episode with no discussion → fall back to the show's comments/rating.
        if ref.isEpisode, cs.isEmpty {
            let showPath = "/shows/\(slug)"
            cs = await comments(path: showPath, clientID: clientID, preferredLang: preferredLang)
            if r == nil { r = await rating(path: showPath, clientID: clientID) }
        }
        return TraktContent(rating: r?.0, votes: r?.1 ?? 0, comments: cs)
    }

    private static func comments(path: String, clientID: String, preferredLang: String) async -> [TraktComment] {
        struct User: Decodable { let username: String?; let name: String? }
        struct Row: Decodable {
            let id: Int; let comment: String; let spoiler: Bool?; let review: Bool?
            let likes: Int?; let user_rating: Int?; let created_at: String?; let user: User?
        }
        guard let rows = await TraktHTTP.get("\(path)/comments/likes?limit=60",
                                             as: [Row].self, clientID: clientID) else { return [] }
        let parsed: [TraktComment] = rows.map { row in
            let text = row.comment
                .replacingOccurrences(of: "[spoiler]", with: "")
                .replacingOccurrences(of: "[/spoiler]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TraktComment(id: row.id, text: text, spoiler: row.spoiler ?? false,
                                isReview: row.review ?? false, likes: row.likes ?? 0,
                                userName: row.user?.username ?? row.user?.name ?? "—",
                                userRating: row.user_rating, createdAt: row.created_at,
                                lang: TraktComment.detectLanguage(text))
        }
        // User's language first, then most-liked. Nothing hidden.
        let pref = String(preferredLang.prefix(2)).lowercased()
        return parsed.sorted {
            let a = $0.lang.hasPrefix(pref), b = $1.lang.hasPrefix(pref)
            if a != b { return a }
            return $0.likes > $1.likes
        }
    }

    private static func rating(path: String, clientID: String) async -> (Double, Int)? {
        struct R: Decodable { let rating: Double?; let votes: Int? }
        guard let r = await TraktHTTP.get("\(path)/ratings", as: R.self, clientID: clientID),
              let rating = r.rating, rating > 0 else { return nil }
        return (rating, r.votes ?? 0)
    }

    /// Generic public discovery list (movies + shows interleaved) → content refs.
    private static func discoveryRefs(moviePath: String, showPath: String,
                                      clientID: String, limit: Int) async -> [TraktRef] {
        guard !clientID.isEmpty else { return [] }
        struct Ids: Decodable { let tmdb: Int? }
        struct Node: Decodable { let ids: Ids }
        struct Row: Decodable { let movie: Node?; let show: Node? }
        async let m = TraktHTTP.get("\(moviePath)?limit=\(limit)", as: [Row].self, clientID: clientID)
        async let s = TraktHTTP.get("\(showPath)?limit=\(limit)", as: [Row].self, clientID: clientID)
        let (movies, shows) = await (m, s)
        let mr = (movies ?? []).compactMap { $0.movie?.ids.tmdb }.map { TraktRef.movie($0) }
        let sr = (shows ?? []).compactMap { $0.show?.ids.tmdb }.map { TraktRef.show($0) }
        var out: [TraktRef] = []
        for i in 0..<max(mr.count, sr.count) {
            if i < mr.count { out.append(mr[i]) }
            if i < sr.count { out.append(sr[i]) }
        }
        return out
    }

    /// Community discovery (public, Client ID only). Enrich with TMDB for cards.
    static func trending(clientID: String, limit: Int = 16) async -> [TraktRef] {
        await discoveryRefs(moviePath: "/movies/trending", showPath: "/shows/trending",
                            clientID: clientID, limit: limit)
    }
    static func mostWatched(clientID: String, limit: Int = 16) async -> [TraktRef] {
        await discoveryRefs(moviePath: "/movies/watched/weekly", showPath: "/shows/watched/weekly",
                            clientID: clientID, limit: limit)
    }
    static func anticipated(clientID: String, limit: Int = 16) async -> [TraktRef] {
        await discoveryRefs(moviePath: "/movies/anticipated", showPath: "/shows/anticipated",
                            clientID: clientID, limit: limit)
    }

    /// "Related" — community-based similar titles to a movie/show.
    static func related(_ ref: TraktRef, clientID: String, limit: Int = 20) async -> [TraktRef] {
        guard !clientID.isEmpty, let slug = await slug(ref, clientID: clientID) else { return [] }
        let path = ref.isShow ? "/shows/\(slug)/related" : "/movies/\(slug)/related"
        struct Ids: Decodable { let tmdb: Int? }
        struct Row: Decodable { let ids: Ids }
        guard let rows = await TraktHTTP.get("\(path)?limit=\(limit)", as: [Row].self, clientID: clientID) else { return [] }
        let isShow = ref.isShow
        return rows.compactMap { $0.ids.tmdb.map { isShow ? .show($0) : .movie($0) } }
    }

    /// Replies of a comment (read, public).
    static func replies(commentID: Int, clientID: String) async -> [TraktComment] {
        struct User: Decodable { let username: String?; let name: String? }
        struct Row: Decodable {
            let id: Int; let comment: String; let spoiler: Bool?; let review: Bool?
            let likes: Int?; let user_rating: Int?; let created_at: String?; let user: User?
        }
        guard let rows = await TraktHTTP.get("/comments/\(commentID)/replies",
                                             as: [Row].self, clientID: clientID) else { return [] }
        return rows.map {
            TraktComment(id: $0.id, text: $0.comment, spoiler: $0.spoiler ?? false,
                         isReview: $0.review ?? false, likes: $0.likes ?? 0,
                         userName: $0.user?.username ?? "—", userRating: $0.user_rating,
                         createdAt: $0.created_at, lang: TraktComment.detectLanguage($0.comment))
        }
    }

    // MARK: - WRITE (phase 2, requires the user's OAuth token)

    /// `{movies|shows: [...]}` items body for /sync/* endpoints (accept tmdb ids).
    /// No `watched_at` → Trakt records the watch at the current time.
    private static func itemsBody(_ ref: TraktRef, rating: Int? = nil) -> [String: Any] {
        let ids: [String: Any] = ["tmdb": ref.tmdbID]
        if ref.isEpisode, let s = ref.season, let e = ref.episode {
            var episode: [String: Any] = ["number": e]
            if let rating { episode["rating"] = rating }
            let season: [String: Any] = ["number": s, "episodes": [episode]]
            return ["shows": [["ids": ids, "seasons": [season]]]]
        }
        var node: [String: Any] = ["ids": ids]
        if let rating { node["rating"] = rating }
        return ref.isShow ? ["shows": [node]] : ["movies": [node]]
    }

    private static func ok(_ code: Int?) -> Bool { code == 200 || code == 201 }

    /// Rate 1–10.
    static func rate(_ ref: TraktRef, rating: Int, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/ratings", json: itemsBody(ref, rating: rating),
                                clientID: clientID, accessToken: token))
    }
    static func removeRating(_ ref: TraktRef, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/ratings/remove", json: itemsBody(ref),
                                clientID: clientID, accessToken: token))
    }

    /// Mark watched / unwatched (adds to the user's Trakt history & profile).
    static func markWatched(_ ref: TraktRef, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/history", json: itemsBody(ref),
                                clientID: clientID, accessToken: token))
    }
    static func removeWatched(_ ref: TraktRef, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/history/remove", json: itemsBody(ref),
                                clientID: clientID, accessToken: token))
    }

    /// Favorites add / remove — Trakt's curated "favorites" list (the 👍 maps here,
    /// not to a numeric rating).
    static func addFavorite(_ ref: TraktRef, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/favorites", json: itemsBody(ref),
                                clientID: clientID, accessToken: token))
    }
    static func removeFavorite(_ ref: TraktRef, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/favorites/remove", json: itemsBody(ref),
                                clientID: clientID, accessToken: token))
    }

    /// Watchlist add / remove.
    static func addToWatchlist(_ ref: TraktRef, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/watchlist", json: itemsBody(ref),
                                clientID: clientID, accessToken: token))
    }
    static func removeFromWatchlist(_ ref: TraktRef, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/sync/watchlist/remove", json: itemsBody(ref),
                                clientID: clientID, accessToken: token))
    }

    /// Reads the user's Trakt watchlist (movies + shows) as content refs, to mirror
    /// it into the app's My List. The watchlist is a built-in list — always exists.
    static func watchlist(clientID: String, token: String) async -> [TraktRef] {
        struct Ids: Decodable { let tmdb: Int? }
        struct Node: Decodable { let ids: Ids }
        struct Row: Decodable { let movie: Node?; let show: Node? }
        guard let rows = await TraktHTTP.get("/sync/watchlist?limit=300",
                                             as: [Row].self, clientID: clientID, accessToken: token) else { return [] }
        return rows.compactMap { row in
            if let t = row.movie?.ids.tmdb { return .movie(t) }
            if let t = row.show?.ids.tmdb { return .show(t) }
            return nil
        }
    }

    /// In-progress playback (Trakt "continue watching"): movies + episodes the user
    /// paused. Returns (ref, progress 0–100, pausedAt epoch). Used to mirror Trakt →
    /// local Continue Watching.
    static func playbackProgress(clientID: String, token: String) async -> [(ref: TraktRef, progress: Double, pausedAt: Int)] {
        struct Ids: Decodable { let tmdb: Int? }
        struct Node: Decodable { let ids: Ids }
        struct Ep: Decodable { let season: Int?; let number: Int? }
        struct Row: Decodable {
            let progress: Double?; let paused_at: String?; let type: String?
            let movie: Node?; let show: Node?; let episode: Ep?
        }
        guard let rows = await TraktHTTP.get("/sync/playback?limit=200",
                                             as: [Row].self, clientID: clientID, accessToken: token) else { return [] }
        let iso = ISO8601DateFormatter()
        return rows.compactMap { r in
            let prog = r.progress ?? 0
            let paused = r.paused_at.flatMap { iso.date(from: $0) }.map { Int($0.timeIntervalSince1970) } ?? 0
            if r.type == "movie", let t = r.movie?.ids.tmdb {
                return (TraktRef.movie(t), prog, paused)
            }
            if r.type == "episode", let t = r.show?.ids.tmdb, let s = r.episode?.season, let e = r.episode?.number {
                return (TraktRef.episode(showTmdbID: t, season: s, number: e), prog, paused)
            }
            return nil
        }
    }

    /// Subject object (`movie`/`show`/`episode`) for /comments and /scrobble.
    private static func subject(_ ref: TraktRef, clientID: String) async -> [String: Any]? {
        if ref.isEpisode {
            guard let slug = await slug(ref, clientID: clientID),
                  let traktID = await episodeTraktID(ref, slug: slug, clientID: clientID) else { return nil }
            return ["episode": ["ids": ["trakt": traktID]]]
        }
        let key = ref.isShow ? "show" : "movie"
        return [key: ["ids": ["tmdb": ref.tmdbID]]]
    }

    /// Post a comment / review (Trakt requires ≥ 5 words). Spoiler-flaggable.
    static func postComment(_ ref: TraktRef, text: String, spoiler: Bool,
                            clientID: String, token: String) async -> Bool {
        guard var json = await subject(ref, clientID: clientID) else { return false }
        json["comment"] = text
        json["spoiler"] = spoiler
        return ok(await TraktHTTP.post("/comments", json: json, clientID: clientID, accessToken: token))
    }

    /// Like / unlike a comment.
    static func likeComment(_ commentID: Int, clientID: String, token: String) async -> Bool {
        ok(await TraktHTTP.post("/comments/\(commentID)/like", json: [:], clientID: clientID, accessToken: token))
    }

    /// Scrobble what you're watching to your Trakt profile (progress 0–100).
    /// Uses show + season/number for episodes (no episode-id lookup), so it works
    /// for any series on Trakt — even poorly catalogued ones.
    static func scrobble(_ action: TraktScrobbleAction, ref: TraktRef, progress: Double,
                         clientID: String, token: String) async -> Bool {
        var json: [String: Any]
        if ref.isEpisode, let s = ref.season, let e = ref.episode {
            json = ["show": ["ids": ["tmdb": ref.tmdbID]], "episode": ["season": s, "number": e]]
        } else {
            json = [(ref.isShow ? "show" : "movie"): ["ids": ["tmdb": ref.tmdbID]]]
        }
        json["progress"] = max(0, min(100, progress))
        return ok(await TraktHTTP.post("/scrobble/\(action.rawValue)", json: json,
                                       clientID: clientID, accessToken: token))
    }
}
