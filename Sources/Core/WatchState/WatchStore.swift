import Foundation
import GRDB

/// Identidad de la persona activa = el **perfil propio de la app** seleccionado
/// (ver `ProfileStore`). Es la clave de TODOS los datos per-persona (historial,
/// continuar viendo, Mi Lista, parental, Trakt…) y de la sincronización iCloud.
///
/// Ya NO depende del multiusuario de tvOS (`TVUserManager`/`runs-as-current-user`),
/// que no aísla cuentas de menores ni expone un id de perfil utilizable. LumoraTV
/// gestiona sus perfiles y los sincroniza por iCloud keyados por su UUID.
enum UserContext {
    /// Identidad bajo la que vivían los datos en builds antiguos (antes de perfiles).
    static let legacyID = "shared"

    @MainActor
    static var currentUserID: String { ProfileStore.shared.selectedID }
}

/// Estado de visionado por usuario, por identidad de contenido (cruza servidores).
struct WatchState: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "watchState"

    var userID: String
    var itemID: String      // watchKey: "tmdb:movie:603" / "ep:tmdb:show:1399:s2e4"
    var isEpisode: Bool
    var refID: String?      // fila concreta reproducida (mapeo de vuelta a Episode/MediaItem)
    var viewOffsetMs: Int
    var viewCount: Int
    var lastViewedAt: Int
    var finishedAt: Int?    // when it finished playing (epoch)
    var durationMs: Int?    // played duration (for torrent progress without local metadata)
}

enum WatchStore {

    /// Todos los estados del usuario, indexados por watchKey.
    static func states(userID: String) async -> [String: WatchState] {
        (try? await AppDatabase.shared.dbQueue.read { db in
            try WatchState
                .filter(Column("userID") == userID)
                .fetchAll(db)
                .reduce(into: [:]) { $0[$1.itemID] = $1 }
        }) ?? [:]
    }

    /// Actualiza el progreso tras reproducir. >95% = completado.
    static func update(userID: String, watchKey: String, refID: String, isEpisode: Bool, timeMs: Int, durationMs: Int) async {
        let now = Int(Date().timeIntervalSince1970)
        let finished = durationMs > 0 && Double(timeMs) / Double(durationMs) > 0.95

        try? await AppDatabase.shared.dbQueue.write { db in
            var state = try WatchState
                .filter(Column("userID") == userID && Column("itemID") == watchKey)
                .fetchOne(db)
                ?? WatchState(userID: userID, itemID: watchKey, isEpisode: isEpisode, refID: refID, viewOffsetMs: 0, viewCount: 0, lastViewedAt: now, finishedAt: nil)

            state.refID = refID
            state.viewOffsetMs = finished ? 0 : max(timeMs, 0)
            if durationMs > 0 { state.durationMs = durationMs }
            if finished {
                state.viewCount += 1
                state.finishedAt = now
            }
            state.lastViewedAt = now
            try state.save(db)
        }
        await MainActor.run {
            SyncCoordinator.shared.enqueue(.watchState(userID: userID, itemID: watchKey))
            // Natural "watched" on Trakt is handled by scrobble stop (≥80%); the
            // manual toggles below use setWatched. No call here avoids duplicates.
        }
    }

    /// Agrega una entrada de "Continuar viendo" traída de Trakt — SOLO si no existe
    /// localmente (prioridad local: nunca pisa el progreso propio). Duración
    /// aproximada por tipo para que la barra refleje el % de Trakt.
    static func addFromTrakt(userID: String, watchKey: String, isEpisode: Bool, progress: Double, pausedAt: Int) async {
        let duration = isEpisode ? 2_700_000 : 7_200_000   // ~45min / ~2h
        let offset = Int(Double(duration) * max(1, min(95, progress)) / 100.0)
        let when = pausedAt > 0 ? pausedAt : Int(Date().timeIntervalSince1970)
        try? await AppDatabase.shared.dbQueue.write { db in
            let exists = try WatchState
                .filter(Column("userID") == userID && Column("itemID") == watchKey)
                .fetchCount(db) > 0
            guard !exists else { return }
            try WatchState(userID: userID, itemID: watchKey, isEpisode: isEpisode, refID: nil,
                           viewOffsetMs: offset, viewCount: 0, lastViewedAt: when, finishedAt: nil,
                           durationMs: duration).save(db)
        }
        await MainActor.run { SyncCoordinator.shared.enqueue(.watchState(userID: userID, itemID: watchKey)) }
    }

