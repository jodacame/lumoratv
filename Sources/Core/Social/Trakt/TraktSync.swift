import Foundation

/// Bridges the app's own actions to the user's Trakt account (phase 2), when that
/// Apple TV user has linked Trakt. Fire-and-forget; a no-op if the service isn't
/// configured (global Client ID) or the user isn't linked (per-user token).
@MainActor
enum TraktSync {
    /// mergeKey "tmdb:movie:603" / "tmdb:show:1399" → TraktRef.
    static func ref(from mergeKey: String) -> TraktRef? {
        let parts = mergeKey.split(separator: ":")
        guard parts.count == 3, parts[0] == "tmdb", let id = Int(parts[2]) else { return nil }
        return parts[1] == "show" ? .show(id) : .movie(id)
    }

    /// watchKey → TraktRef. Handles movies ("tmdb:movie:603") and episodes
    /// ("ep:tmdb:show:1399:s2e4").
    static func watchedRef(from watchKey: String) -> TraktRef? {
        guard watchKey.hasPrefix("ep:") else { return ref(from: watchKey) }
        let body = String(watchKey.dropFirst(3))            // "tmdb:show:1399:s2e4"
        guard let r = body.range(of: ":s", options: .backwards) else { return nil }
        let showKey = String(body[..<r.lowerBound])         // "tmdb:show:1399"
        let se = String(body[r.upperBound...])              // "2e4"
        let nums = se.split(separator: "e")
        guard nums.count == 2, let season = Int(nums[0]), let episode = Int(nums[1]),
              let showRef = ref(from: showKey) else { return nil }
        return .episode(showTmdbID: showRef.tmdbID, season: season, number: episode)
    }

    /// Mirrors the app's "My List" to the user's Trakt watchlist. No-op if not
    /// configured / not linked.
    static func setWatchlist(userID: String, mergeKey: String, inList: Bool) {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty,
              let ref = ref(from: mergeKey) else { return }
        Task {
            guard let token = await TraktAuth.accessToken(userID: userID) else { return }
            if inList {
                _ = await TraktClient.addToWatchlist(ref, clientID: clientID, token: token)
            } else {
                _ = await TraktClient.removeFromWatchlist(ref, clientID: clientID, token: token)
            }
        }
    }

    /// Pulls the user's Trakt watchlist into the app's My List (Trakt → app).
    /// Additive and idempotent; doesn't remove local items. No-op if not linked.
    static func pullWatchlist(userID: String) {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty else { return }
        Task {
            guard let token = await TraktAuth.accessToken(userID: userID) else { return }
            let refs = await TraktClient.watchlist(clientID: clientID, token: token)
            for ref in refs {
                let mergeKey = "tmdb:\(ref.isShow ? "show" : "movie"):\(ref.tmdbID)"
                await MyListStore.addFromRemote(userID: userID, mergeKey: mergeKey)
            }
        }
    }

    /// TraktRef → app watchKey (inverso de `watchedRef`).
    static func watchKey(for ref: TraktRef) -> String? {
        if ref.isEpisode, let s = ref.season, let e = ref.episode {
            return "ep:tmdb:show:\(ref.tmdbID):s\(s)e\(e)"
        }
        return ref.isShow ? nil : "tmdb:movie:\(ref.tmdbID)"
    }

    private static var didBackfillPush = Set<String>()

