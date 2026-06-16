import Foundation

/// On-disk cache for the Home discovery rows + categories (TMDB + Trakt
/// trending/most-watched/anticipated, related, etc.).
///
/// Cache-first / offline: the Home renders this snapshot instantly on every
/// entry (no network, works offline) and only refreshes in the background when
/// the snapshot is stale (older than the TTL) or its key changed (language /
/// streaming mode). Best-effort — any read/write failure just behaves as a miss.
actor DiscoverCache {
    static let shared = DiscoverCache()

    struct Payload: Codable {
        var rows: [DiscoverRow]
        var categories: [DiscoverCategory]
        var savedAt: Double      // epoch seconds
        var key: String          // language + streaming-mode + version fingerprint
    }

    /// Bump when the payload shape changes to invalidate old caches.
    private static let version = 1
    /// Background refresh threshold. Within this window the cache is served
    /// without hitting the network at all.
    private let ttl: TimeInterval = 60 * 60 * 6   // 6 hours

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("home-discover.json")
    }

    /// Fingerprint that must match for a cache hit to be valid. Includes the
    /// Trakt-ready flag and the parental level so cached rows are always correct
    /// for the current restriction.
    nonisolated static func key(lang: String, fullCatalog: Bool, trakt: Bool, parental: Int) -> String {
        "v\(version)|\(lang)|\(fullCatalog ? "full" : "lite")|\(trakt ? "trakt" : "notrakt")|p\(parental)"
    }

    /// Returns the cached payload only if it matches the current key.
    func load(key: String) -> Payload? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.key == key else { return nil }
        return payload
    }

    func isStale(_ payload: Payload, now: Double) -> Bool {
        now - payload.savedAt > ttl
    }

    func save(rows: [DiscoverRow], categories: [DiscoverCategory], key: String, now: Double) {
        let payload = Payload(rows: rows, categories: categories, savedAt: now, key: key)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
