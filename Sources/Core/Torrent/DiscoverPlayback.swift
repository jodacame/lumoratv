import Foundation
import GRDB

/// Resolves which playback options exist for a title identified by TMDB:
/// versions on configured servers (Plex) and/or torrent releases (if Streaming Mode is ready).
enum DiscoverPlayback {

    struct Sources: Sendable {
        var libraryItem: MediaItem?          // local copy if it exists (for the Plex path)
        var serverVersions: [PlayVersion]    // versions on servers
        var torrentReleases: [TorrentRelease]
        var diagnostic: String?              // why there were no torrents (incomplete config, error, empty)
        var hasAny: Bool { !serverVersions.isEmpty || !torrentReleases.isEmpty }
    }

    /// Finds the local copy by content identity (TMDB id).
    @MainActor
    static func libraryItem(tmdbID: Int, isShow: Bool) async -> MediaItem? {
        let type = isShow ? "show" : "movie"
        let raw = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(Column("type") == type && Column("tmdbID") == tmdbID).fetchAll(db)
        }) ?? []
        return HomeViewModel.merged(raw).first
    }

    /// Resolves all sources for a TMDB item.
    @MainActor
    static func resolve(item: DiscoverItem) async -> Sources {
        var sources = Sources(libraryItem: nil, serverVersions: [], torrentReleases: [])
        let settings = SettingsStore.shared

        // 1) Is it on any configured server?
        if let local = await libraryItem(tmdbID: item.tmdbID, isShow: item.isShow) {
            sources.libraryItem = local
            sources.serverVersions = (try? await PlexPlayback.resolveVersions(item: local)) ?? []
        }

        // 2) Torrents (only if the source is configured). We capture the exact
        //    reason when there are no results so it can be shown on screen.
        if settings.streamingModeReady, let key = settings.tmdbKey {
            let imdbID = await TMDBBrowse.imdbID(tmdbID: item.tmdbID, isShow: item.isShow, key: key)
            let query = (item.year != nil && !item.isShow) ? "\(item.title) \(item.year!)" : item.title
            do {
                let releases = try await ProwlarrClient.search(query: query, imdbID: imdbID, isShow: item.isShow)
                sources.torrentReleases = releases
                if releases.isEmpty {
                    sources.diagnostic = trf(L.prowlarrNoReleases, query)
                }
            } catch {
                sources.diagnostic = "Prowlarr: \(error.localizedDescription)"
            }
        } else if settings.streamingModeEnabled {
            // Streaming Mode is on but pieces are missing: say exactly which ones.
            var missing: [String] = []
            if settings.tmdbKey == nil { missing.append("TMDB API key") }
            if settings.prowlarrURL.isEmpty { missing.append("Prowlarr URL") }
            if settings.prowlarrKey == nil { missing.append("Prowlarr API key") }
            if settings.torrServerURL.isEmpty { missing.append("TorrServer URL") }
            if !missing.isEmpty {
                sources.diagnostic = trf(L.streamingIncomplete, missing.joined(separator: ", "))
            }
        }
        return sources
    }

    /// Resolves torrent releases for a specific episode of a show.
    /// Searches with the "Title SxxEyy" pattern (used by release names).
    @MainActor
    static func resolveEpisode(item: DiscoverItem, episode: TMDBBrowse.DiscoverEpisode) async -> Sources {
        var sources = Sources(libraryItem: nil, serverVersions: [], torrentReleases: [])
        let settings = SettingsStore.shared

        guard settings.streamingModeReady, let key = settings.tmdbKey else {
            if settings.streamingModeEnabled {
                var missing: [String] = []
                if settings.tmdbKey == nil { missing.append("TMDB API key") }
                if settings.prowlarrURL.isEmpty { missing.append("Prowlarr URL") }
                if settings.prowlarrKey == nil { missing.append("Prowlarr API key") }
                if settings.torrServerURL.isEmpty { missing.append("TorrServer URL") }
                if !missing.isEmpty {
                    sources.diagnostic = trf(L.streamingIncomplete, missing.joined(separator: ", "))
                }
            }
            return sources
        }

        let imdbID = await TMDBBrowse.imdbID(tmdbID: item.tmdbID, isShow: true, key: key)
        // Search for the specific episode and also the season (for packs).
        let epQuery = "\(item.title) \(episode.code)"
        let seasonQuery = String(format: "\(item.title) S%02d", episode.seasonNumber)
        do {
            var releases = try await ProwlarrClient.search(query: epQuery, imdbID: imdbID, isShow: true)
            // Add season results (packs) that the episode search didn't return.
            let seen = Set(releases.map(\.id))
            let packs = (try? await ProwlarrClient.search(query: seasonQuery, imdbID: imdbID, isShow: true)) ?? []
            releases += packs.filter { !seen.contains($0.id) }

            // Discard releases for a DIFFERENT episode/season; keep exact matches, packs and
            // ambiguous ones. Sort: exact episode → pack → ambiguous, then by composite
            // score (quality + health + language + size + freeleech + reputation).
            let scored = releases
                .map { ($0, EpisodeMatch.relevance($0.title, season: episode.seasonNumber, episode: episode.episodeNumber)) }
                .filter { $0.1 != .different }
                .sorted { a, b in
                    if a.1.rawValue != b.1.rawValue { return a.1.rawValue < b.1.rawValue }
                    return ReleaseScore.score(a.0) > ReleaseScore.score(b.0)
                }
            sources.torrentReleases = scored.map(\.0)
            if sources.torrentReleases.isEmpty {
                sources.diagnostic = trf(L.episodeNotFound, episode.code)
            }
        } catch {
            sources.diagnostic = "Prowlarr: \(error.localizedDescription)"
        }
        return sources
    }

    /// Builds a PlayableMedia for an episode resolved from a torrent.
    @MainActor
    static func playableEpisode(from release: TorrentRelease, item: DiscoverItem, episode: TMDBBrowse.DiscoverEpisode, startOverrideMs: Int? = nil) async throws -> PlayableMedia {
        // Fetch the age rating + genres in parallel with the stream resolution (no added latency).
        async let metaTask = playerMetadata(for: item)
        // Pass season/episode: if the release is a pack, pick the EXACT file for the episode.
        let resolved = try await TorrServerClient.resolve(for: release, season: episode.seasonNumber, episode: episode.episodeNumber)
        let meta = await metaTask
        // Guarda el cert al persistir el item → "Continuar viendo" no lo oculta en perfiles kids.
        await VirtualLibrary.registerEpisode(show: item, episode: episode, certification: meta.contentRating)
        TorrentChoiceStore.save(watchKey: episodeWatchKey(item, episode), release: release)
        let offset: Int
        if let startOverrideMs {
            offset = startOverrideMs   // resume decision already made in the detail screen
        } else {
            offset = await VirtualLibrary.resumeOffset(watchKey: episodeWatchKey(item, episode))
        }
        return episodePlayable(videoURL: resolved.videoURL, subs: resolved.subtitles, item: item, episode: episode, release: release, startOffsetMs: offset, contentRating: meta.contentRating, genres: meta.genres)
    }

    @MainActor
    private static func episodeWatchKey(_ item: DiscoverItem, _ episode: TMDBBrowse.DiscoverEpisode) -> String {
        PlexPlayback.episodeWatchKey(showMergeKey: item.mergeKey, season: episode.seasonNumber, number: episode.episodeNumber)
    }

    /// TMDB extras (age rating + genres) for a torrent title, so the player shows
    /// them like Plex content does. Best-effort; the two TMDB calls run in parallel.
    @MainActor
    private static func playerMetadata(for item: DiscoverItem) async -> (genres: String, contentRating: String?) {
        guard let key = SettingsStore.shared.tmdbKey else { return ("", nil) }
        async let details = TMDBBrowse.details(tmdbID: item.tmdbID, isShow: item.isShow, key: key)
        async let cert = TMDBBrowse.certification(tmdbID: item.tmdbID, isShow: item.isShow, key: key)
        return (await details.genres, await cert)
    }

    /// The next episode: tries to reuse the SAME pack (another file in the torrent);
    /// if it's not there, searches Prowlarr for the individual episode. Returns nil if there are no more.
    @MainActor
    static func nextTorrentEpisode(after media: PlayableMedia) async -> PlayableMedia? {
        guard media.serverID == "torrent", media.isEpisode,
              let tmdbID = media.tmdbID, let season = media.seasonNumber, let current = media.episodeNumber,
              let key = SettingsStore.shared.tmdbKey else { return nil }

        // Rebuild the virtual item and fetch the next episode's metadata.
        let item = DiscoverItem(
            tmdbID: tmdbID, isShow: true, title: media.title, overview: media.summary,
            posterPath: nil, backdropPath: nil, year: media.year, rating: media.rating
        )
        let eps = await TMDBBrowse.episodes(showID: tmdbID, season: season, key: key)
        guard let next = eps.first(where: { $0.episodeNumber == current + 1 }) else { return nil }

        // 1) Is the next episode in the SAME torrent (pack)?
        if let hash = TorrServerClient.hash(from: media.url),
           let resolved = try? await TorrServerClient.resolveInSameTorrent(hash: hash, season: season, episode: next.episodeNumber) {
            // Reuse the implicit "release": no quality metadata, but it plays.
            let release = TorrentRelease(title: "", magnetURL: nil, downloadURL: nil, infoHash: hash,
                                         sizeBytes: 0, seeders: 0, leechers: 0, indexer: "pack", freeleech: nil)
            let meta = await playerMetadata(for: item)
            await VirtualLibrary.registerEpisode(show: item, episode: next, certification: meta.contentRating)
            let offset = await VirtualLibrary.resumeOffset(watchKey: episodeWatchKey(item, next))
            return episodePlayable(videoURL: resolved.videoURL, subs: resolved.subtitles, item: item, episode: next, release: release, startOffsetMs: offset, contentRating: meta.contentRating, genres: meta.genres)
        }

        // 2) If it's not in the pack, search for the individual episode.
        let sources = await resolveEpisode(item: item, episode: next)
        guard let best = sources.torrentReleases.first else { return nil }
        return try? await playableEpisode(from: best, item: item, episode: next)
    }

    @MainActor
    private static func episodePlayable(videoURL: URL, subs: [ExternalSubtitle], item: DiscoverItem, episode: TMDBBrowse.DiscoverEpisode, release: TorrentRelease, startOffsetMs: Int, contentRating: String? = nil, genres: String = "") -> PlayableMedia {
        PlayableMedia(
            ratingKey: "torrent-\(item.tmdbID)-\(episode.id)",
            serverID: "torrent",
            watchKey: episodeWatchKey(item, episode),
            refID: VirtualLibrary.episodeID(tmdbID: item.tmdbID, season: episode.seasonNumber, number: episode.episodeNumber),
            isEpisode: true,
            title: item.title,
            subtitle: "\(episode.code) · \(episode.name)",
            url: videoURL,
            durationMs: 0,
            startOffsetMs: startOffsetMs,
            artPath: nil,
            thumbPath: nil,
            logoURL: nil,
            partID: nil,
            hasPreviewThumbnails: false,
            year: item.year,
            rating: item.rating,
            contentRating: contentRating,
            resolution: release.quality,
            videoCodec: release.codec,
            fileSizeGB: release.sizeGB,
            hdrLabel: release.hdr,
            tmdbID: item.tmdbID,
            tmdbIsShow: true,
            summary: episode.overview.isEmpty ? item.overview : episode.overview,
            genres: genres,
            externalSubs: subs,
            markers: [],
            reportsProgress: true,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            sourceProvider: release.indexer.isEmpty ? nil : release.indexer,
            sourceGroup: release.releaseGroup
        )
    }

    /// Builds a PlayableMedia from a torrent release (resolves the stream in TorrServer,
    /// including sidecar subtitles from the torrent itself).
    @MainActor
    static func playable(from release: TorrentRelease, item: DiscoverItem, startOverrideMs: Int? = nil) async throws -> PlayableMedia {
        // Fetch the age rating + genres in parallel with the stream resolution (no added latency).
        async let metaTask = playerMetadata(for: item)
        let resolved = try await TorrServerClient.resolve(for: release)
        let meta = await metaTask
        // Guarda el cert al persistir el item → "Continuar viendo" no lo oculta en perfiles kids.
        await VirtualLibrary.registerMovie(item, certification: meta.contentRating)
        TorrentChoiceStore.save(watchKey: item.mergeKey, release: release)
        let offset: Int
        if let startOverrideMs {
            offset = startOverrideMs   // resume decision already made in the detail screen
        } else {
            offset = await VirtualLibrary.resumeOffset(watchKey: item.mergeKey)
        }
        return PlayableMedia(
            ratingKey: "torrent-\(item.tmdbID)",
            serverID: "torrent",
            watchKey: item.mergeKey,
            refID: item.mergeKey,
            isEpisode: false,
            title: item.title,
            subtitle: release.title,
            url: resolved.videoURL,
            durationMs: 0,
            startOffsetMs: offset,
            artPath: nil,
            thumbPath: nil,
            logoURL: nil,
            partID: nil,
            hasPreviewThumbnails: false,
            year: item.year,
            rating: item.rating,
            contentRating: meta.contentRating,
            resolution: release.quality,
            videoCodec: release.codec,
            fileSizeGB: release.sizeGB,
            hdrLabel: release.hdr,
            tmdbID: item.tmdbID,
            tmdbIsShow: item.isShow,
            summary: item.overview,
            genres: meta.genres,
            externalSubs: resolved.subtitles,
            markers: [],
            reportsProgress: true,
            sourceProvider: release.indexer.isEmpty ? nil : release.indexer,
            sourceGroup: release.releaseGroup
        )
    }
}
