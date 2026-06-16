import SwiftUI
import GRDB

@MainActor
final class DetailViewModel: ObservableObject {

    struct EpisodeSlot: Identifiable {
        let number: Int
        let episode: Episode?   // nil = no local copy
        let title: String?
        var watched: Bool
        var progress: Double?
        /// Started but not finished (has a resume offset, never completed).
        var inProgress: Bool = false
        var watchedDate: Date?
        var airDate: String?    // "yyyy-MM-dd" (TMDB)
        var stillURL: URL?      // episode image (TMDB, virtual content)
        var overview: String = ""
        /// Runtime in minutes (local episode duration or TMDB runtime), if known.
        var durationMinutes: Int? = nil
        /// Playable via an external source (torrent) even without a local copy.
        var virtualPlayable: Bool = false
        var id: Int { number }
        /// No way to play it: neither a local copy nor a virtual source.
        var isMissing: Bool { episode == nil && !virtualPlayable }
        var playable: Bool { episode != nil || virtualPlayable }
        /// Missing because it hasn't aired yet (future date).
        var notYetAired: Bool {
            guard episode == nil, let d = airDate, !d.isEmpty else { return false }
            return d > TMDBBrowse.todayString
        }
    }

    struct SeasonInfo: Identifiable {
        let number: Int
        var slots: [EpisodeSlot]
        var missingCount: Int { slots.filter(\.isMissing).count }
        var id: Int { number }
    }

    @Published var cast: [CastMember] = []
    @Published var similar: [MediaItem] = []
    /// The TMDB collection ("saga") this movie belongs to, in order.
    @Published var saga: [MediaItem] = []
    @Published var sagaName = ""
    /// YouTube video key for the trailer (TMDB videos). Opened in the YouTube app.
    @Published var trailerYouTubeKey: String?
    @Published var resumeOffsetMs = 0
    /// Virtual movie not yet available (in theaters / coming soon): no Play, with dates.
    @Published var notYetReleased = false
    @Published var theatricalDate: String?
    @Published var digitalDate: String?
    @Published var seasons: [SeasonInfo] = []
    @Published var selectedSeason = 1
    @Published var nextEpisodeLabel: String?
    @Published var nextIsMissing = false
    @Published var inMyList = false
    @Published var watchedAt: Date?
    @Published var liked: Bool?
    /// Effective item (enriched if it was virtual). The view uses it for rendering.
    @Published var content: MediaItem?

    private var episodeMetaCache: [Int: [Int: TMDBClient.EpisodeMeta]] = [:]
    private var virtualEpisodeCache: [Int: [TMDBBrowse.DiscoverEpisode]] = [:]
    private var item: MediaItem?

    func load(item rawItem: MediaItem) async {
        // Lazy enrichment of virtual items (genres, duration, logo, PG).
        let item = await rawItem.enrichedIfVirtual()
        self.item = item
        self.content = item
        let settings = SettingsStore.shared
        let lang = L10nStore.shared.effective

        let userID = UserContext.currentUserID
        let states = await WatchStore.states(userID: userID)

        if item.type == "movie" {
            let state = states[item.watchKey]
            resumeOffsetMs = state?.viewOffsetMs ?? 0
            if let finished = state?.finishedAt, finished > 0 {
                watchedAt = Date(timeIntervalSince1970: TimeInterval(finished))
            }
        }
        inMyList = await MyListStore.contains(userID: userID, mergeKey: item.mergeKey)

        // Recent virtual movie with no digital release yet → in theaters / coming soon.
        if item.isVirtual, item.type == "movie", let key = settings.tmdbKey, let tmdbID = item.tmdbID {
            let today = TMDBBrowse.todayString
            let currentYear = Int(today.prefix(4)) ?? 0
            if (item.year ?? 0) >= currentYear - 1 {
                let dates = await TMDBBrowse.releaseDates(movieID: tmdbID, key: key)
                let digitalOut = (dates.digital.map { $0 <= today }) ?? false
                if !digitalOut {
                    notYetReleased = true
                    theatricalDate = dates.theatrical
                    digitalDate = dates.digital
                }
            }
        }

        // "More like this": community related from Trakt when configured, else
        // TMDB recommendations, else the internal recommender. Always mapped to a
        // local copy when one exists. Fully resilient.
        if let key = settings.tmdbKey, let tmdbID = item.tmdbID {
            if settings.traktReady {
                similar = await relatedFromTrakt(item: item, key: key, tmdbID: tmdbID)
            }
            if similar.isEmpty {
                similar = await relatedFromTMDB(item: item, key: key, tmdbID: tmdbID)
            }
        }
        if similar.isEmpty {
            similar = await Recommend.similar(to: item)
        }
        // Saga: the movie's TMDB collection, mapped to local copies when they exist.
        if item.type == "movie", let key = settings.tmdbKey, let tmdbID = item.tmdbID,
           let coll = await TMDBBrowse.collection(forMovie: tmdbID, key: key) {
            sagaName = coll.name
            saga = await mapToLibrary(coll.items)
        }
        liked = await RatingStore.get(userID: userID, mergeKey: item.mergeKey)

        // Trailer (TMDB → YouTube) + cast, in parallel. No Plex dependency.
        if let key = settings.tmdbKey, let tmdbID = item.tmdbID {
            async let trailerTask = TMDBBrowse.trailerKey(tmdbID: tmdbID, isShow: item.type == "show", key: key)
            async let castTask = TMDBClient.credits(tmdbID: tmdbID, isShow: item.type == "show", key: key)
            cast = await castTask
            trailerYouTubeKey = await trailerTask
        }

        // Shows: seasons. Virtual → from TMDB (everything playable); real → library.
        if item.type == "show" {
            if item.isVirtual {
                await loadVirtualSeasons(item: item, states: states, tmdbKey: settings.tmdbKey)
            } else {
                await loadSeasons(item: item, states: states, tmdbKey: settings.tmdbKey, lang: lang)
            }
        }
    }

