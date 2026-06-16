import Foundation
import GRDB
import CryptoKit

struct MediaItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "mediaItem"

    var id: String          // "{serverID}:{ratingKey}"
    var serverID: String
    var ratingKey: String   // raw ratingKey on its server
    var libraryKey: String
    var type: String        // "movie" | "show"
    var title: String
    var sortTitle: String
    var year: Int?
    var summary: String
    var durationMs: Int?
    var addedAt: Int
    var updatedAt: Int
    var viewCount: Int
    var viewOffsetMs: Int
    var lastViewedAt: Int?
    var audienceRating: Double?
    var contentRating: String?
    var genres: String      // separated by "|"
    var tmdbID: Int?
    var thumbPath: String?  // poster (Plex)
    var artPath: String?    // backdrop (Plex)
    var logoURL: String?    // logo PNG (TMDB)
    var videoResolution: String?
    var audioCodec: String?
    var audioChannels: Int?
    var leafCount: Int?
    var viewedLeafCount: Int?
    // Localized metadata (TMDB) in the user's language.
    var tmdbTitle: String?
    var tmdbSummary: String?
    var tmdbPosterPath: String?
    var tmdbBackdropPath: String?
    var metaLang: String?
    // Origin (TMDB) used to classify anime / doramas.
    var originalLanguage: String?   // "ja", "ko", "zh"…
    var originCountry: String?      // "JP", "KR,CN"…

    var displayTitle: String { tmdbTitle ?? title }
    var displaySummary: String { tmdbSummary ?? summary }

    /// Content identity across servers: same TMDB ID = same movie/show.
    var mergeKey: String {
        if let tmdbID { return "tmdb:\(type):\(tmdbID)" }
        // No TMDB match: hash the title so the plaintext content name is NEVER
        // persisted locally nor synced to CloudKit. Deterministic, so cross-server
        // and cross-device matching is preserved.
        return "t:\(type):\(Self.titleHash(title)):\(year ?? 0)"
    }

    /// Short SHA-256 (16 hex) of the lowercased title — opaque, collision-safe enough.
    static func titleHash(_ title: String) -> String {
        SHA256.hash(data: Data(title.lowercased().utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Progress key per content (not per copy).
    var watchKey: String { mergeKey }

    /// Catalog segment: anime (Japanese animation), dorama (live-action Asian
    /// series), or the base type. Requires TMDB enrichment to detect.
    var classification: CatalogKind {
        let g = genres.lowercased()
        let isAnimation = g.contains("anim")
        let isDoc = g.contains("documental") || g.contains("documentary")
        let lang = originalLanguage ?? ""
        let country = (originCountry ?? "").uppercased()
        let asian = ["KR", "CN", "TW", "HK", "TH", "JP"]

        if isAnimation && (lang == "ja" || country.contains("JP")) { return .anime }
        if isDoc { return .documentary }
        if type == "show" {
            if asian.contains(where: { country.contains($0) }) || ["ko", "zh", "ja", "th"].contains(lang) {
                return .dorama
            }
            return .series
        }
        return .movie
    }
}

enum CatalogKind: String {
    case movie, series, anime, dorama, documentary
}

struct Episode: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "episode"

    var id: String          // "{serverID}:{ratingKey}"
    var serverID: String
    var ratingKey: String
    var showKey: String     // "{serverID}:{showRatingKey}"
    var seasonNumber: Int
    var episodeNumber: Int
    var title: String
    var durationMs: Int?
    var viewOffsetMs: Int
    var viewCount: Int
    var lastViewedAt: Int?
    var addedAt: Int
    var thumbPath: String?
}

/// Cast member of an item, indexed locally from TMDB.
struct CastEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "castEntry"

    var itemID: String
    var personID: Int
    var personName: String
}

final class AppDatabase: Sendable {
    static let shared = makeShared()

