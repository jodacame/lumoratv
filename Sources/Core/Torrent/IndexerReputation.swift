import Foundation

/// Internal reputation of torrent indexers, learned from real playback outcomes:
/// sources that load fine and get watched to the end rank up; sources whose
/// releases fail to start rank down. Persisted in UserDefaults.
enum IndexerReputation {

    struct Stats: Codable {
        var failures = 0     // release never started playing
        var loads = 0        // stream loaded and playback started
        var completions = 0  // the user finished watching
    }

    enum Event {
        case failed, loaded, completed
    }

    private static let key = "indexerReputation"

    static func record(_ event: Event, indexer: String) {
        guard !indexer.isEmpty, indexer != "?" else { return }
        var all = load()
        var stats = all[indexer] ?? Stats()
        switch event {
        case .failed: stats.failures += 1
        case .loaded: stats.loads += 1
        case .completed: stats.completions += 1
        }
        all[indexer] = stats
        save(all)
    }

    /// Normalized score in [-1, +1]. Completions weigh the most, failures hurt
    /// double. Laplace smoothing keeps young indexers near neutral until there
    /// is enough evidence.
    static func score(indexer: String) -> Double {
        guard let s = load()[indexer] else { return 0 }
        let positive = Double(s.loads) + Double(s.completions) * 3
        let negative = Double(s.failures) * 2
        let total = positive + negative + 6   // smoothing: ~6 events to move the needle
        return max(-1, min(1, (positive - negative) / total))
    }

    static func allStats() -> [String: Stats] { load() }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func load() -> [String: Stats] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Stats].self, from: data) else { return [:] }
        return decoded
    }

    private static func save(_ all: [String: Stats]) {
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
