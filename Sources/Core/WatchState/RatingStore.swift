import Foundation
import GRDB

/// Voto del usuario sobre un contenido (base del recomendador por gustos).
struct UserRating: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "userRating"

    var userID: String
    var itemID: String   // mergeKey
    var liked: Bool
    var ratedAt: Int
}

enum RatingStore {

    static func get(userID: String, mergeKey: String) async -> Bool? {
        (try? await AppDatabase.shared.dbQueue.read { db in
            try UserRating
                .filter(Column("userID") == userID && Column("itemID") == mergeKey)
                .fetchOne(db)
        })?.liked
    }

    /// liked: true/false casts a vote; nil clears it.
    static func set(userID: String, mergeKey: String, liked: Bool?) async {
        try? await AppDatabase.shared.dbQueue.write { db in
            if let liked {
                try UserRating(
                    userID: userID,
                    itemID: mergeKey,
                    liked: liked,
                    ratedAt: Int(Date().timeIntervalSince1970)
                ).save(db)
            } else {
                try UserRating
                    .filter(Column("userID") == userID && Column("itemID") == mergeKey)
                    .deleteAll(db)
            }
        }
        await MainActor.run {
            SyncCoordinator.shared.enqueue(.userRating(userID: userID, itemID: mergeKey))
            // Mirror the 👍 to the user's Trakt Favorites ("me gusta"), if linked.
            TraktSync.pushLike(userID: userID, mergeKey: mergeKey, liked: liked)
        }
    }

    /// All of the user's votes (for the recommender).
    static func all(userID: String) async -> [String: Bool] {
        (try? await AppDatabase.shared.dbQueue.read { db in
            try UserRating
                .filter(Column("userID") == userID)
                .fetchAll(db)
                .reduce(into: [:]) { $0[$1.itemID] = $1.liked }
        }) ?? [:]
    }
}

/// Motor de recomendación centralizado: géneros + actores + gustos del usuario.
/// 100% local (BD propia), per-usuario, fusionado multi-servidor y con filtro parental.
enum Recommend {

    /// Taste profile: weights per genre and per actor, built from
    /// explicit 👍/👎 (strong signal) and watch history (weak signal).
    struct TasteProfile: Sendable {
        var genreWeights: [String: Double] = [:]
        var actorWeights: [Int: Double] = [:]
        var dislikedKeys: Set<String> = []
        var hasSignal: Bool { !genreWeights.isEmpty || !actorWeights.isEmpty }
    }

    /// Preloaded catalog context to score without repeated queries.
    private struct Catalog {
        let merged: [MediaItem]
        let castByMergeKey: [String: Set<Int>]
    }