    /// Quita un contenido de "Continuar viendo" (resetea el offset, conserva el historial).
    static func clearProgress(userID: String, item: MediaItem) async {
        let affected: [String] = (try? await AppDatabase.shared.dbQueue.write { db -> [String] in
            if item.type == "movie" {
                try db.execute(
                    sql: "UPDATE watchState SET viewOffsetMs = 0 WHERE userID = ? AND itemID = ?",
                    arguments: [userID, item.watchKey]
                )
                return [item.watchKey]
            } else {
                let keys = try String.fetchAll(
                    db,
                    sql: "SELECT itemID FROM watchState WHERE userID = ? AND itemID LIKE ?",
                    arguments: [userID, "ep:\(item.mergeKey):%"]
                )
                try db.execute(
                    sql: "UPDATE watchState SET viewOffsetMs = 0 WHERE userID = ? AND itemID LIKE ?",
                    arguments: [userID, "ep:\(item.mergeKey):%"]
                )
                return keys
            }
        }) ?? []
        await MainActor.run {
            SyncStatus.shared.generation += 1
            for key in affected {
                SyncCoordinator.shared.enqueue(.watchState(userID: userID, itemID: key))
            }
        }
    }

    /// Marks/unmarks a movie as watched (manual record).
    static func setWatched(_ watched: Bool, userID: String, item: MediaItem) async {
        let now = Int(Date().timeIntervalSince1970)
        try? await AppDatabase.shared.dbQueue.write { db in
            var state = try WatchState
                .filter(Column("userID") == userID && Column("itemID") == item.watchKey)
                .fetchOne(db)
                ?? WatchState(userID: userID, itemID: item.watchKey, isEpisode: false, refID: item.id, viewOffsetMs: 0, viewCount: 0, lastViewedAt: now, finishedAt: nil)
            state.viewOffsetMs = 0
            state.viewCount = watched ? max(state.viewCount, 1) : 0
            state.finishedAt = watched ? now : nil
            state.lastViewedAt = now
            try state.save(db)
        }
        await MainActor.run {
            SyncStatus.shared.generation += 1
            SyncCoordinator.shared.enqueue(.watchState(userID: userID, itemID: item.watchKey))
            TraktSync.setWatched(userID: userID, watchKey: item.watchKey, watched: watched)
        }
    }

    /// Marks/unmarks a single episode as watched (manual record), keyed by its
    /// per-episode watchKey ("ep:<mergeKey>:s<S>e<E>").
    static func setEpisodeWatched(_ watched: Bool, userID: String, watchKey: String, refID: String) async {
        let now = Int(Date().timeIntervalSince1970)
        try? await AppDatabase.shared.dbQueue.write { db in
            var state = try WatchState
                .filter(Column("userID") == userID && Column("itemID") == watchKey)
                .fetchOne(db)
                ?? WatchState(userID: userID, itemID: watchKey, isEpisode: true, refID: refID, viewOffsetMs: 0, viewCount: 0, lastViewedAt: now, finishedAt: nil)
            state.viewOffsetMs = 0
            state.viewCount = watched ? max(state.viewCount, 1) : 0
            state.finishedAt = watched ? now : nil
            state.lastViewedAt = now
            try state.save(db)
        }
        await MainActor.run {
            SyncStatus.shared.generation += 1
            SyncCoordinator.shared.enqueue(.watchState(userID: userID, itemID: watchKey))
            TraktSync.setWatched(userID: userID, watchKey: watchKey, watched: watched)
        }
    }

    /// Primera vez por usuario: hereda el estado actual de Plex como punto de partida.
    static func seedIfNeeded(userID: String) async {
        try? await AppDatabase.shared.dbQueue.write { db in
            let existing = try WatchState.filter(Column("userID") == userID).fetchCount(db)
            guard existing == 0 else { return }

            let movies = try MediaItem
                .filter(Column("type") == "movie" && (Column("viewOffsetMs") > 0 || Column("viewCount") > 0))
                .fetchAll(db)
            var seen = Set<String>()
            for movie in movies where seen.insert(movie.watchKey).inserted {
                try WatchState(
                    userID: userID,
                    itemID: movie.watchKey,
                    isEpisode: false,
                    refID: movie.id,
                    viewOffsetMs: movie.viewOffsetMs,
                    viewCount: movie.viewCount,
                    lastViewedAt: movie.lastViewedAt ?? 0,
                    finishedAt: movie.viewCount > 0 ? movie.lastViewedAt : nil
                ).save(db)
            }

            let shows = try MediaItem.filter(Column("type") == "show").fetchAll(db)
            let showsByID = shows.reduce(into: [String: MediaItem]()) { $0[$1.id] = $1 }
            let episodes = try Episode
                .filter(Column("viewOffsetMs") > 0 || Column("viewCount") > 0)
                .fetchAll(db)
            for episode in episodes {
                guard let show = showsByID[episode.showKey] else { continue }
                let key = PlexPlayback.episodeWatchKey(
                    showMergeKey: show.mergeKey,
                    season: episode.seasonNumber,
                    number: episode.episodeNumber
                )
                guard seen.insert(key).inserted else { continue }
                try WatchState(
                    userID: userID,
                    itemID: key,
                    isEpisode: true,
                    refID: episode.id,
                    viewOffsetMs: episode.viewOffsetMs,
                    viewCount: episode.viewCount,
                    lastViewedAt: episode.lastViewedAt ?? 0,
                    finishedAt: episode.viewCount > 0 ? episode.lastViewedAt : nil
                ).save(db)
            }
        }
    }
}