    /// Seasons of a virtual show (TMDB catalog): all aired episodes are marked
    /// playable; watched state is cross-referenced with the user's progress.
    private func loadVirtualSeasons(item: MediaItem, states: [String: WatchState], tmdbKey: String?) async {
        guard let tmdbKey, let tmdbID = item.tmdbID else { return }
        let tmdbSeasons = await TMDBBrowse.seasons(showID: tmdbID, key: tmdbKey)
        seasons = tmdbSeasons.map { s in
            let slots = (1...max(s.episodeCount, 1)).map { n -> EpisodeSlot in
                let key = PlexPlayback.episodeWatchKey(showMergeKey: item.mergeKey, season: s.seasonNumber, number: n)
                let state = states[key]
                let progress: Double? = {
                    guard let state, state.viewOffsetMs > 0, let dur = state.durationMs, dur > 0 else { return nil }
                    return Double(state.viewOffsetMs) / Double(dur)
                }()
                return EpisodeSlot(number: n, episode: nil, title: nil,
                                   watched: (state?.viewCount ?? 0) > 0, progress: progress,
                                   inProgress: (state?.viewCount ?? 0) == 0 && (state?.viewOffsetMs ?? 0) > 0,
                                   watchedDate: nil, virtualPlayable: true)
            }
            return SeasonInfo(number: s.seasonNumber, slots: slots)
        }
        if let first = seasons.first { selectedSeason = first.number }
        nextEpisodeLabel = nil
        await fillEpisodeNames(season: selectedSeason)
    }

    /// Episode that "Play" should start, Netflix-style — based on your real
    /// progress, not the earliest gap:
    ///   1. Resume the latest episode you have IN PROGRESS (started, not finished).
    ///   2. Otherwise, the playable episode right AFTER the last one you finished
    ///      (e.g. finished E3 → play E4), skipping any that aren't playable.
    ///   3. Otherwise (nothing watched, or everything watched) → the first
    ///      playable episode.
    func firstUnwatchedEpisode() -> (season: Int, slot: EpisodeSlot)? {
        let ordered: [(season: Int, slot: EpisodeSlot)] = seasons.flatMap { season in
            season.slots.map { (season.number, $0) }
        }

        // 1) Resume the latest in-progress episode.
        if let inProgress = ordered.last(where: { $0.slot.playable && $0.slot.inProgress }) {
            return inProgress
        }

        // 2) The next playable episode after the last finished one.
        if let lastWatched = ordered.lastIndex(where: { $0.slot.watched }) {
            if let next = ordered[(lastWatched + 1)...].first(where: { $0.slot.playable }) {
                return next
            }
            // Series finished (nothing playable after the last watched) → fall
            // through to start over from the first episode.
        }

        // 3) Nothing watched/in-progress, or all watched → first playable.
        return ordered.first(where: { $0.slot.playable })
    }

    /// Manually marks/unmarks an episode as watched (from the long-press menu)
    /// and refreshes the seasons, keeping the season the user is viewing.
    func toggleEpisodeWatched(season: Int, slot: EpisodeSlot) async {
        guard let item else { return }
        let watchKey = PlexPlayback.episodeWatchKey(showMergeKey: item.mergeKey, season: season, number: slot.number)
        let refID = slot.episode?.id ?? watchKey
        await WatchStore.setEpisodeWatched(!slot.watched, userID: UserContext.currentUserID, watchKey: watchKey, refID: refID)
        let keep = selectedSeason
        let states = await WatchStore.states(userID: UserContext.currentUserID)
        if item.isVirtual {
            await loadVirtualSeasons(item: item, states: states, tmdbKey: SettingsStore.shared.tmdbKey)
        } else {
            await loadSeasons(item: item, states: states, tmdbKey: SettingsStore.shared.tmdbKey, lang: L10nStore.shared.effective)
        }
        if seasons.contains(where: { $0.number == keep }) { selectedSeason = keep }
    }