    @MainActor
    private static func loadCatalog() async -> Catalog {
        let raw = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.fetchAll(db)
        }) ?? []
        let entries: [CastEntry] = (try? await AppDatabase.shared.dbQueue.read { db in
            try CastEntry.fetchAll(db)
        }) ?? []
        let mergeKeyByID = raw.reduce(into: [String: String]()) { $0[$1.id] = $1.mergeKey }
        var castMap: [String: Set<Int>] = [:]
        for entry in entries {
            guard let key = mergeKeyByID[entry.itemID] else { continue }
            castMap[key, default: []].insert(entry.personID)
        }
        return Catalog(
            merged: ParentalStore.shared.filter(HomeViewModel.merged(raw)),
            castByMergeKey: castMap
        )
    }

    @MainActor
    static func profile(userID: String) async -> TasteProfile {
        let catalog = await loadCatalog()
        let byMergeKey = catalog.merged.reduce(into: [String: MediaItem]()) { $0[$1.mergeKey] = $1 }
        let ratings = await RatingStore.all(userID: userID)
        let states = await WatchStore.states(userID: userID)

        var profile = TasteProfile()

        func apply(_ item: MediaItem, weight: Double) {
            for genre in item.genres.split(separator: "|") {
                profile.genreWeights[String(genre), default: 0] += weight
            }
            for person in catalog.castByMergeKey[item.mergeKey] ?? [] {
                profile.actorWeights[person, default: 0] += weight
            }
        }

        // 👍 = +1.0 · 👎 = -1.2 (rejection weighs more than liking)
        for (mergeKey, liked) in ratings {
            guard let item = byMergeKey[mergeKey] else { continue }
            apply(item, weight: liked ? 1.0 : -1.2)
            if !liked { profile.dislikedKeys.insert(mergeKey) }
        }
        // Fully watched = weak signal (+0.3)
        for state in states.values where state.viewCount > 0 && !state.isEpisode {
            guard let item = catalog.merged.first(where: { $0.watchKey == state.itemID }) else { continue }
            if ratings[item.mergeKey] == nil {
                apply(item, weight: 0.3)
            }
        }
        return profile
    }

    /// Similar to a given title: content similarity (genres + shared cast)
    /// adjusted by the user's taste profile.
    @MainActor
    static func similar(to item: MediaItem, limit: Int = 12) async -> [MediaItem] {
        let catalog = await loadCatalog()
        let taste = await profile(userID: UserContext.currentUserID)
        let myGenres = Set(item.genres.split(separator: "|").map(String.init))
        let myCast = catalog.castByMergeKey[item.mergeKey] ?? []

        return catalog.merged
            .filter { $0.type == item.type && $0.mergeKey != item.mergeKey && !taste.dislikedKeys.contains($0.mergeKey) }
            .compactMap { candidate -> (MediaItem, Double)? in
                let genres = Set(candidate.genres.split(separator: "|").map(String.init))
                let cast = catalog.castByMergeKey[candidate.mergeKey] ?? []
                let genreOverlap = Double(genres.intersection(myGenres).count)
                let castOverlap = Double(cast.intersection(myCast).count)
                let content = genreOverlap * 2.0 + castOverlap * 1.5
                guard content > 0 else { return nil }
                let tasteScore = genres.reduce(0.0) { $0 + (taste.genreWeights[$1] ?? 0) } * 0.4
                    + cast.reduce(0.0) { $0 + (taste.actorWeights[$1] ?? 0) } * 0.3
                let prior = (candidate.audienceRating ?? 5) / 10
                return (candidate, content + tasteScore + prior)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// "For You": combines TMDB's recommendation engine (seeded with the user's
    /// taste) with the local recommender. TMDB brings full-catalog relevance;
    /// the local side guarantees titles you already own. No duplicates.
    @MainActor
    static func forUser(userID: String, limit: Int = 15) async -> [MediaItem] {
        let tmdb = await forUserTMDB(userID: userID, limit: limit)
        let local = await forUserLocal(userID: userID, limit: limit)
        var seen = Set<String>()
        var blended: [MediaItem] = []
        for item in tmdb + local where seen.insert(item.mergeKey).inserted {
            blended.append(item)
        }
        return Array(blended.prefix(limit))
    }

    /// tmdbID e isShow a partir de un mergeKey "tmdb:tipo:ID".
    private static func tmdbInfo(_ mergeKey: String) -> (id: Int, isShow: Bool)? {
        let parts = mergeKey.split(separator: ":")
        guard parts.count == 3, parts[0] == "tmdb", let id = Int(parts[2]) else { return nil }
        return (id, parts[1] == "show")
    }

    /// Advanced recommendations via TMDB: runs TMDB's recommendation engine over
    /// the user's seeds (👍 and watch history), aggregating votes across seeds
    /// (collaborative filtering) and weighting by rating. Maps to a local copy or,
    /// when the TMDB catalog is available, to a virtual title playable via torrent.
    @MainActor
    static func forUserTMDB(userID: String, limit: Int) async -> [MediaItem] {
        guard let key = SettingsStore.shared.tmdbKey else { return [] }
        let ratings = await RatingStore.all(userID: userID)
        let states = await WatchStore.states(userID: userID)

        // Weighted seeds (mergeKey -> weight): 👍 strong, watched weak.
        var seedWeights: [String: Double] = [:]
        var disliked = Set<String>()
        for (mk, liked) in ratings {
            if liked { seedWeights[mk, default: 0] += 2.0 } else { disliked.insert(mk) }
        }
        for s in states.values where s.viewCount > 0 {
            if s.isEpisode {
                // "ep:tmdb:show:ID:sXeY" -> "tmdb:show:ID"
                guard s.itemID.hasPrefix("ep:") else { continue }
                let body = String(s.itemID.dropFirst(3))
                if let range = body.range(of: ":s", options: .backwards) {
                    seedWeights[String(body[..<range.lowerBound]), default: 0] += 1.0
                }
            } else {
                seedWeights[s.itemID, default: 0] += 1.0
            }
        }
        guard !seedWeights.isEmpty else { return [] }

        // Top seeds (max 10) to avoid hammering TMDB.
        let seeds = seedWeights.sorted { $0.value > $1.value }.prefix(10)
        let seedKeys = Set(seedWeights.keys)
        let catalogBrowse = SettingsStore.shared.fullCatalogEnabled

        // Each seed's recommendations in parallel, aggregated by tmdbID.
        let aggregated = await withTaskGroup(of: [(DiscoverItem, Double)].self) { group -> [Int: (DiscoverItem, Double)] in
            for (mergeKey, weight) in seeds {
                guard let info = tmdbInfo(mergeKey) else { continue }
                group.addTask {
                    let recs = await TMDBBrowse.recommendations(tmdbID: info.id, isShow: info.isShow, key: key)
                    return recs.map { ($0, weight) }
                }
            }
            var map: [Int: (DiscoverItem, Double)] = [:]
            for await chunk in group {
                for (item, weight) in chunk {
                    if var existing = map[item.tmdbID] {
                        existing.1 += weight
                        map[item.tmdbID] = existing
                    } else {
                        map[item.tmdbID] = (item, weight)
                    }
                }
            }
            return map
        }

        // Local copies by tmdbID (to map to the library when one exists).
        let tmdbIDs = Array(aggregated.keys)
        let locals = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(tmdbIDs.contains(Column("tmdbID"))).fetchAll(db)
        }) ?? []
        let localByTmdb = Dictionary(locals.compactMap { item -> (Int, MediaItem)? in
            item.tmdbID.map { ($0, item) }
        }, uniquingKeysWith: { a, _ in a })

        func isWatched(_ mergeKey: String, isShow: Bool) -> Bool {
            if !isShow { return (states[mergeKey]?.viewCount ?? 0) > 0 }
            return states.values.contains { $0.itemID.hasPrefix("ep:\(mergeKey):") && $0.viewCount > 0 }
        }

        let scored: [(MediaItem, Double)] = aggregated.values.compactMap { (item, seedScore) in
            let mergeKey = item.mergeKey
            guard !seedKeys.contains(mergeKey), !disliked.contains(mergeKey),
                  !isWatched(mergeKey, isShow: item.isShow) else { return nil }
            let media: MediaItem
            if let local = localByTmdb[item.tmdbID] {
                media = local
            } else if catalogBrowse {
                media = MediaItem.virtualStub(from: item)
            } else {
                return nil
            }
            let score = seedScore * 2.0 + (item.rating ?? 5) / 10
            return (media, score)
        }

        let ranked = ParentalStore.shared.filter(scored.sorted { $0.1 > $1.1 }.map(\.0))
        return Array(ranked.prefix(limit))
    }

    /// Local "For You": the catalog's best per the user's profile (excluding watched/voted).
    @MainActor
    static func forUserLocal(userID: String, limit: Int = 15) async -> [MediaItem] {
        let taste = await profile(userID: userID)
        guard taste.hasSignal else { return [] }
        let catalog = await loadCatalog()
        let states = await WatchStore.states(userID: userID)
        let ratings = await RatingStore.all(userID: userID)
        let stopped = StoppedStore.all(userID: userID)

        func isWatched(_ item: MediaItem) -> Bool {
            if item.type == "movie" {
                return (states[item.watchKey]?.viewCount ?? 0) > 0
            }
            let prefix = "ep:\(item.mergeKey):"
            return states.values.contains { $0.itemID.hasPrefix(prefix) && $0.viewCount > 0 }
        }

        return catalog.merged
            .filter { !isWatched($0) && ratings[$0.mergeKey] == nil && !taste.dislikedKeys.contains($0.mergeKey) && !stopped.contains($0.mergeKey) }
            .compactMap { candidate -> (MediaItem, Double)? in
                let genres = Set(candidate.genres.split(separator: "|").map(String.init))
                let cast = catalog.castByMergeKey[candidate.mergeKey] ?? []
                let tasteScore = genres.reduce(0.0) { $0 + (taste.genreWeights[$1] ?? 0) }
                    + cast.reduce(0.0) { $0 + (taste.actorWeights[$1] ?? 0) } * 0.6
                guard tasteScore > 0.5 else { return nil }
                let prior = (candidate.audienceRating ?? 5) / 10
                return (candidate, tasteScore + prior)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