    /// Trakt → local "Continuar viendo": trae los items en progreso de Trakt y agrega
    /// SOLO los que NO existen localmente (prioridad local; nunca pisa). Registra un
    /// stub virtual para que aparezcan. (Películas; los episodios se materializarán
    /// después.) No-op si no está vinculado.
    static func pullContinueWatching(userID: String) {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty,
              let tmdbKey = SettingsStore.shared.tmdbKey else { return }
        Task {
            guard let token = await TraktAuth.accessToken(userID: userID) else { return }
            let items = await TraktClient.playbackProgress(clientID: clientID, token: token)
            guard !items.isEmpty else { return }
            let existing = await WatchStore.states(userID: userID)
            var added = false
            for item in items where item.progress > 1 && item.progress < 95 {
                guard !item.ref.isShow, let key = watchKey(for: item.ref), existing[key] == nil else { continue }
                if let d = await TMDBBrowse.discoverItem(tmdbID: item.ref.tmdbID, isShow: false, key: tmdbKey) {
                    await VirtualLibrary.registerMovie(d)
                }
                await WatchStore.addFromTrakt(userID: userID, watchKey: key, isEpisode: false,
                                              progress: item.progress, pausedAt: item.pausedAt)
                added = true
            }
            if added { SyncStatus.shared.generation += 1 }
        }
    }

    /// Local → Trakt: sube TODO el progreso local en curso (scrobble pause). Una vez
    /// por sesión (el progreso en vivo ya se scrobblea al reproducir). No-op si no
    /// está vinculado.
    static func pushAllContinueWatching(userID: String) {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty,
              !didBackfillPush.contains(userID) else { return }
        didBackfillPush.insert(userID)
        Task {
            guard let token = await TraktAuth.accessToken(userID: userID) else { return }
            let states = await WatchStore.states(userID: userID)
            for (key, s) in states where s.finishedAt == nil && s.viewOffsetMs > 0 {
                guard let dur = s.durationMs, dur > 0, let ref = watchedRef(from: key) else { continue }
                let progress = Double(s.viewOffsetMs) / Double(dur) * 100
                guard progress > 1, progress < 95 else { continue }
                _ = await TraktClient.scrobble(.pause, ref: ref, progress: progress, clientID: clientID, token: token)
                try? await Task.sleep(nanoseconds: 700_000_000)   // throttle anti rate-limit
            }
        }
    }

    /// Real-time scrobble (start/pause/stop) of what the current user is watching,
    /// to their Trakt profile. A stop at ≥80% marks it watched automatically — so
    /// this is the auto "watched" path; manual marking uses `setWatched`.
    /// No-op if not configured / not linked.
    static func scrobble(_ action: TraktScrobbleAction, userID: String,
                         watchKey: String, progress: Double) {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty,
              let ref = watchedRef(from: watchKey) else { return }
        Task {
            guard let token = await TraktAuth.accessToken(userID: userID) else { return }
            _ = await TraktClient.scrobble(action, ref: ref, progress: progress,
                                           clientID: clientID, token: token)
        }
    }

    /// Marks (or unmarks) a movie/show/episode as watched on the user's Trakt
    /// history & profile (manual toggle). No-op if the service isn't configured or
    /// the user isn't linked — so it never affects playback when Trakt isn't there.
    static func setWatched(userID: String, watchKey: String, watched: Bool) {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty,
              let ref = watchedRef(from: watchKey) else { return }
        Task {
            guard let token = await TraktAuth.accessToken(userID: userID) else { return }
            if watched {
                _ = await TraktClient.markWatched(ref, clientID: clientID, token: token)
            } else {
                _ = await TraktClient.removeWatched(ref, clientID: clientID, token: token)
            }
        }
    }

    /// Mirrors a 👍 to the user's Trakt **Favorites** (the curated "me gusta"
    /// playlist), not a numeric rating. 👍 adds to Favorites; 👎 or clearing
    /// removes it. No-op if not configured / not linked.
    static func pushLike(userID: String, mergeKey: String, liked: Bool?) {
        guard let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty,
              let ref = ref(from: mergeKey) else { return }
        Task {
            guard let token = await TraktAuth.accessToken(userID: userID) else { return }
            if liked == true {
                _ = await TraktClient.addFavorite(ref, clientID: clientID, token: token)
            } else {
                _ = await TraktClient.removeFavorite(ref, clientID: clientID, token: token)
            }
        }
    }
}
