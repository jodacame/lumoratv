import Foundation

/// Series que el usuario decidió "dejar de ver": se excluyen de Continuar viendo,
/// Para ti, Porque te gusta y Nuevos episodios. Per-usuario de Apple TV.
@MainActor
enum StoppedStore {
    private static func key(_ userID: String) -> String { "stoppedShows-\(userID)" }

    static func all(userID: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(userID)) ?? [])
    }

    static func isStopped(userID: String, mergeKey: String) -> Bool {
        all(userID: userID).contains(mergeKey)
    }

    static func stop(userID: String, mergeKey: String) {
        var set = all(userID: userID)
        set.insert(mergeKey)
        UserDefaults.standard.set(Array(set), forKey: key(userID))
        SyncStatus.shared.generation += 1
        SyncCoordinator.shared.enqueue(.stoppedShow(userID: userID, mergeKey: mergeKey))
    }

    static func resume(userID: String, mergeKey: String) {
        var set = all(userID: userID)
        set.remove(mergeKey)
        UserDefaults.standard.set(Array(set), forKey: key(userID))
        SyncStatus.shared.generation += 1
        SyncCoordinator.shared.enqueue(.stoppedShow(userID: userID, mergeKey: mergeKey))
    }
}
