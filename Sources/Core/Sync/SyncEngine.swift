import Foundation
import GRDB

@MainActor
final class SyncStatus: ObservableObject {
    static let shared = SyncStatus()

    enum Phase: Equatable {
        case idle
        case syncing(detail: String)
        case failed
    }

    @Published var phase: Phase = .idle
    @Published var lastSyncAt: Date? = UserDefaults.standard.object(forKey: "lastSyncAt") as? Date
    /// Incremented at the end of each sync so views reload.
    @Published var generation = 0

    func markSynced() {
        lastSyncAt = Date()
        UserDefaults.standard.set(lastSyncAt, forKey: "lastSyncAt")
        generation += 1
        phase = .idle
    }
}

actor SyncEngine {
    static let shared = SyncEngine()

    private var running = false

    func sync() async {
        guard !running else { return }
        running = true
        defer { running = false }

        let serverList = await MainActor.run { () -> [(PlexServerRef, String)] in
            let s = SettingsStore.shared
            return s.servers.compactMap { server in
                guard let token = s.token(forServer: server.id) else { return nil }
                return (server, token)
            }
        }
        guard !serverList.isEmpty else { return }

        let db = AppDatabase.shared.dbQueue
        var anySuccess = false

        // Enriched metadata (logos, localized titles): preserved across the re-sync.
        let preservedMap: [String: PreservedMeta] = (try? await db.read { dbc in
            try MediaItem.fetchAll(dbc).reduce(into: [:]) {
                $0[$1.id] = PreservedMeta(
                    logoURL: $1.logoURL,
                    tmdbTitle: $1.tmdbTitle,
                    tmdbSummary: $1.tmdbSummary,
                    tmdbPosterPath: $1.tmdbPosterPath,
                    metaLang: $1.metaLang,
                    originalLanguage: $1.originalLanguage,
                    originCountry: $1.originCountry
                )
            }
        }) ?? [:]

        for (server, token) in serverList {
            do {
                let baseURL = server.url
                let serverID = server.id
                let now = Int(Date().timeIntervalSince1970)
                let lastFull = UserDefaults.standard.integer(forKey: "lastFullSync-\(serverID)")
                let lastInc = UserDefaults.standard.integer(forKey: "lastIncSync-\(serverID)")
                // Full every 24h (reconciles deletions); incremental otherwise (changes only).
                let needFull = lastFull == 0 || now - lastFull > 86_400

                let libraries = try await PlexClient.libraries(baseURL: baseURL, token: token)
                var fetchedItemIDs = Set<String>()
                var fetchedEpisodeIDs = Set<String>()

                for library in libraries where library.type == "movie" || library.type == "show" {
                    await MainActor.run {
                        SyncStatus.shared.phase = .syncing(detail: "\(server.name) · \(library.title)")
                    }
                    let since = max(lastInc - 300, 1)  // 5 min of safety overlap

                    if library.type == "movie" {
                        let metas = needFull
                            ? try await PlexClient.fetchSectionItems(baseURL: baseURL, token: token, sectionKey: library.key, type: 1)
                            : try await PlexClient.fetchSectionItemsUpdatedSince(baseURL: baseURL, token: token, sectionKey: library.key, type: 1, since: since)
                        let items = metas.map { MediaItem(meta: $0, serverID: serverID, libraryKey: library.key, type: "movie", preserved: preservedMap["\(serverID):\($0.ratingKey)"]) }
                        fetchedItemIDs.formUnion(items.map(\.id))
                        try await db.write { dbc in
                            for item in items { try item.save(dbc) }
                        }
                    } else {
                        let showMetas = needFull
                            ? try await PlexClient.fetchSectionItems(baseURL: baseURL, token: token, sectionKey: library.key, type: 2)
                            : try await PlexClient.fetchSectionItemsUpdatedSince(baseURL: baseURL, token: token, sectionKey: library.key, type: 2, since: since)
                        let shows = showMetas.map { MediaItem(meta: $0, serverID: serverID, libraryKey: library.key, type: "show", preserved: preservedMap["\(serverID):\($0.ratingKey)"]) }
                        let episodeMetas = needFull
                            ? try await PlexClient.fetchSectionItems(baseURL: baseURL, token: token, sectionKey: library.key, type: 4)
                            : try await PlexClient.fetchSectionItemsUpdatedSince(baseURL: baseURL, token: token, sectionKey: library.key, type: 4, since: since)
                        let episodes = episodeMetas.compactMap { Episode(meta: $0, serverID: serverID) }
                        fetchedItemIDs.formUnion(shows.map(\.id))
                        fetchedEpisodeIDs.formUnion(episodes.map(\.id))
                        try await db.write { dbc in
                            for show in shows { try show.save(dbc) }
                            for episode in episodes { try episode.save(dbc) }
                        }
                    }
                }

                // Full: remove what no longer exists on the server.
                if needFull {
                    let itemIDs = fetchedItemIDs
                    let episodeIDs = fetchedEpisodeIDs
                    try await db.write { dbc in
                        let existingItems = try String.fetchAll(dbc, sql: "SELECT id FROM mediaItem WHERE serverID = ?", arguments: [serverID])
                        for chunk in existingItems.filter({ !itemIDs.contains($0) }).chunked(into: 400) {
                            try MediaItem.filter(chunk.contains(Column("id"))).deleteAll(dbc)
                        }
                        let existingEpisodes = try String.fetchAll(dbc, sql: "SELECT id FROM episode WHERE serverID = ?", arguments: [serverID])
                        for chunk in existingEpisodes.filter({ !episodeIDs.contains($0) }).chunked(into: 400) {
                            try Episode.filter(chunk.contains(Column("id"))).deleteAll(dbc)
                        }
                    }
                    UserDefaults.standard.set(now, forKey: "lastFullSync-\(serverID)")
                }
                UserDefaults.standard.set(now, forKey: "lastIncSync-\(serverID)")
                anySuccess = true
            } catch {
                // A down server does not block the rest of the catalog.
                continue
            }
        }

        if anySuccess {
            await MainActor.run { SyncStatus.shared.markSynced() }
            // TMDB enrichment in the background (does not block the UI).
            Task { await TMDBEnricher.shared.enrichAll() }
        } else {
            await MainActor.run { SyncStatus.shared.phase = .failed }
        }
    }
}
