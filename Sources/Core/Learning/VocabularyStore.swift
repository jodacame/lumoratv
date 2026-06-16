import Foundation

/// On-device, per-user vocabulary model for the language-learning mode. Counts how
/// many times each lemma (base form) has been *encountered* on screen; a lemma
/// graduates to "known" after enough encounters — so the movie itself acts as the
/// spaced-repetition system. Persisted in UserDefaults (no backend, no network).
@MainActor
final class VocabularyStore {
    static let shared = VocabularyStore()
    private let defaults = UserDefaults.standard
    private var cache: [String: [String: Int]] = [:]
    /// Encounters after which a word is treated as learned.
    let knownThreshold = 6

    enum Status { case new, learning, known }

    private init() {}

    private func key(_ userID: String, _ lang: String) -> String {
        "vocab.\(userID).\(lang.lowercased())"
    }

    private func dict(_ k: String) -> [String: Int] {
        if let c = cache[k] { return c }
        let d = defaults.dictionary(forKey: k) as? [String: Int] ?? [:]
        cache[k] = d
        return d
    }

    func status(_ lemma: String, userID: String, lang: String) -> Status {
        let c = dict(key(userID, lang))[lemma.lowercased()] ?? 0
        if c == 0 { return .new }
        return c < knownThreshold ? .learning : .known
    }

    func isKnown(_ lemma: String, userID: String, lang: String) -> Bool {
        (dict(key(userID, lang))[lemma.lowercased()] ?? 0) >= knownThreshold
    }

    /// Records one encounter per lemma (call once per displayed line). Returns the
    /// lemmas that were brand-new (first time ever seen) for the session summary.
    @discardableResult
    func record(_ lemmas: [String], userID: String, lang: String) -> [String] {
        guard !lemmas.isEmpty else { return [] }
        let k = key(userID, lang)
        var d = dict(k)
        var fresh: [String] = []
        for raw in Set(lemmas.map { $0.lowercased() }) {
            let prev = d[raw] ?? 0
            if prev == 0 { fresh.append(raw) }
            d[raw] = prev + 1
        }
        cache[k] = d
        defaults.set(d, forKey: k)
        SyncCoordinator.shared.enqueue(.vocab(userID: userID, lang: lang))
        return fresh
    }

    /// Merges a remote vocabulary snapshot (from another device) by taking the
    /// maximum encounter count per lemma — never loses learning progress.
    func mergeRemote(_ remote: [String: Int], userID: String, lang: String) {
        guard !remote.isEmpty else { return }
        let k = key(userID, lang)
        var d = dict(k)
        for (lemma, count) in remote { d[lemma] = max(d[lemma] ?? 0, count) }
        cache[k] = d
        defaults.set(d, forKey: k)
    }

    func knownCount(userID: String, lang: String) -> Int {
        dict(key(userID, lang)).values.filter { $0 >= knownThreshold }.count
    }
}
