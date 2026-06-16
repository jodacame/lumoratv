import Foundation
import GRDB

/// Entrada de "Mi lista", por usuario de Apple TV y por identidad de contenido.
struct MyListEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "myList"

    var userID: String
    var itemID: String   // mergeKey
    var addedAt: Int
}

enum MyListStore {

    static func contains(userID: String, mergeKey: String) async -> Bool {
        ((try? await AppDatabase.shared.dbQueue.read { db in
            try MyListEntry
                .filter(Column("userID") == userID && Column("itemID") == mergeKey)
                .fetchCount(db)
        }) ?? 0) > 0
    }

    /// Adds or removes. Returns true if it ended up IN the list.
    @discardableResult
    static func toggle(userID: String, mergeKey: String) async -> Bool {
        let nowInList = (try? await AppDatabase.shared.dbQueue.write { db -> Bool in
            let existing = try MyListEntry
                .filter(Column("userID") == userID && Column("itemID") == mergeKey)
                .fetchOne(db)
            if let existing {
                try existing.delete(db)
                return false
            }
            try MyListEntry(
                userID: userID,
                itemID: mergeKey,
                addedAt: Int(Date().timeIntervalSince1970)
            ).save(db)
            return true
        }) ?? false
        await MainActor.run {
            SyncStatus.shared.generation += 1
            SyncCoordinator.shared.enqueue(.myList(userID: userID, itemID: mergeKey))
            // Mirror to the user's Trakt watchlist, if linked (no-op otherwise).
            TraktSync.setWatchlist(userID: userID, mergeKey: mergeKey, inList: nowInList)
        }
        return nowInList
    }

    /// Adds an item that came FROM Trakt (watchlist pull). Idempotent; does not
    /// push back to Trakt (avoids an echo loop). Syncs to CloudKit like a local add.
    static func addFromRemote(userID: String, mergeKey: String) async {
        let added = (try? await AppDatabase.shared.dbQueue.write { db -> Bool in
            let exists = try MyListEntry
                .filter(Column("userID") == userID && Column("itemID") == mergeKey)
                .fetchCount(db) > 0
            guard !exists else { return false }
            try MyListEntry(userID: userID, itemID: mergeKey,
                            addedAt: Int(Date().timeIntervalSince1970)).save(db)
            return true
        }) ?? false
        if added {
            await MainActor.run {
                SyncStatus.shared.generation += 1
                SyncCoordinator.shared.enqueue(.myList(userID: userID, itemID: mergeKey))
            }
        }
    }

    /// The user's mergeKeys, most recent first.
    static func mergeKeys(userID: String) async -> [String] {
        (try? await AppDatabase.shared.dbQueue.read { db in
            try MyListEntry
                .filter(Column("userID") == userID)
                .order(Column("addedAt").desc)
                .fetchAll(db)
                .map(\.itemID)
        }) ?? []
    }
}
