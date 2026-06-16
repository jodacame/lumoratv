import SwiftUI

struct ParentalConfig: Codable, Equatable {
    var pin: String
    var maxLevel: Int   // 0=G · 1=PG · 2=PG-13 · 3=everything
}

/// Per-Apple TV user parental controls: PIN + maximum rating.
/// With a restriction active, unrated content is also hidden.
///
/// **LOCAL-ONLY by design (safety):** never synced via iCloud. It lives in the
/// per-user `UserDefaults` (isolated by `runs-as-current-user`), so one profile's
/// restriction can NEVER leak to another — even if several Apple TV profiles share
/// one Apple ID (where account-wide CloudKit would otherwise cross-contaminate).
/// The trade-off (set the restriction per Apple TV) is the correct one for a
/// control protecting a minor. Set it on each device.
@MainActor
final class ParentalStore: ObservableObject {
    static let shared = ParentalStore()

    @Published private(set) var config: ParentalConfig?

    /// Usuario para el que `config` está cargado (red de seguridad ante cambios).
    private var loadedForUserID: String?

    private var storageKey: String { "parental-\(UserContext.currentUserID)" }

    private init() {
        reload()
    }

    func reload() {
        loadedForUserID = UserContext.currentUserID
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(ParentalConfig.self, from: data) {
            config = decoded
        } else {
            config = nil
        }
    }

    /// Seguridad ante todo: si el usuario activo cambió desde la última carga,
    /// recarga ANTES de evaluar, para no aplicar jamás la restricción de otro
    /// usuario (ni dejar pasar contenido por una config obsoleta).
    private func ensureCurrentUser() {
        if loadedForUserID != UserContext.currentUserID { reload() }
    }

    /// La fuente de verdad del nivel parental es el PERFIL de la app activo. Esto lo
    /// aplica (lo llama `ProfileStore` al seleccionar/editar). nil/≥3 = sin
    /// restricción. El PIN que protege cambios es el PIN del hogar (`ProfileStore`).
    func applyProfileLevel(_ level: Int?) {
        loadedForUserID = UserContext.currentUserID
        if let level, level < 3 {
            let new = ParentalConfig(pin: "", maxLevel: level)
            config = new
            if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: storageKey) }
        } else {
            config = nil
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    var isEnabled: Bool { config != nil }

    func enable(pin: String, maxLevel: Int) {
        let new = ParentalConfig(pin: pin, maxLevel: maxLevel)
        config = new
        persist()
        SyncStatus.shared.generation += 1
    }

    func updateMaxLevel(_ level: Int) {
        guard var current = config else { return }
        current.maxLevel = level
        config = current
        persist()
        SyncStatus.shared.generation += 1
    }

    /// Sets the content level immediately (the PIN is optional, it only protects changes).
    /// Level 3 ("everything") = no restriction: keeps the PIN if one existed.
    func setLevel(_ level: Int) {
        if level >= 3 {
            if var current = config { current.maxLevel = 3; config = current; persist() }
        } else if var current = config {
            current.maxLevel = level
            config = current
            persist()
        } else {
            config = ParentalConfig(pin: "", maxLevel: level)   // no PIN: filter without a lock
            persist()
        }
        SyncStatus.shared.generation += 1
    }

    /// Sets/changes the protection PIN (empty = remove the lock).
    func setPin(_ pin: String) {
        guard var current = config else { return }
        current.pin = pin.trimmingCharacters(in: .whitespaces)
        config = current
        persist()
    }

    var hasPin: Bool { !(config?.pin ?? "").isEmpty }

    @discardableResult
    func disable(pin: String) -> Bool {
        guard verify(pin: pin) else { return false }
        config = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
        SyncStatus.shared.generation += 1
        return true
    }

    func verify(pin: String) -> Bool {
        // With no PIN configured (empty) there is no lock: any change is allowed.
        guard let stored = config?.pin, !stored.isEmpty else { return true }
        return stored == pin.trimmingCharacters(in: .whitespaces)
    }

    private func persist() {
        guard let config, let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: Filtering

    func allows(_ item: MediaItem) -> Bool {
        ensureCurrentUser()
        guard let config else { return true }
        guard let rating = item.contentRating else {
            // No rating: only visible if the limit is "everything".
            return config.maxLevel >= 3
        }
        return Self.level(for: rating) <= config.maxLevel
    }

    func filter(_ items: [MediaItem]) -> [MediaItem] {
        guard config != nil else { return items }
        return items.filter { allows($0) }
    }

    /// Active restriction level (nil = no restriction / "everything").
    var activeLevel: Int? {
        ensureCurrentUser()
        return config.flatMap { $0.maxLevel < 3 ? $0.maxLevel : nil }
    }

    /// Whether an age-certification string is allowed under the current limit.
    func allowsCert(_ cert: String?) -> Bool {
        ensureCurrentUser()
        guard let config else { return true }
        guard let cert, !cert.isEmpty else { return config.maxLevel >= 3 }
        return Self.level(for: cert) <= config.maxLevel
    }

    /// First shield: filters TMDB/Trakt discover items by age certification
    /// (fetched + cached via CertStore). No-op without a restriction. Unrated
    /// titles are HIDDEN when restricted. Covers Home discovery, Trakt, search,
    /// categories — anywhere DiscoverItems are shown.
    func filterDiscover(_ items: [DiscoverItem]) async -> [DiscoverItem] {
        ensureCurrentUser()
        guard let config, config.maxLevel < 3 else { return items }
        // Security-first: if restricted and we can't verify ratings, hide everything.
        guard let apiKey = SettingsStore.shared.tmdbKey else { return [] }
        // Fetch certifications in PARALLEL (cached) — keeps the filter fast.
        let certs: [Int: String] = await withTaskGroup(of: (Int, String).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask {
                    let c = await CertStore.shared.certification(tmdbID: item.tmdbID, isShow: item.isShow, apiKey: apiKey)
                    return (i, c ?? "")
                }
            }
            var map: [Int: String] = [:]
            for await (i, c) in group { map[i] = c }
            return map
        }
        return items.enumerated().compactMap { i, item in
            let cert = certs[i]
            return allowsCert(cert?.isEmpty == false ? cert : nil) ? item : nil
        }
    }

    /// Second shield: authoritative gate BEFORE playback. Fetches the certification
    /// for virtual items that don't carry one, and blocks anything above the limit
    /// (in case something slipped past the row filters).
    func allowsPlayback(_ item: MediaItem) async -> Bool {
        ensureCurrentUser()
        guard let config, config.maxLevel < 3 else { return true }
        if let rating = item.contentRating, !rating.isEmpty {
            return Self.level(for: rating) <= config.maxLevel
        }
        if let tmdbID = item.tmdbID, let apiKey = SettingsStore.shared.tmdbKey {
            let cert = await CertStore.shared.certification(tmdbID: tmdbID, isShow: item.type == "show", apiKey: apiKey)
            return allowsCert(cert)
        }
        return config.maxLevel >= 3
    }

    /// Level for a rating (US, TV, and common numeric ratings).
    static func level(for rating: String) -> Int {
        let r = rating.uppercased().trimmingCharacters(in: .whitespaces)
        switch r {
        case "G", "TV-Y", "TV-G", "APTA", "A", "AL", "0", "TP":
            return 0
        case "PG", "TV-Y7", "TV-PG", "6", "7", "7+", "8":
            return 1
        case "PG-13", "TV-14", "12", "13", "13+", "14", "14+", "15":
            return 2
        default:
            // R, NC-17, TV-MA, 16, 18, X, and anything unknown.
            return 3
        }
    }
}