    let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    private static func makeShared() -> AppDatabase {
        do {
            // tvOS: guaranteed persistent storage is minimal; we use Caches.
            // If the system purges the DB, the sync rebuilds it automatically.
            let dir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("lumoratv.sqlite").path)
            try migrator.migrate(dbQueue)
            return AppDatabase(dbQueue: dbQueue)
        } catch {
            fatalError("Could not open the database: \(error)")
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "mediaItem") { t in
                t.primaryKey("id", .text)
                t.column("libraryKey", .text).notNull()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("sortTitle", .text).notNull()
                t.column("year", .integer)
                t.column("summary", .text).notNull()
                t.column("durationMs", .integer)
                t.column("addedAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("viewCount", .integer).notNull()
                t.column("viewOffsetMs", .integer).notNull()
                t.column("lastViewedAt", .integer)
                t.column("audienceRating", .double)
                t.column("contentRating", .text)
                t.column("genres", .text).notNull()
                t.column("tmdbID", .integer)
                t.column("thumbPath", .text)
                t.column("artPath", .text)
                t.column("logoURL", .text)
                t.column("videoResolution", .text)
                t.column("audioCodec", .text)
                t.column("audioChannels", .integer)
                t.column("leafCount", .integer)
                t.column("viewedLeafCount", .integer)
            }
            try db.create(indexOn: "mediaItem", columns: ["type"])
            try db.create(indexOn: "mediaItem", columns: ["addedAt"])
            try db.create(indexOn: "mediaItem", columns: ["lastViewedAt"])

            try db.create(table: "episode") { t in
                t.primaryKey("id", .text)
                t.column("showKey", .text).notNull()
                t.column("seasonNumber", .integer).notNull()
                t.column("episodeNumber", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("durationMs", .integer)
                t.column("viewOffsetMs", .integer).notNull()
                t.column("viewCount", .integer).notNull()
                t.column("lastViewedAt", .integer)
                t.column("addedAt", .integer).notNull()
                t.column("thumbPath", .text)
            }
            try db.create(indexOn: "episode", columns: ["showKey"])
            try db.create(indexOn: "episode", columns: ["lastViewedAt"])
        }
        migrator.registerMigration("v2-localized-meta") { db in
            try db.alter(table: "mediaItem") { t in
                t.add(column: "tmdbTitle", .text)
                t.add(column: "tmdbSummary", .text)
                t.add(column: "tmdbPosterPath", .text)
                t.add(column: "metaLang", .text)
            }
        }
        migrator.registerMigration("v3-watch-state") { db in
            try db.create(table: "watchState") { t in
                t.column("userID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("isEpisode", .boolean).notNull()
                t.column("viewOffsetMs", .integer).notNull()
                t.column("viewCount", .integer).notNull()
                t.column("lastViewedAt", .integer).notNull()
                t.primaryKey(["userID", "itemID"])
            }
            try db.create(indexOn: "watchState", columns: ["userID", "lastViewedAt"])
        }
        // Multi-server: IDs prefixed per server and watchState keyed by content identity.
        // Clean recreation: the catalog is rebuilt on the next sync.
        migrator.registerMigration("v4-multi-server") { db in
            try db.drop(table: "mediaItem")
            try db.drop(table: "episode")
            try db.drop(table: "watchState")

            try db.create(table: "mediaItem") { t in
                t.primaryKey("id", .text)
                t.column("serverID", .text).notNull()
                t.column("ratingKey", .text).notNull()
                t.column("libraryKey", .text).notNull()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("sortTitle", .text).notNull()
                t.column("year", .integer)
                t.column("summary", .text).notNull()
                t.column("durationMs", .integer)
                t.column("addedAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("viewCount", .integer).notNull()
                t.column("viewOffsetMs", .integer).notNull()
                t.column("lastViewedAt", .integer)
                t.column("audienceRating", .double)
                t.column("contentRating", .text)
                t.column("genres", .text).notNull()
                t.column("tmdbID", .integer)
                t.column("thumbPath", .text)
                t.column("artPath", .text)
                t.column("logoURL", .text)
                t.column("videoResolution", .text)
                t.column("audioCodec", .text)
                t.column("audioChannels", .integer)
                t.column("leafCount", .integer)
                t.column("viewedLeafCount", .integer)
                t.column("tmdbTitle", .text)
                t.column("tmdbSummary", .text)
                t.column("tmdbPosterPath", .text)
                t.column("metaLang", .text)
            }
            try db.create(indexOn: "mediaItem", columns: ["type"])
            try db.create(indexOn: "mediaItem", columns: ["addedAt"])
            try db.create(indexOn: "mediaItem", columns: ["tmdbID"])

            try db.create(table: "episode") { t in
                t.primaryKey("id", .text)
                t.column("serverID", .text).notNull()
                t.column("ratingKey", .text).notNull()
                t.column("showKey", .text).notNull()
                t.column("seasonNumber", .integer).notNull()
                t.column("episodeNumber", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("durationMs", .integer)
                t.column("viewOffsetMs", .integer).notNull()
                t.column("viewCount", .integer).notNull()
                t.column("lastViewedAt", .integer)
                t.column("addedAt", .integer).notNull()
                t.column("thumbPath", .text)
            }
            try db.create(indexOn: "episode", columns: ["showKey"])

            try db.create(table: "watchState") { t in
                t.column("userID", .text).notNull()
                t.column("itemID", .text).notNull()    // watchKey per content
                t.column("isEpisode", .boolean).notNull()
                t.column("refID", .text)               // concrete row that was played (to map back)
                t.column("viewOffsetMs", .integer).notNull()
                t.column("viewCount", .integer).notNull()
                t.column("lastViewedAt", .integer).notNull()
                t.primaryKey(["userID", "itemID"])
            }
            try db.create(indexOn: "watchState", columns: ["userID", "lastViewedAt"])
        }
        // Locally indexed cast: enables "Because you like {actor}" and per-person searches.
        migrator.registerMigration("v5-cast-index") { db in
            try db.create(table: "castEntry") { t in
                t.column("itemID", .text).notNull()
                t.column("personID", .integer).notNull()
                t.column("personName", .text).notNull()
                t.primaryKey(["itemID", "personID"])
            }
            try db.create(indexOn: "castEntry", columns: ["personID"])
        }
        // My list: per user and per content identity (mergeKey).
        migrator.registerMigration("v6-my-list") { db in
            try db.create(table: "myList") { t in
                t.column("userID", .text).notNull()
                t.column("itemID", .text).notNull()   // mergeKey
                t.column("addedAt", .integer).notNull()
                t.primaryKey(["userID", "itemID"])
            }
            try db.create(indexOn: "myList", columns: ["userID", "addedAt"])
        }
        // Finish date: tracks when each piece of content was watched.
        migrator.registerMigration("v7-finished-at") { db in
            try db.alter(table: "watchState") { t in
                t.add(column: "finishedAt", .integer)
            }
        }
        // Liked / disliked: per user and content, foundation of the recommender.
        migrator.registerMigration("v8-user-rating") { db in
            try db.create(table: "userRating") { t in
                t.column("userID", .text).notNull()
                t.column("itemID", .text).notNull()   // mergeKey
                t.column("liked", .boolean).notNull()
                t.column("ratedAt", .integer).notNull()
                t.primaryKey(["userID", "itemID"])
            }
        }
        // Origin used to classify anime / doramas.
        migrator.registerMigration("v9-origin") { db in
            try db.alter(table: "mediaItem") { t in
                t.add(column: "originalLanguage", .text)
                t.add(column: "originCountry", .text)
            }
        }
        // TMDB backdrop: background for items without a server (TMDB virtual catalog).
        migrator.registerMigration("v10-tmdb-backdrop") { db in
            try db.alter(table: "mediaItem") { t in
                t.add(column: "tmdbBackdropPath", .text)
            }
        }
        // Played duration: for the progress bar of content without local metadata (torrents).
        migrator.registerMigration("v11-watch-duration") { db in
            try db.alter(table: "watchState") { t in
                t.add(column: "durationMs", .integer)
            }
        }
        return migrator
    }

    func isEmpty() async -> Bool {
        (try? await dbQueue.read { db in
            try MediaItem.fetchCount(db) == 0
        }) ?? true
    }
}
