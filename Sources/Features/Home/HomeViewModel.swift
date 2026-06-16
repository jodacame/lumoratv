import SwiftUI
import GRDB

enum ShelfStyle {
    case landscapeProgress  // Continue Watching: 16:9 with progress bar
    case posterLarge        // Recently added: large posters
    case poster             // Genre rows: standard posters
    case wide               // Gems: wide cinematic cards
    case numbered           // Top 10 with a giant number
}

struct ShelfItem: Identifiable, Hashable, Sendable {
    let media: MediaItem
    var progress: Double?
    var subtitle: String?
    /// Continue Watching: total runtime and time left of the in-progress item (ms).
    var totalMs: Int?
    var remainingMs: Int?
    var id: String { media.id }
}

struct Shelf: Identifiable {
    let id: String
    let title: String
    let style: ShelfStyle
    let items: [ShelfItem]
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var shelves: [Shelf] = []
    @Published var heroItem: MediaItem?
    /// The fullscreen backdrop is only shown while browsing "Continue Watching".
    @Published var heroBackdropVisible = false
    /// TMDB catalog rows when available (Streaming Mode or no server).
    @Published var discoverRows: [DiscoverRow] = []
    /// Categories (genres) for the home carousel.
    @Published var categories: [DiscoverCategory] = []
    /// tmdbIDs present in the local library (to mark local vs remote in the TMDB catalog).
    @Published var localTmdbIDs: Set<Int> = []
    /// Local copy by tmdbID — lets discover cards route the context menu to the
    /// real library item when one exists (else a virtual stub).
    @Published var localByTmdb: [Int: MediaItem] = [:]

    /// True while the discovery rows are being fetched/filtered (shows a spinner;
    /// the parental cert lookups can make the first load take a moment).
    @Published var loadingDiscovery = false

    private var itemsByID: [String: MediaItem] = [:]
    private var heroDebounce: Task<Void, Never>?
    /// Prevents concurrent background refreshes of the discovery rows.
    private var isRefreshingDiscovery = false

