import Foundation
import GRDB

/// Persists virtual content (TMDB catalog / Streaming Mode) in the local DB when played,
/// so it shows up in "Continue watching" and Recently added and keeps statistics
/// just like the Plex library. The rest of the app treats it as just another item.
@MainActor
enum VirtualLibrary {

    /// Stable identifier for the virtual show/movie (matches MediaItem.virtualStub).
    static func contentID(tmdbID: Int, isShow: Bool) -> String {
        "tmdb:\(isShow ? "tv" : "movie"):\(tmdbID)"
    }

    static func episodeID(tmdbID: Int, season: Int, number: Int) -> String {
        "\(contentID(tmdbID: tmdbID, isShow: true)):s\(season)e\(number)"
    }

    /// Registers a virtual movie (insert-or-ignore; does not overwrite an existing
    /// copy). `certification` (TMDB age rating) is stored so parental filtering can
    /// evaluate it — without it, a restricted (kids) profile hides the item even when
    /// it's age-appropriate. If the copy already exists without a rating, backfills it.
    static func registerMovie(_ item: DiscoverItem, certification: String? = nil) async {
        var stub = MediaItem.virtualStub(from: item)
        stub.contentRating = certification
        let media = stub   // inmutable para la clausura concurrente del write
        try? await AppDatabase.shared.dbQueue.write { db in
            if try MediaItem.filter(Column("id") == media.id).fetchCount(db) == 0 {
                var m = media
                m.addedAt = Int(Date().timeIntervalSince1970)
                try m.insert(db)
            } else if let certification, !certification.isEmpty {
                try db.execute(
                    sql: "UPDATE mediaItem SET contentRating = ? WHERE id = ? AND (contentRating IS NULL OR contentRating = '')",
                    arguments: [certification, media.id])
            }
        }
        SyncStatus.shared.generation += 1
    }

    /// Registers a virtual show and the played episode (to map "Continue watching").
    /// `certification` (the show's TMDB age rating) is stored on the show stub so a
    /// restricted (kids) profile doesn't hide the episode for lacking a rating.
    static func registerEpisode(show: DiscoverItem, episode: TMDBBrowse.DiscoverEpisode, certification: String? = nil) async {
        var showStub = MediaItem.virtualStub(from: show)
        showStub.contentRating = certification
        let showMedia = showStub   // inmutable para la clausura concurrente del write
        let epID = episodeID(tmdbID: show.tmdbID, season: episode.seasonNumber, number: episode.episodeNumber)
        let now = Int(Date().timeIntervalSince1970)
        let ep = Episode(
            id: epID,
            serverID: "",
            ratingKey: epID,
            showKey: showMedia.id,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.name,
            durationMs: nil,
            viewOffsetMs: 0,
            viewCount: 0,
            lastViewedAt: nil,
            addedAt: now,
            thumbPath: nil
        )
        try? await AppDatabase.shared.dbQueue.write { db in
            if try MediaItem.filter(Column("id") == showMedia.id).fetchCount(db) == 0 {
                var m = showMedia
                m.addedAt = now
                try m.insert(db)
            } else if let certification, !certification.isEmpty {
                try db.execute(
                    sql: "UPDATE mediaItem SET contentRating = ? WHERE id = ? AND (contentRating IS NULL OR contentRating = '')",
                    arguments: [certification, showMedia.id])
            }
            // The episode: insert-or-ignore (does not clobber progress if it already exists).
            if try Episode.filter(Column("id") == epID).fetchCount(db) == 0 {
                try ep.insert(db)
            }
        }
        SyncStatus.shared.generation += 1
    }

    /// Saved resume offset for a watchKey (0 if none).
    static func resumeOffset(watchKey: String) async -> Int {
        let userID = UserContext.currentUserID
        let states = await WatchStore.states(userID: userID)
        return states[watchKey]?.viewOffsetMs ?? 0
    }
}
