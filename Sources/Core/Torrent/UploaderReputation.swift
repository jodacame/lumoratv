import Foundation

/// Internal reputation of release uploaders (scene/P2P groups parsed from the
/// release title), learned from REAL viewing behavior — not from what titles
/// promise. Two dimensions are tracked:
///
/// - Playback: did releases from this group start, get watched, get finished?
/// - Subtitles: when the file carried embedded subtitles in the user's
///   language, did the user actually watch with them (groups that ship
///   complete, synced subs) or did they have to rescue the session by
///   downloading external ones?
///
/// Identity comes from a heuristic title parse, which is noisy by nature.
/// That's fine: a mis-parsed token ("AAC") aggregates releases from many
/// unrelated uploaders, so its stats converge to the global average and its
/// score to ~0 — neutral, harmless. Real groups accumulate a consistent
/// signal that survives. Laplace smoothing keeps young entries near neutral.
enum UploaderReputation {

    struct Stats: Codable {
        var failures = 0       // release never started playing
        var loads = 0          // stream loaded and playback started
        var completions = 0    // the user finished watching
        var abandons = 0       // the user switched source mid-watch (alive but bad)
        var subsUsed = 0       // finished watching WITH embedded subs in their language
        var subsRescued = 0    // had embedded subs in their language, user fetched external anyway

        var totalEvents: Int { failures + loads + completions + abandons + subsUsed + subsRescued }
    }

    enum Event {
        case failed, loaded, completed, abandoned, subsUsed, subsRescued
    }

    private static let key = "uploaderReputation"
    /// Hard cap so the store never grows unbounded; least-seen entries are evicted.
    private static let maxEntries = 200

    static func record(_ event: Event, uploader: String?) {
        guard let uploader, !uploader.isEmpty else { return }
        var all = load()
        var stats = all[uploader] ?? Stats()
        switch event {
        case .failed: stats.failures += 1
        case .loaded: stats.loads += 1
        case .completed: stats.completions += 1
        case .abandoned: stats.abandons += 1
        case .subsUsed: stats.subsUsed += 1
        case .subsRescued: stats.subsRescued += 1
        }
        all[uploader] = stats
        if all.count > maxEntries {
            evictLeastSeen(&all)
        }
        save(all)
    }

    /// Normalized score in [-1, +1]. Completions and subs-used weigh the most;
    /// failures and mid-watch abandons hurt double. Laplace smoothing keeps new
    /// groups near neutral until there is enough evidence (~6 events).
    static func score(uploader: String?) -> Double {
        guard let uploader, let s = load()[uploader] else { return 0 }
        let positive = Double(s.loads) + Double(s.completions) * 3 + Double(s.subsUsed) * 3
        let negative = Double(s.failures) * 2 + Double(s.abandons) * 2 + Double(s.subsRescued)
        let total = positive + negative + 6
        return max(-1, min(1, (positive - negative) / total))
    }

    static func allStats() -> [String: Stats] { load() }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func evictLeastSeen(_ all: inout [String: Stats]) {
        let sorted = all.sorted { $0.value.totalEvents < $1.value.totalEvents }
        for (name, _) in sorted.prefix(all.count - maxEntries) {
            all.removeValue(forKey: name)
        }
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
