import Foundation

/// Persistent cache of TMDB age certifications (US) per title, so the parental
/// filter can rate the virtual TMDB/Trakt catalog (DiscoverItem carries no age
/// rating). `""` means "looked up, none available" — avoids refetching forever.
actor CertStore {
    static let shared = CertStore()

    private let defaultsKey = "certCache.v1"
    private var cache: [String: String]

    init() {
        cache = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    private func key(_ tmdbID: Int, _ isShow: Bool) -> String { "\(isShow ? "t" : "m")\(tmdbID)" }

    /// US age certification for a title (nil if none). Cached after first lookup.
    func certification(tmdbID: Int, isShow: Bool, apiKey: String) async -> String? {
        let k = key(tmdbID, isShow)
        if let cached = cache[k] { return cached.isEmpty ? nil : cached }
        let fetched = await TMDBBrowse.certification(tmdbID: tmdbID, isShow: isShow, key: apiKey)
        cache[k] = fetched ?? ""
        UserDefaults.standard.set(cache, forKey: defaultsKey)   // UserDefaults is thread-safe
        return fetched
    }
}
