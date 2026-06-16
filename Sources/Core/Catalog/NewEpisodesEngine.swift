import Foundation
import GRDB

/// Detects shows the user follows (My List + watch history) that aired an
/// episode they haven't watched yet, within a recent window. Powers the
/// "New Episodes" Home row. TMDB responses go through the shared HTTP cache,
/// so a Home reload doesn't hammer the API.
enum NewEpisodesEngine {

    struct Entry: Sendable {
        let media: MediaItem
        let label: String      // "NEW · S2 E5"
    }

    /// How far back an aired episode still counts as "new".
    private static let windowDays = 31
    /// Request cap per check (followed shows beyond this are skipped).
    private static let maxShows = 25

    @MainActor
    static func check() async -> [Entry] {
        guard let key = SettingsStore.shared.tmdbKey else { return [] }
        let userID = UserContext.currentUserID
        let states = await WatchStore.states(userID: userID)
        let stopped = StoppedStore.all(userID: userID)

        // Followed shows: My List + anything with episode activity, minus stopped.
        var showKeys: Set<String> = []
        for mergeKey in await MyListStore.mergeKeys(userID: userID) where mergeKey.hasPrefix("tmdb:show:") {
            showKeys.insert(mergeKey)
        }
        for itemID in states.keys where itemID.hasPrefix("ep:tmdb:show:") {
            // "ep:tmdb:show:123:s2e5" → "tmdb:show:123"
            let parts = itemID.split(separator: ":")
            if parts.count >= 4 { showKeys.insert("tmdb:show:\(parts[3])") }
        }
        showKeys.subtract(stopped)
        guard !showKeys.isEmpty else { return [] }

        // Cutoff date for the "recent" window.
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()

        // Latest aired episode per show, in parallel (HTTP-cached).
        let candidates = Array(showKeys.prefix(maxShows)).compactMap { key -> Int? in
            Int(key.split(separator: ":").last ?? "")
        }
        let statuses = await withTaskGroup(of: (Int, TMDBBrowse.ShowAirStatus?).self) { group -> [(Int, TMDBBrowse.ShowAirStatus)] in
            for tmdbID in candidates {
                group.addTask { (tmdbID, await TMDBBrowse.showAirStatus(tmdbID: tmdbID, key: key)) }
            }
            var out: [(Int, TMDBBrowse.ShowAirStatus)] = []
            for await (id, status) in group {
                if let status { out.append((id, status)) }
            }
            return out
        }

        // Keep shows whose latest episode is recent AND unwatched.
        var fresh: [(TMDBBrowse.ShowAirStatus, Date)] = []
        for (tmdbID, status) in statuses {
            guard let aired = formatter.date(from: status.lastAirDate), aired >= cutoff else { continue }
            let (ws, we) = highestWatched(states: states, tmdbID: tmdbID)
            if (status.lastSeason, status.lastEpisode) > (ws, we) {
                fresh.append((status, aired))
            }
        }
        guard !fresh.isEmpty else { return [] }
        fresh.sort { $0.1 > $1.1 }   // most recent first

        // Map to local copies when they exist; virtual stubs otherwise.
        let ids = fresh.map(\.0.item.tmdbID)
        let locals = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(ids.contains(Column("tmdbID")) && Column("type") == "show").fetchAll(db)
        }) ?? []
        let localByTmdb = Dictionary(locals.compactMap { item -> (Int, MediaItem)? in
            item.tmdbID.map { ($0, item) }
        }, uniquingKeysWith: { a, _ in a })

        let catalogBrowse = SettingsStore.shared.fullCatalogEnabled
        let entries: [Entry] = fresh.compactMap { status, _ in
            let media: MediaItem
            if let local = localByTmdb[status.item.tmdbID] {
                media = local
            } else if catalogBrowse {
                media = MediaItem.virtualStub(from: status.item)
            } else {
                return nil
            }
            return Entry(media: media, label: trf(L.newEpisodeLabel, status.lastSeason, status.lastEpisode))
        }
        return ParentalStore.shared.filter(entries.map(\.media)).compactMap { allowed in
            entries.first { $0.media.id == allowed.id }
        }
    }

    /// Highest episode of the show the user has fully watched.
    private static func highestWatched(states: [String: WatchState], tmdbID: Int) -> (Int, Int) {
        var best = (0, 0)
        let prefix = "ep:tmdb:show:\(tmdbID):s"
        for (itemID, state) in states where state.viewCount > 0 && itemID.hasPrefix(prefix) {
            // suffix "s{S}e{E}"
            let tail = itemID.dropFirst(prefix.count)   // "{S}e{E}"
            let comps = tail.split(separator: "e")
            guard comps.count == 2, let s = Int(comps[0]), let e = Int(comps[1]) else { continue }
            if (s, e) > best { best = (s, e) }
        }
        return best
    }
}