    private func loadSeasons(item: MediaItem, states: [String: WatchState], tmdbKey: String?, lang: String) async {
        // Local episodes from all copies of the show, deduped by season/episode.
        let copies: [MediaItem] = ((try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(Column("type") == "show").fetchAll(db)
        }) ?? []).filter { $0.mergeKey == item.mergeKey }
        let showKeys = copies.map(\.id)
        let episodes: [Episode] = (try? await AppDatabase.shared.dbQueue.read { db in
            try Episode
                .filter(showKeys.contains(Column("showKey")))
                .order(Column("seasonNumber").asc, Column("episodeNumber").asc)
                .fetchAll(db)
        }) ?? []

        var localByKey: [String: Episode] = [:]
        for ep in episodes {
            let key = "s\(ep.seasonNumber)e\(ep.episodeNumber)"
            if localByKey[key] == nil { localByKey[key] = ep }
        }

        // Official TMDB count to detect gaps.
        var officialSeasons: [TVSeasonInfo] = []
        if let tmdbKey, let tmdbID = item.tmdbID {
            officialSeasons = await TMDBClient.tvSeasons(tmdbID: tmdbID, key: tmdbKey)
        }

        let localSeasonNumbers = Set(episodes.map(\.seasonNumber))
        let officialByNumber = officialSeasons.reduce(into: [Int: Int]()) { $0[$1.number] = $1.episodeCount }
        let allSeasonNumbers = localSeasonNumbers.union(officialByNumber.keys).filter { $0 > 0 }.sorted()

        var built: [SeasonInfo] = []
        for seasonNumber in allSeasonNumbers {
            let localMax = episodes.filter { $0.seasonNumber == seasonNumber }.map(\.episodeNumber).max() ?? 0
            let count = max(officialByNumber[seasonNumber] ?? 0, localMax)
            guard count > 0 else { continue }
            var slots: [EpisodeSlot] = []
            for number in 1...count {
                let episode = localByKey["s\(seasonNumber)e\(number)"]
                let key = PlexPlayback.episodeWatchKey(showMergeKey: item.mergeKey, season: seasonNumber, number: number)
                let state = states[key]
                let progress: Double? = {
                    guard let state, state.viewOffsetMs > 0, let dur = episode?.durationMs, dur > 0 else { return nil }
                    return Double(state.viewOffsetMs) / Double(dur)
                }()
                slots.append(EpisodeSlot(
                    number: number,
                    episode: episode,
                    title: episode?.title,
                    watched: (state?.viewCount ?? 0) > 0,
                    progress: progress,
                    inProgress: (state?.viewCount ?? 0) == 0 && (state?.viewOffsetMs ?? 0) > 0,
                    watchedDate: (state?.finishedAt).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                    durationMinutes: episode?.durationMs.map { $0 / 60_000 }
                ))
            }
            built.append(SeasonInfo(number: seasonNumber, slots: slots))
        }
        seasons = built

        // Next episode to watch: first unfinished one in order.
        outer: for season in built {
            for slot in season.slots {
                if slot.watched { continue }
                if slot.isMissing {
                    nextEpisodeLabel = "T\(season.number) · E\(slot.number)"
                    nextIsMissing = true
                    break outer
                }
                nextEpisodeLabel = "T\(season.number) · E\(slot.number)"
                nextIsMissing = false
                break outer
            }
        }

