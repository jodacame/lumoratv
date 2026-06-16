import Foundation

/// Bounded, on-disk LRU cache of AI word explanations: a repeated word never
/// re-hits the API, and the cache can't fill the disk (capped entry count, LRU
/// eviction, stored in the purgeable Caches directory).
actor AIWordCache {
    static let shared = AIWordCache()

    private struct Entry: Codable { let text: String; var used: Int }
    private var entries: [String: Entry] = [:]
    private var counter = 0
    private let maxEntries = 1500
    private let url: URL
    private var loaded = false

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("ai_word_cache.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
        counter = (entries.values.map(\.used).max() ?? 0) + 1
    }

    func get(_ key: String) -> String? {
        loadIfNeeded()
        guard var e = entries[key] else { return nil }
        counter += 1
        e.used = counter
        entries[key] = e
        return e.text
    }

    func set(_ key: String, _ text: String) {
        loadIfNeeded()
        counter += 1
        entries[key] = Entry(text: text, used: counter)
        if entries.count > maxEntries {
            // Evict the least-recently-used down to ~90% to avoid pruning every write.
            let target = Int(Double(maxEntries) * 0.9)
            for (k, _) in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(entries.count - target) {
                entries.removeValue(forKey: k)
            }
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
