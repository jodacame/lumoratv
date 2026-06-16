import Foundation

/// **Service-agnostic** source resolution: given a piece of content (`MediaItem`)
/// and, optionally, an episode, gathers every way to play it —
/// versions on Plex servers + torrent releases (and, in the future, other services) —
/// into a single list. The UI just renders whatever arrives; adding a new service means
/// adding a case here, not scattering conditionals across the views.
@MainActor
enum PlaybackResolver {

    /// A playback option, regardless of which service it comes from.
    struct Option: Identifiable {
        enum Origin {
            case server(PlayVersion)
            case torrent(TorrentRelease)
        }
        let origin: Origin

        var id: String {
            switch origin {
            case .server(let v): "server:\(v.id)"
            case .torrent(let r): "torrent:\(r.id)"
            }
        }
        /// Main line: server name or torrent quality.
        var title: String {
            switch origin {
            case .server(let v): v.serverName
            case .torrent(let r): r.qualityLabel.isEmpty ? r.indexer : r.qualityLabel
            }
        }
        var qualityLabel: String {
            switch origin {
            case .server(let v): v.qualityLabel
            case .torrent(let r): r.qualityLabel
            }
        }
        var detailTitle: String? {
            switch origin {
            case .server: nil
            case .torrent(let r): r.title
            }
        }
        var badges: [String] {
            switch origin {
            case .server(let v): Array(v.audioLangs.prefix(4))
            case .torrent(let r): r.languageBadges
            }
        }
        var seeders: Int? {
            if case .torrent(let r) = origin { return r.seeders }
            return nil
        }
        var sizeGB: Double? {
            if case .torrent(let r) = origin { return r.sizeGB > 0 ? r.sizeGB : nil }
            return nil
        }
        var isServer: Bool {
            if case .server = origin { return true }
            return false
        }
        /// Provider/origin of the source: server name or torrent indexer.
        var provider: String? {
            switch origin {
            case .server: nil
            case .torrent(let r): r.indexer
            }
        }
    }

    struct Resolved {
        var options: [Option] = []
        var diagnostic: String?
        var hasAny: Bool { !options.isEmpty }
        /// A single server version and nothing else → play directly without asking.
        var soleServer: PlayVersion? {
            guard options.count == 1, case .server(let v) = options[0].origin else { return nil }
            return v
        }
    }

    /// Gathers sources for a movie or a specific episode.
    static func resolve(item: MediaItem, episode: TMDBBrowse.DiscoverEpisode? = nil) async -> Resolved {
        var result = Resolved()
        var serverVersions: [PlayVersion] = []

        // 1) Versions on Plex servers: from the item itself (if real) or from a library
        //    copy found by TMDB identity (if virtual).
        let realCopy: MediaItem?
        if item.isVirtual {
            if let tmdbID = item.tmdbID {
                realCopy = await DiscoverPlayback.libraryItem(tmdbID: tmdbID, isShow: item.type == "show")
            } else {
                realCopy = nil
            }
        } else {
            realCopy = item
        }
        if let realCopy {
            serverVersions = (try? await PlexPlayback.resolveVersions(
                item: realCopy, season: episode?.seasonNumber, episodeNumber: episode?.episodeNumber
            )) ?? []
        }
        result.options += serverVersions.map { Option(origin: .server($0)) }

        // 2) Torrents: only for virtual content from the TMDB catalog. Pure library content
        //    keeps the Plex behavior (fast, no external searches).
        if item.isVirtual, let discover = DiscoverItem(media: item) {
            let sources: DiscoverPlayback.Sources
            if let episode {
                sources = await DiscoverPlayback.resolveEpisode(item: discover, episode: episode)
            } else {
                sources = await DiscoverPlayback.resolve(item: discover)
            }
            result.options += sources.torrentReleases.map { Option(origin: .torrent($0)) }
            if result.options.isEmpty {
                // Clear message when there is NOTHING configured for playback (no
                // server and no Streaming Mode): the catalog is browsed with TMDB only.
                result.diagnostic = sources.diagnostic ?? tr(L.noSourcesConfigured)
            }
        }

        return result
    }

    /// Builds the `PlayableMedia` for a chosen option.
    static func playable(for option: Option, item: MediaItem, episode: TMDBBrowse.DiscoverEpisode?) async throws -> PlayableMedia {
        switch option.origin {
        case .server(let version):
            return version.media
        case .torrent(let release):
            guard let discover = DiscoverItem(media: item) else { throw PlaybackError.noContent }
            if let episode {
                return try await DiscoverPlayback.playableEpisode(from: release, item: discover, episode: episode)
            }
            return try await DiscoverPlayback.playable(from: release, item: discover)
        }
    }

    enum PlaybackError: LocalizedError {
        case noContent
        var errorDescription: String? { tr(L.playbackBuildFailed) }
    }
}
