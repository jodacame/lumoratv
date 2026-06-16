import Foundation

/// Remembers the specific torrent the user started watching a piece of content with,
/// to reuse it for "Continue watching" without asking for the source again.
/// Switching sources (in the player panel) updates this memory.
@MainActor
enum TorrentChoiceStore {
    private static func key(_ watchKey: String) -> String {
        "torrentChoice-\(UserContext.currentUserID)-\(watchKey)"
    }

    static func save(watchKey: String, release: TorrentRelease) {
        // We don't remember the pack-reuse "pseudo-release" with no identity of its own.
        guard release.magnetURL != nil || release.infoHash != nil || release.downloadURL != nil,
              let data = try? JSONEncoder().encode(release) else { return }
        UserDefaults.standard.set(data, forKey: key(watchKey))
        SyncCoordinator.shared.enqueue(.torrentChoice(userID: UserContext.currentUserID, watchKey: watchKey))
    }

    static func get(watchKey: String) -> TorrentRelease? {
        guard let data = UserDefaults.standard.data(forKey: key(watchKey)) else { return nil }
        return try? JSONDecoder().decode(TorrentRelease.self, from: data)
    }

    static func clear(watchKey: String) {
        UserDefaults.standard.removeObject(forKey: key(watchKey))
        SyncCoordinator.shared.enqueue(.torrentChoice(userID: UserContext.currentUserID, watchKey: watchKey))
    }
}