        if let first = built.first {
            selectedSeason = states.values
                .filter { $0.isEpisode && $0.viewOffsetMs > 0 }
                .isEmpty ? first.number : selectedSeason
        }
        await fillEpisodeNames(season: selectedSeason)
    }

    /// Related titles from TMDB (full-catalog recommendations). Uses the local copy
    /// if it exists; otherwise, a virtual stub (only if the TMDB catalog is available, to
    /// avoid offering unplayable titles to users without external sources).
    private func relatedFromTMDB(item: MediaItem, key: String, tmdbID: Int) async -> [MediaItem] {
        let recs = await TMDBBrowse.recommendations(tmdbID: tmdbID, isShow: item.type == "show", key: key)
        guard !recs.isEmpty else { return [] }
        return await mapToLibrary(recs)
    }

    /// Community-based "related" from Trakt, enriched with TMDB art and mapped to
    /// the library (or virtual stubs). No-op if Trakt isn't configured.
    private func relatedFromTrakt(item: MediaItem, key: String, tmdbID: Int) async -> [MediaItem] {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty else { return [] }
        let ref: TraktRef = item.type == "show" ? .show(tmdbID) : .movie(tmdbID)
        let refs = await TraktClient.related(ref, clientID: clientID)
        guard !refs.isEmpty else { return [] }
        let discover = await withTaskGroup(of: (Int, DiscoverItem?).self) { group -> [DiscoverItem] in
            for (i, r) in refs.enumerated() {
                group.addTask {
                    (i, await TMDBBrowse.discoverItem(tmdbID: r.tmdbID, isShow: r.isShow, key: key))
                }
            }
            var byIndex: [Int: DiscoverItem] = [:]
            for await (i, di) in group { if let di { byIndex[i] = di } }
            return refs.indices.compactMap { byIndex[$0] }
        }
        return await mapToLibrary(discover)
    }

    /// Maps TMDB items to local copies when they exist; otherwise virtual stubs
    /// (only if the TMDB catalog is available, to avoid offering unplayable
    /// titles to users without external sources). Parental-filtered.
    private func mapToLibrary(_ tmdbItems: [DiscoverItem]) async -> [MediaItem] {
        guard !tmdbItems.isEmpty else { return [] }
        // Parental first shield by age certification (cert-aware; handles virtual items).
        let safe = await ParentalStore.shared.filterDiscover(tmdbItems)
        let ids = safe.map(\.tmdbID)
        let locals = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(ids.contains(Column("tmdbID"))).fetchAll(db)
        }) ?? []
        let localByTmdb = Dictionary(locals.compactMap { item -> (Int, MediaItem)? in
            item.tmdbID.map { ($0, item) }
        }, uniquingKeysWith: { a, _ in a })

        let catalogBrowse = SettingsStore.shared.fullCatalogEnabled
        return safe.compactMap { entry in
            if let local = localByTmdb[entry.tmdbID] { return local }
            return catalogBrowse ? MediaItem.virtualStub(from: entry) : nil
        }
    }

    func toggleMyList() async {
        guard let item else { return }
        inMyList = await MyListStore.toggle(userID: UserContext.currentUserID, mergeKey: item.mergeKey)
    }

    /// 👍/👎: repeating the same vote clears it.
    func rate(_ value: Bool) async {
        guard let item else { return }
        let newValue: Bool? = (liked == value) ? nil : value
        liked = newValue
        await RatingStore.set(userID: UserContext.currentUserID, mergeKey: item.mergeKey, liked: newValue)
    }

    /// TMDB name, image and date for the episodes of the visible season.
    func fillEpisodeNames(season: Int) async {
        guard let item, item.type == "show",
              let key = SettingsStore.shared.tmdbKey, let tmdbID = item.tmdbID else { return }

        // Virtual show: full episodes from TMDB (name + image + air date).
        if item.isVirtual {
            let eps: [TMDBBrowse.DiscoverEpisode]
            if let cached = virtualEpisodeCache[season] {
                eps = cached
            } else {
                eps = await TMDBBrowse.episodes(showID: tmdbID, season: season, key: key)
                virtualEpisodeCache[season] = eps
            }
            guard let idx = seasons.firstIndex(where: { $0.number == season }) else { return }
            let byNumber = Dictionary(uniqueKeysWithValues: eps.map { ($0.episodeNumber, $0) })
            seasons[idx].slots = seasons[idx].slots.map { slot in
                guard let ep = byNumber[slot.number] else { return slot }
                var copy = slot
                copy = EpisodeSlot(number: slot.number, episode: nil, title: ep.name,
                                   watched: slot.watched, progress: slot.progress, watchedDate: slot.watchedDate,
                                   airDate: ep.airDate, stillURL: ep.aired ? ep.stillURL : nil, overview: ep.overview,
                                   durationMinutes: ep.runtime, virtualPlayable: ep.aired)
                return copy
            }
            return
        }

        guard let index = seasons.firstIndex(where: { $0.number == season }),
              seasons[index].slots.contains(where: { $0.isMissing }) else { return }

        let metas: [Int: TMDBClient.EpisodeMeta]
        if let cached = episodeMetaCache[season] {
            metas = cached
        } else {
            metas = await TMDBClient.seasonEpisodes(tmdbID: tmdbID, season: season, key: key, lang: L10nStore.shared.effective)
            episodeMetaCache[season] = metas
        }
        guard !metas.isEmpty, let idx = seasons.firstIndex(where: { $0.number == season }) else { return }
        seasons[idx].slots = seasons[idx].slots.map { slot in
            guard slot.isMissing, let meta = metas[slot.number] else { return slot }
            var copy = slot
            if copy.title == nil { copy.airDate = meta.airDate; return EpisodeSlot(number: slot.number, episode: slot.episode, title: meta.name, watched: slot.watched, progress: slot.progress, watchedDate: slot.watchedDate, airDate: meta.airDate) }
            copy.airDate = meta.airDate
            return copy
        }
    }
}