    /// Crea stubs virtuales (desde TMDB) para los estados EN CURSO cuyo título no está
    /// en el catálogo local de esta TV — el caso de "lo empecé en otro Apple TV"
    /// (sincronizado por iCloud) o lo trajo Trakt. Insert-or-ignore: nunca pisa una
    /// copia existente. Sin catálogo TMDB (modo solo-Plex) es no-op, porque ahí no se
    /// muestran items virtuales de todos modos.
    ///
    /// Además, en un perfil RESTRINGIDO (kids) rellena el `contentRating` (certificación
    /// TMDB) de los items en curso que no lo tengan. Sin él, el filtro parental los
    /// oculta por "sin rating" aunque sean aptos — el caso de "le doy play y no me
    /// queda en Continuar viendo".
    private func hydrateContinueWatching() async {
        guard SettingsStore.shared.fullCatalogEnabled,
              let tmdbKey = SettingsStore.shared.tmdbKey else { return }
        let userID = UserContext.currentUserID
        let states = await WatchStore.states(userID: userID)
        let inProgress = states.values.filter { $0.viewOffsetMs > 0 && $0.finishedAt == nil }
        guard !inProgress.isEmpty else { return }
        let restricted = ParentalStore.shared.activeLevel != nil
        let db = AppDatabase.shared.dbQueue
        // tmdbID → contentRating local ("" = presente sin rating). Sin clave = no está.
        let local: [Int: String] = (try? await db.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT tmdbID, contentRating FROM mediaItem WHERE tmdbID IS NOT NULL")
                .reduce(into: [Int: String]()) { dict, row in
                    if let id: Int = row["tmdbID"] { dict[id] = (row["contentRating"] as String?) ?? "" }
                }
        }) ?? [:]
        for state in inProgress {
            guard let ref = TraktSync.watchedRef(from: state.itemID) else { continue }
            let tmdbID = ref.tmdbID
            if let rating = local[tmdbID] {
                // Ya está en catálogo. En perfil restringido sin rating → rellena el
                // cert para que el filtro lo evalúe (si no, lo oculta).
                if restricted, rating.isEmpty,
                   let cert = await CertStore.shared.certification(tmdbID: tmdbID, isShow: ref.isShow, apiKey: tmdbKey),
                   !cert.isEmpty {
                    try? await db.write { dbc in
                        try dbc.execute(
                            sql: "UPDATE mediaItem SET contentRating = ? WHERE tmdbID = ? AND (contentRating IS NULL OR contentRating = '')",
                            arguments: [cert, tmdbID])
                    }
                }
                continue
            }
            // No está en catálogo → materializar (con su cert).
            let cert = await CertStore.shared.certification(tmdbID: tmdbID, isShow: ref.isShow, apiKey: tmdbKey)
            if ref.isEpisode, let season = ref.season, let number = ref.episode {
                guard let show = await TMDBBrowse.discoverItem(tmdbID: tmdbID, isShow: true, key: tmdbKey) else { continue }
                let ep = TMDBBrowse.DiscoverEpisode(seasonNumber: season, episodeNumber: number,
                                                    name: "", overview: "", stillPath: nil, airDate: nil, runtime: nil)
                await VirtualLibrary.registerEpisode(show: show, episode: ep, certification: cert)
            } else if !ref.isShow {
                guard let movie = await TMDBBrowse.discoverItem(tmdbID: tmdbID, isShow: false, key: tmdbKey) else { continue }
                await VirtualLibrary.registerMovie(movie, certification: cert)
            }
        }
    }

    func load() async {
        let db = AppDatabase.shared.dbQueue
        // Materializa stubs de TMDB para lo que quedó EN CURSO en OTRO Apple TV (sync
        // iCloud) o en Trakt, pero que no está en el catálogo local de este equipo —
        // así "Continuar viendo" puede mostrarlo aquí aunque nunca se haya tocado el
        // título en esta TV. Debe ir ANTES de leer el catálogo.
        await hydrateContinueWatching()
        // An EMPTY local library is valid (fresh install with TMDB but no Plex
        // server, i.e. catalog/streaming mode): the local shelves below simply stay
        // empty and the TMDB/Trakt discovery rows populate the Home. Only bail when
        // there's truly nothing to show (no library AND no TMDB catalog available).
        let raw = (try? await db.read { dbc in try MediaItem.fetchAll(dbc) }) ?? []
        if raw.isEmpty && !SettingsStore.shared.fullCatalogEnabled { return }

        // Merged catalog: a single entry per content even if it lives on several servers.
        let all = ParentalStore.shared.filter(Self.merged(raw))
        localTmdbIDs = Set(all.compactMap(\.tmdbID))
        localByTmdb = Dictionary(all.compactMap { i in i.tmdbID.map { ($0, i) } },
                                 uniquingKeysWith: { a, _ in a })
        // Only what is on a server (excludes virtual items persisted for
        // torrent "Continue Watching"). The catalog rows use this.
        let library = all.filter { !$0.isVirtual }
        // With the TMDB catalog disabled, NOTHING virtual/remote should appear in any row.
        let discoverOn = SettingsStore.shared.fullCatalogEnabled
        func allowed(_ item: MediaItem) -> Bool { discoverOn || !item.isVirtual }
        let allByID = raw.reduce(into: [String: MediaItem]()) { $0[$1.id] = $1 }
        let canonicalByMergeKey = all.reduce(into: [String: MediaItem]()) { $0[$1.mergeKey] = $1 }

        // Internal watch state of the Apple TV's current user.
        let userID = UserContext.currentUserID
        let states = await WatchStore.states(userID: userID)

        let episodeRefIDs = states.values
            .filter { $0.isEpisode && $0.viewOffsetMs > 0 }
            .compactMap(\.refID)
        let episodesInProgress: [Episode] = (try? await db.read { dbc in
            try Episode.filter(episodeRefIDs.contains(Column("id"))).fetchAll(dbc)
        }) ?? []

        itemsByID = all.reduce(into: [:]) { $0[$1.id] = $1 }

        // Shows the user stopped watching: excluded from continue/recommendations/new episodes.
        let stopped = StoppedStore.all(userID: userID)

        var result: [Shelf] = []

        // 0. New episodes — from shows I'm watching (not stopped), recently added.
        let newEpisodesCutoff = Int(Date().timeIntervalSince1970) - 21 * 86_400
        var newEpisodeShows: [ShelfItem] = []
        var newEpisodeSort: [String: Int] = [:]
        var seenNewShows = Set<String>()
        let watchedShowKeys: Set<String> = Set(all.filter { item in
            item.type == "show" && states.values.contains { $0.isEpisode && $0.itemID.hasPrefix("ep:\(item.mergeKey):") && $0.viewCount > 0 }
        }.map(\.mergeKey))
        let recentEpisodes: [Episode] = (try? await db.read { dbc in
            try Episode.filter(Column("addedAt") > newEpisodesCutoff).order(Column("addedAt").desc).fetchAll(dbc)
        }) ?? []
        for episode in recentEpisodes {
            guard let showCopy = allByID[episode.showKey],
                  let show = canonicalByMergeKey[showCopy.mergeKey],
                  allowed(show),
                  watchedShowKeys.contains(show.mergeKey), !stopped.contains(show.mergeKey),
                  !seenNewShows.contains(show.mergeKey) else { continue }
            seenNewShows.insert(show.mergeKey)
            newEpisodeShows.append(ShelfItem(media: show, progress: nil, subtitle: "T\(episode.seasonNumber) · E\(episode.episodeNumber)"))
            newEpisodeSort[show.id] = episode.addedAt
        }
        newEpisodeShows.sort { (newEpisodeSort[$0.id] ?? 0) > (newEpisodeSort[$1.id] ?? 0) }

        // Also: episodes that AIRED (TMDB) for followed shows, even when no copy
        // has reached a server yet — the Streaming Mode case. Local entries win.
        for entry in await NewEpisodesEngine.check() where !seenNewShows.contains(entry.media.mergeKey) {
            guard allowed(entry.media), !stopped.contains(entry.media.mergeKey) else { continue }
            seenNewShows.insert(entry.media.mergeKey)
            newEpisodeShows.append(ShelfItem(media: entry.media, progress: nil, subtitle: entry.label))
        }
        if !newEpisodeShows.isEmpty {
            result.append(Shelf(id: "newepisodes", title: tr(L.newEpisodes), style: .landscapeProgress, items: Array(newEpisodeShows.prefix(12))))
        }

        // 1. Continue Watching — landscape with progress (per-user)
        var continueItems: [ShelfItem] = []
        var continueSort: [String: Int] = [:]
        for movie in all where movie.type == "movie" && allowed(movie) {
            guard let state = states[movie.watchKey], state.viewOffsetMs > 0 else { continue }
            let dur = movie.durationMs ?? state.durationMs
            let progress = dur.map { Double(state.viewOffsetMs) / Double(max($0, 1)) }
            continueItems.append(ShelfItem(
                media: movie, progress: progress, subtitle: nil,
                totalMs: dur, remainingMs: dur.map { max(0, $0 - state.viewOffsetMs) }
            ))
            continueSort[movie.id] = state.lastViewedAt
        }
        // Duración por watchKey desde las filas de Episode locales que SÍ tengamos
        // (más rica que la guardada en el estado); las series de otra TV o de Trakt
        // caen al `durationMs` del propio estado.
        var episodeDurByKey: [String: Int] = [:]
        for episode in episodesInProgress {
            guard let showCopy = allByID[episode.showKey],
                  let show = canonicalByMergeKey[showCopy.mergeKey],
                  let dur = episode.durationMs else { continue }
            let key = PlexPlayback.episodeWatchKey(showMergeKey: show.mergeKey, season: episode.seasonNumber, number: episode.episodeNumber)
            episodeDurByKey[key] = dur
        }
        // "Continuar viendo" de episodios derivado DIRECTO de los estados en curso, no
        // del refID — así aparece venga de donde venga (sync iCloud, Trakt, virtual o
        // Plex). El watchKey codifica serie + temporada/episodio: "ep:<mergeKey>:s<S>e<E>".
        let inProgressEpisodes = states.values
            .filter { $0.isEpisode && $0.viewOffsetMs > 0 && $0.finishedAt == nil }
            .sorted { $0.lastViewedAt > $1.lastViewedAt }
        for state in inProgressEpisodes {
            guard let ref = TraktSync.watchedRef(from: state.itemID),
                  let season = ref.season, let number = ref.episode else { continue }
            guard let show = canonicalByMergeKey["tmdb:show:\(ref.tmdbID)"],
                  allowed(show),
                  !stopped.contains(show.mergeKey),
                  !continueItems.contains(where: { $0.id == show.id }) else { continue }
            let dur = episodeDurByKey[state.itemID] ?? state.durationMs
            let progress = dur.map { Double(state.viewOffsetMs) / Double(max($0, 1)) }
            continueItems.append(ShelfItem(
                media: show,
                progress: progress,
                subtitle: "T\(season) · E\(number)",
                totalMs: dur,
                remainingMs: dur.map { max(0, $0 - state.viewOffsetMs) }
            ))
            continueSort[show.id] = state.lastViewedAt
        }
        continueItems.sort { (continueSort[$0.id] ?? 0) > (continueSort[$1.id] ?? 0) }
        if !continueItems.isEmpty {
            result.append(Shelf(id: "continue", title: tr(L.shelfContinue), style: .landscapeProgress, items: Array(continueItems.prefix(30))))
        }

        // Most-recent local items feed the hero fallback. The "Recently added"
        // row was removed; "My list" now lives at the very end (see below).
        let recent = library.sorted { $0.addedAt > $1.addedAt }.prefix(16)

        // 3. Undiscovered gems — cinematic wide (not watched by this user)
        let gems = library
            .filter { ($0.audienceRating ?? 0) >= 7.5 && (states[$0.watchKey]?.viewCount ?? 0) == 0 && $0.viewCount == 0 }
            .sorted { ($0.audienceRating ?? 0) > ($1.audienceRating ?? 0) }
            .prefix(12)
        if !gems.isEmpty {
            result.append(Shelf(id: "gems", title: tr(L.shelfGems), style: .wide, items: gems.map { ShelfItem(media: $0) }))
        }

        // 4. Top 10 — Netflix-style giant number (local library only)
        let top = library
            .filter { $0.audienceRating != nil }
            .sorted { ($0.audienceRating ?? 0) > ($1.audienceRating ?? 0) }
            .prefix(10)
        if top.count >= 4 {
            result.append(Shelf(id: "top10", title: tr(L.shelfTopPicks), style: .numbered, items: top.map { ShelfItem(media: $0) }))
        }

        // 5. For you — taste-based recommender (genres + actors + 👍/👎)
        let forYou = await Recommend.forUser(userID: userID).filter(allowed)
        if forYou.count >= 4 {
            result.append(Shelf(id: "foryou", title: tr(L.forYou), style: .posterLarge, items: forYou.map { ShelfItem(media: $0) }))
        }

        // 6. Because you like {actor} — actor with 3+ titles watched by this user
        if let actorShelf = await Self.favoriteActorShelf(all: library, raw: raw, states: states) {
            result.append(actorShelf)
        }

        // 6. Genre rows — standard posters (local library only)
        var genreCounts: [String: Int] = [:]
        for item in library {
            for genre in item.genres.split(separator: "|") {
                genreCounts[String(genre), default: 0] += 1
            }
        }
        let topGenres = genreCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        // Visual rhythm: alternates sizes per row so it doesn't look monotonous.
        let genreStyles: [ShelfStyle] = [.posterLarge, .poster, .wide, .poster, .posterLarge]
        for (index, genre) in topGenres.enumerated() {
            let items = library
                .filter { $0.genres.contains(genre) }
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(18)
            if items.count >= 5 {
                let style = genreStyles[index % genreStyles.count]
                result.append(Shelf(id: "genre-\(genre)", title: genre, style: style, items: items.map { ShelfItem(media: $0) }))
            }
        }

        // LAST ROW — My list (per-user). Includes TMDB/virtual items added from
        // discover cards or pulled from Trakt, even without a local copy. Missing
        // stubs are fetched once and persisted, so later loads need no network.
        let myListKeys = await MyListStore.mergeKeys(userID: userID)
        var myListItems: [MediaItem] = []
        var myListMissing: [(tmdbID: Int, isShow: Bool)] = []
        for mk in myListKeys {
            if let local = canonicalByMergeKey[mk] {
                myListItems.append(local)
            } else {
                let parts = mk.split(separator: ":")
                if parts.count == 3, parts[0] == "tmdb", let id = Int(parts[2]) {
                    myListMissing.append((id, parts[1] == "show"))
                }
            }
        }
        if !myListMissing.isEmpty, let tmdbKey = SettingsStore.shared.tmdbKey {
            for entry in myListMissing {
                guard let d = await TMDBBrowse.discoverItem(tmdbID: entry.tmdbID, isShow: entry.isShow, key: tmdbKey) else { continue }
                await VirtualLibrary.registerMovie(d)   // persist so next load is local
                myListItems.append(MediaItem.virtualStub(from: d))
            }
        }
        myListItems = ParentalStore.shared.filter(myListItems)
        if !myListItems.isEmpty {
            result.append(Shelf(id: "mylist", title: tr(L.myList), style: .wide, items: myListItems.map { ShelfItem(media: $0) }))
        }

        shelves = result
        if heroItem == nil {
            // Initial hero: the first item from Continue Watching (with its backdrop), or the most recent one.
            if let firstContinue = continueItems.first?.media {
                heroItem = firstContinue
                heroBackdropVisible = true
            } else {
                heroItem = recent.first
            }
        }

        // Discovery rows (TMDB catalog + Trakt community) — cache-first: render
        // the last on-disk snapshot instantly (offline-capable, no network) and
        // only refresh in the background when it's stale or its key changed.
        let fullCatalog = SettingsStore.shared.fullCatalogEnabled
        let cacheKey = DiscoverCache.key(lang: L10n.effectiveLanguage(),
                                         fullCatalog: fullCatalog,
                                         trakt: SettingsStore.shared.traktReady,
                                         parental: ParentalStore.shared.activeLevel ?? -1)
        let now = Date().timeIntervalSince1970
        let cached = await DiscoverCache.shared.load(key: cacheKey)
        if let cached {
            discoverRows = cached.rows
            categories = cached.categories
        }
        let needsRefresh: Bool
        if let cached {
            needsRefresh = await DiscoverCache.shared.isStale(cached, now: now)
        } else {
            needsRefresh = true
        }
        if needsRefresh {
            refreshDiscovery(cacheKey: cacheKey, fullCatalog: fullCatalog)
        }

        // Trakt (si está vinculado): espejo de watchlist → My List, y Continuar
        // viendo en ambos sentidos (Trakt→local solo lo ausente; local→Trakt todo).
        TraktSync.pullWatchlist(userID: userID)
        TraktSync.pullContinueWatching(userID: userID)
        TraktSync.pushAllContinueWatching(userID: userID)
    }

    /// Fetches the discovery rows (TMDB + Trakt) off the main actor, then updates
    /// the UI and the on-disk cache. Kicked from `load()` so the Home shows the
    /// cached snapshot immediately; guarded so overlapping loads don't refetch.
    /// Never clobbers a good cache with an empty result (offline / failure).
    private func refreshDiscovery(cacheKey: String, fullCatalog: Bool) {
        guard !isRefreshingDiscovery else { return }
        isRefreshingDiscovery = true
        loadingDiscovery = true
        Task {
            defer { isRefreshingDiscovery = false; loadingDiscovery = false }
            var rows: [DiscoverRow] = []
            var cats: [DiscoverCategory] = []
            if fullCatalog {
                rows = await TMDBBrowse.discoverRows()
                cats = await TMDBBrowse.movieCategories()
            }
            // Community discovery (Trakt) — prepended once the service is configured.
            let traktRows = await Self.traktDiscoveryRows()
            rows.insert(contentsOf: traktRows, at: 0)

            // Parental first shield: drop titles above the rating (TMDB + Trakt rows).
            var safeRows: [DiscoverRow] = []
            for row in rows {
                let items = await ParentalStore.shared.filterDiscover(row.items)
                if !items.isEmpty { safeRows.append(DiscoverRow(id: row.id, title: row.title, items: items)) }
            }
            rows = safeRows

            guard !rows.isEmpty || !cats.isEmpty else { return }
            discoverRows = rows
            categories = cats
            await DiscoverCache.shared.save(rows: rows, categories: cats,
                                            key: cacheKey, now: Date().timeIntervalSince1970)
        }
    }

    /// Community discovery rows (Trakt), enriched with TMDB art. Shown when the
    /// Trakt service is configured (Client ID) and TMDB is available. Resilient:
    /// if Trakt isn't configured, returns nothing and the TMDB rows stand alone.
    /// `nonisolated` so the network/enrich work runs off the main actor.
    nonisolated private static func traktDiscoveryRows() async -> [DiscoverRow] {
        let cfg = await MainActor.run { () -> (clientID: String, key: String)? in
            guard SettingsStore.shared.traktReady,
                  let clientID = SettingsStore.shared.traktClientID,
                  let key = SettingsStore.shared.tmdbKey else { return nil }
            return (clientID, key)
        }
        guard let cfg else { return [] }
        let clientID = cfg.clientID, key = cfg.key
        async let trending = TraktClient.trending(clientID: clientID, limit: 14)
        async let watched = TraktClient.mostWatched(clientID: clientID, limit: 14)
        async let anticipated = TraktClient.anticipated(clientID: clientID, limit: 14)
        let (tr1, mw, an) = await (trending, watched, anticipated)
        // tr(...) is nonisolated (reads UserDefaults), so titles are safe here.
        var rows: [DiscoverRow] = []
        if let r = await enrichTraktRow(id: "trakt-trending", title: tr(L.communityTrending), refs: tr1, key: key) { rows.append(r) }
        if let r = await enrichTraktRow(id: "trakt-watched", title: tr(L.communityMostWatched), refs: mw, key: key) { rows.append(r) }
        if let r = await enrichTraktRow(id: "trakt-anticipated", title: tr(L.communityAnticipated), refs: an, key: key) { rows.append(r) }
        return rows
    }

    /// Turns Trakt content refs into a DiscoverRow by fetching TMDB art (parallel,
    /// order preserved). `nonisolated` — pure off-main work.
    nonisolated private static func enrichTraktRow(id: String, title: String,
                                                   refs: [TraktRef], key: String) async -> DiscoverRow? {
        guard !refs.isEmpty else { return nil }
        let items = await withTaskGroup(of: (Int, DiscoverItem?).self) { group -> [DiscoverItem] in
            for (i, ref) in refs.enumerated() {
                group.addTask {
                    (i, await TMDBBrowse.discoverItem(tmdbID: ref.tmdbID, isShow: ref.isShow, key: key))
                }
            }
            var byIndex: [Int: DiscoverItem] = [:]
            for await (i, item) in group { if let item { byIndex[i] = item } }
            return refs.indices.compactMap { byIndex[$0] }
        }
        guard !items.isEmpty else { return nil }
        return DiscoverRow(id: id, title: title, items: items)
    }

    /// Favorite actor: 3+ watched titles → row with their pending titles.
    private static func favoriteActorShelf(all: [MediaItem], raw: [MediaItem], states: [String: WatchState]) async -> Shelf? {
        // Content watched by the user (completed movies + shows with watched episodes).
        var watchedMergeKeys = Set<String>()
        for item in all {
            if item.type == "movie", (states[item.watchKey]?.viewCount ?? 0) > 0 {
                watchedMergeKeys.insert(item.mergeKey)
            }
            if item.type == "show" {
                let prefix = "ep:\(item.mergeKey):"
                if states.values.contains(where: { $0.itemID.hasPrefix(prefix) && $0.viewCount > 0 }) {
                    watchedMergeKeys.insert(item.mergeKey)
                }
            }
        }
        guard watchedMergeKeys.count >= 3 else { return nil }

        // IDs of all copies of the watched content, to cross-reference with the cast index.
        let watchedIDs = raw.filter { watchedMergeKeys.contains($0.mergeKey) }.map(\.id)
        let mergeKeyByID = raw.reduce(into: [String: String]()) { $0[$1.id] = $1.mergeKey }

        let entries: [CastEntry] = (try? await AppDatabase.shared.dbQueue.read { db in
            try CastEntry.filter(watchedIDs.contains(Column("itemID"))).fetchAll(db)
        }) ?? []
        guard !entries.isEmpty else { return nil }

        // Count per person over distinct content (not per copy).
        var contentByPerson: [Int: Set<String>] = [:]
        var nameByPerson: [Int: String] = [:]
        for entry in entries {
            guard let mergeKey = mergeKeyByID[entry.itemID] else { continue }
            contentByPerson[entry.personID, default: []].insert(mergeKey)
            nameByPerson[entry.personID] = entry.personName
        }
        guard let (personID, watched) = contentByPerson.max(by: { $0.value.count < $1.value.count }),
              watched.count >= 3, let name = nameByPerson[personID] else { return nil }

        // Their titles in the library that the user hasn't watched yet.
        let personItemIDs: Set<String> = Set(((try? await AppDatabase.shared.dbQueue.read { db in
            try CastEntry.filter(Column("personID") == personID).fetchAll(db)
        }) ?? []).map(\.itemID))

        let pending = all.filter { item in
            !watchedMergeKeys.contains(item.mergeKey)
                && raw.contains { $0.mergeKey == item.mergeKey && personItemIDs.contains($0.id) }
        }
        .sorted { ($0.audienceRating ?? 0) > ($1.audienceRating ?? 0) }
        .prefix(15)

        guard pending.count >= 3 else { return nil }
        return await Shelf(
            id: "actor-\(personID)",
            title: "\(tr(L.becauseYouLike)) \(name)",
            style: .poster,
            items: pending.map { ShelfItem(media: $0) }
        )
    }

    /// Merges copies of the same content (prefers the copy with enriched metadata).
    static func merged(_ items: [MediaItem]) -> [MediaItem] {
        var byKey: [String: MediaItem] = [:]
        for item in items {
            if let existing = byKey[item.mergeKey] {
                let existingScore = (existing.logoURL != nil ? 1 : 0) + (existing.tmdbTitle != nil ? 1 : 0)
                let newScore = (item.logoURL != nil ? 1 : 0) + (item.tmdbTitle != nil ? 1 : 0)
                if newScore > existingScore { byKey[item.mergeKey] = item }
            } else {
                byKey[item.mergeKey] = item
            }
        }
        return Array(byKey.values)
    }

    /// The focus id is composite: "{shelfID}|{itemID}".
    func focusChanged(to focusKey: String?) {
        let parts = (focusKey ?? "").split(separator: "|", maxSplits: 1)
        let fromContinue = parts.first.map(String.init) == "continue"

        // Outside "Continue Watching" (another row, discover rows, or lost focus):
        // hides the backdrop immediately so it doesn't stay static.
        guard fromContinue else {
            heroDebounce?.cancel()
            heroBackdropVisible = false
            if parts.count == 2, let item = itemsByID[String(parts[1])] {
                heroItem = item
            }
            return
        }

        guard parts.count == 2, let item = itemsByID[String(parts[1])] else { return }
        heroDebounce?.cancel()
        heroDebounce = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            heroItem = item
            heroBackdropVisible = true
        }
    }
}
