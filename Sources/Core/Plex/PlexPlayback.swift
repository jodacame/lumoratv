import Foundation
import GRDB

/// External (sidecar) subtitle served by Plex.
struct ExternalSubtitle: Sendable, Equatable, Hashable {
    let title: String?
    let lang: String?
    let url: URL
}

/// Plex marker (intro / credits).
struct PlayerMarker: Sendable, Equatable {
    let type: String      // "intro" | "credits"
    let startMs: Int
    let endMs: Int
}

/// Everything needed to play a file via direct play.
struct PlayableMedia: Identifiable, Sendable, Equatable {
    var id: String { "\(serverID):\(ratingKey)" }
    let ratingKey: String       // ratingKey of the played item on ITS server
    let serverID: String
    let watchKey: String        // per-content progress key (crosses servers)
    let refID: String           // concrete DB row (for mapping back)
    let isEpisode: Bool
    let title: String
    let subtitle: String?       // "T2 · E4 — Episode name"
    let url: URL
    let durationMs: Int
    var startOffsetMs: Int
    let artPath: String?
    let thumbPath: String?
    let logoURL: String?
    let partID: Int?
    let hasPreviewThumbnails: Bool
    let year: Int?
    let rating: Double?
    let contentRating: String?
    let resolution: String?
    let videoCodec: String?
    let fileSizeGB: Double?
    var hdrLabel: String? = nil   // "DV" | "HDR10" | "HLG"
    let tmdbID: Int?
    let tmdbIsShow: Bool
    let summary: String
    let genres: String
    var externalSubs: [ExternalSubtitle] = []
    var markers: [PlayerMarker] = []
    /// false for trailers and extras: progress is not reported.
    var reportsProgress: Bool = true
    /// Season/episode (to play the next one from the same torrent pack).
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    /// Provider/indexer of the torrent in use (to show which site it comes from).
    var sourceProvider: String? = nil
    /// Release group / uploader of the torrent in use (feeds `UploaderReputation`).
    var sourceGroup: String? = nil
    /// Preview: after playing this many ms (from startOffset) it closes by itself.
    var previewDurationMs: Int? = nil
    /// Torrent to resolve INSIDE the player (opens right away and resolves the stream with feedback).
    var pendingTorrent: PendingTorrent? = nil
}

/// Data to resolve a torrent stream inside the player (without blocking the detail view).
struct PendingTorrent: Sendable, Equatable {
    var release: TorrentRelease
    var item: DiscoverItem
    var episode: TMDBBrowse.DiscoverEpisode?
    /// Resume decision made in the detail screen: nil = use the saved offset,
    /// 0 = play from the start (the user chose so in the resume prompt).
    var startOverrideMs: Int? = nil
    /// true when this is the user's remembered choice (continue watching):
    /// startup gets extra patience and a failure clears the memory.
    var isRemembered: Bool = false
}

extension PlayableMedia {
    @MainActor
    func plexImageURL(path: String?, width: Int, height: Int) -> URL? {
        guard let server = SettingsStore.shared.server(id: serverID),
              let token = SettingsStore.shared.token(forServer: serverID) else { return nil }
        return PlexClient.imageURL(baseURL: server.url, token: token, path: path, width: width, height: height)
    }
}

/// A playable version of a piece of content (there may be several across servers or on the same one).
struct PlayVersion: Identifiable, Sendable, Equatable {
    let id: String
    let serverName: String
    let resolution: String?
    let videoCodec: String?
    let fileSizeGB: Double?
    let hdr: String?
    let audioLangs: [String]
    let subtitleLangs: [String]
    let media: PlayableMedia

    var qualityLabel: String {
        var parts: [String] = []
        if let resolution {
            parts.append(resolution.lowercased() == "4k" ? "4K" : resolution.uppercased())
        }
        if let videoCodec { parts.append(videoCodec.uppercased()) }
        if let hdr { parts.append(hdr) }
        if let fileSizeGB { parts.append(String(format: "%.1f GB", fileSizeGB)) }
        return parts.joined(separator: " · ")
    }
}

enum PlaybackError: LocalizedError {
    case noMedia
    case notReachable

    var errorDescription: String? {
        switch self {
        case .noMedia: "No media parts found."
        case .notReachable: "Server not reachable."
        }
    }
}

enum PlexPlayback {

    // MARK: Version resolution

    /// Returns all playable versions of a piece of content, across servers.
    /// For shows, it first resolves the current user's next episode.
    @MainActor
    static func resolveVersions(item: MediaItem, season: Int? = nil, episodeNumber: Int? = nil) async throws -> [PlayVersion] {
        let userID = UserContext.currentUserID
        let states = await WatchStore.states(userID: userID)

        // Copies of the same content across all servers.
        let mergeKey = item.mergeKey
        let copies: [MediaItem] = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(Column("type") == item.type).fetchAll(db)
        })?.filter { $0.mergeKey == mergeKey } ?? [item]

        var versions: [PlayVersion] = []

        if item.type == "movie" {
            let startOffset = states[item.watchKey]?.viewOffsetMs ?? 0
            for copy in copies {
                guard let server = copy.server,
                      let token = SettingsStore.shared.token(forServer: copy.serverID) else { continue }
                let (infos, markers) = await fetchVersionInfos(baseURL: server.url, token: token, ratingKey: copy.ratingKey)
                for info in infos {
                    versions.append(makeVersion(
                        info: info, copy: copy, server: server,
                        watchKey: item.watchKey, refID: copy.id, isEpisode: false,
                        title: item.displayTitle, subtitle: nil,
                        startOffsetMs: startOffset, item: item, markers: markers
                    ))
                }
            }
        } else {
            // Explicit episode, or the next one according to the user.
            let episode: Episode
            if let season, let episodeNumber {
                episode = try await specificEpisode(showCopies: copies, season: season, number: episodeNumber)
            } else {
                episode = try await nextEpisode(showCopies: copies, states: states)
            }
            let epWatchKey = episodeWatchKey(showMergeKey: mergeKey, season: episode.seasonNumber, number: episode.episodeNumber)
            let startOffset = states[epWatchKey]?.viewOffsetMs ?? 0
            let subtitle = "T\(episode.seasonNumber) · E\(episode.episodeNumber) — \(episode.title)"

            // The same episode on every server that has the show.
            for copy in copies {
                guard let server = copy.server,
                      let token = SettingsStore.shared.token(forServer: copy.serverID) else { continue }
                guard let copyEpisode = try? await AppDatabase.shared.dbQueue.read({ db in
                    try Episode
                        .filter(Column("showKey") == copy.id
                                && Column("seasonNumber") == episode.seasonNumber
                                && Column("episodeNumber") == episode.episodeNumber)
                        .fetchOne(db)
                }) else { continue }

                let (infos, markers) = await fetchVersionInfos(baseURL: server.url, token: token, ratingKey: copyEpisode.ratingKey)
                for info in infos {
                    versions.append(makeVersion(
                        info: info, copy: copy, server: server,
                        watchKey: epWatchKey, refID: copyEpisode.id, isEpisode: true,
                        title: item.displayTitle, subtitle: subtitle,
                        startOffsetMs: startOffset, item: item, markers: markers,
                        overrideRatingKey: copyEpisode.ratingKey
                    ))
                }
            }
        }

        guard !versions.isEmpty else { throw PlaybackError.noMedia }
        // Best quality first, local first.
        return versions.sorted { ($0.fileSizeGB ?? 0) > ($1.fileSizeGB ?? 0) }
    }

    static func episodeWatchKey(showMergeKey: String, season: Int, number: Int) -> String {
        "ep:\(showMergeKey):s\(season)e\(number)"
    }

    private static func makeVersion(
        info: VersionInfo,
        copy: MediaItem,
        server: PlexServerRef,
        watchKey: String,
        refID: String,
        isEpisode: Bool,
        title: String,
        subtitle: String?,
        startOffsetMs: Int,
        item: MediaItem,
        markers: [PlayerMarker],
        overrideRatingKey: String? = nil
    ) -> PlayVersion {
        let media = PlayableMedia(
            ratingKey: overrideRatingKey ?? copy.ratingKey,
            serverID: copy.serverID,
            watchKey: watchKey,
            refID: refID,
            isEpisode: isEpisode,
            title: title,
            subtitle: subtitle,
            url: info.url,
            durationMs: info.durationMs ?? item.durationMs ?? 0,
            startOffsetMs: startOffsetMs,
            artPath: item.artPath,
            thumbPath: item.thumbPath,
            logoURL: item.logoURL,
            partID: info.partID,
            hasPreviewThumbnails: info.hasIndexes,
            year: item.year,
            rating: item.audienceRating,
            contentRating: item.contentRating,
            resolution: info.resolution,
            videoCodec: info.videoCodec,
            fileSizeGB: info.fileSizeGB,
            hdrLabel: info.hdr,
            tmdbID: item.tmdbID,
            tmdbIsShow: item.type == "show",
            summary: item.displaySummary,
            genres: item.genres,
            externalSubs: info.externalSubs,
            markers: markers
        )
        return PlayVersion(
            id: "\(copy.serverID):\(info.partID ?? 0):\(info.url.absoluteString.hashValue)",
            serverName: server.name,
            resolution: info.resolution,
            videoCodec: info.videoCodec,
            fileSizeGB: info.fileSizeGB,
            hdr: info.hdr,
            audioLangs: info.audioLangs,
            subtitleLangs: info.subtitleLangs,
            media: media
        )
    }

    private static func specificEpisode(showCopies: [MediaItem], season: Int, number: Int) async throws -> Episode {
        let showKeys = showCopies.map(\.id)
        guard let episode = try? await AppDatabase.shared.dbQueue.read({ db in
            try Episode
                .filter(showKeys.contains(Column("showKey"))
                        && Column("seasonNumber") == season
                        && Column("episodeNumber") == number)
                .fetchOne(db)
        }) else { throw PlaybackError.noMedia }
        return episode
    }

    private static func nextEpisode(showCopies: [MediaItem], states: [String: WatchState]) async throws -> Episode {
        let showKeys = showCopies.map(\.id)
        let mergeKey = showCopies.first?.mergeKey ?? ""
        let episodes: [Episode] = (try? await AppDatabase.shared.dbQueue.read { db in
            try Episode
                .filter(showKeys.contains(Column("showKey")))
                .order(Column("seasonNumber").asc, Column("episodeNumber").asc)
                .fetchAll(db)
        }) ?? []
        guard !episodes.isEmpty else { throw PlaybackError.noMedia }

        // Dedup by S/E across servers.
        var seen = Set<String>()
        var unique: [Episode] = []
        for ep in episodes {
            let key = "s\(ep.seasonNumber)e\(ep.episodeNumber)"
            if seen.insert(key).inserted { unique.append(ep) }
        }

        func state(_ ep: Episode) -> WatchState? {
            states[episodeWatchKey(showMergeKey: mergeKey, season: ep.seasonNumber, number: ep.episodeNumber)]
        }

        if let inProgress = unique
            .filter({ (state($0)?.viewOffsetMs ?? 0) > 0 })
            .max(by: { (state($0)?.lastViewedAt ?? 0) < (state($1)?.lastViewedAt ?? 0) }) {
            return inProgress
        }
        if let unseen = unique.first(where: { (state($0)?.viewCount ?? 0) == 0 }) {
            return unseen
        }
        return unique[0]
    }

    // MARK: Version details (Media/Part/Stream)

    private struct VersionInfo {
        let url: URL
        let durationMs: Int?
        let partID: Int?
        let hasIndexes: Bool
        let resolution: String?
        let videoCodec: String?
        let fileSizeGB: Double?
        let audioLangs: [String]
        let subtitleLangs: [String]
        let externalSubs: [ExternalSubtitle]
        let hdr: String?
    }

    private static func fetchVersionInfos(baseURL: String, token: String, ratingKey: String) async -> ([VersionInfo], [PlayerMarker]) {
        struct Container: Decodable {
            struct MC: Decodable {
                struct Meta: Decodable {
                    struct MediaInfo: Decodable {
                        struct Part: Decodable {
                            struct Stream: Decodable {
                                let streamType: Int
                                let language: String?
                                let languageTag: String?
                                let displayTitle: String?
                                let key: String?      // present only on external subtitles
                                let colorTrc: String?     // smpte2084 = HDR10 · arib-std-b67 = HLG
                                let DOVIPresent: Bool?    // Dolby Vision
                            }
                            let id: Int?
                            let key: String
                            let duration: Int?
                            let size: Int64?
                            let indexes: String?
                            let Stream: [Stream]?
                        }
                        let videoResolution: String?
                        let videoCodec: String?
                        let duration: Int?
                        let Part: [Part]?
                    }
                    struct PlexMarker: Decodable {
                        let type: String?
                        let startTimeOffset: Int?
                        let endTimeOffset: Int?
                    }
                    let Media: [MediaInfo]?
                    let Marker: [PlexMarker]?
                }
                let Metadata: [Meta]?
            }
            let MediaContainer: MC
        }

        guard let url = URL(string: baseURL + "/library/metadata/\(ratingKey)?includeMarkers=1") else { return ([], []) }
        guard let (data, resp) = try? await URLSession.shared.data(for: PlexClient.request(url, token: token)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let container = try? JSONDecoder().decode(Container.self, from: data),
              let meta = container.MediaContainer.Metadata?.first,
              let mediaList = meta.Media else { return ([], []) }

        let markers: [PlayerMarker] = (meta.Marker ?? []).compactMap { marker in
            guard let type = marker.type, let start = marker.startTimeOffset, let end = marker.endTimeOffset,
                  type == "intro" || type == "credits" else { return nil }
            return PlayerMarker(type: type, startMs: start, endMs: end)
        }

        var infos: [VersionInfo] = []
        for media in mediaList {
            guard let part = media.Part?.first else { continue }
            var comps = URLComponents(string: baseURL + part.key)
            comps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
            guard let fileURL = comps?.url else { continue }

            let streams = part.Stream ?? []
            let audio = streams.filter { $0.streamType == 2 }
                .compactMap { $0.language ?? $0.languageTag }
            let subs = streams.filter { $0.streamType == 3 }
                .compactMap { $0.language ?? $0.languageTag }
            let videoStreams = streams.filter { $0.streamType == 1 }
            let hdrLabel: String? = {
                if videoStreams.contains(where: { $0.DOVIPresent == true }) { return "DV" }
                if videoStreams.contains(where: { $0.colorTrc == "smpte2084" }) { return "HDR10" }
                if videoStreams.contains(where: { $0.colorTrc == "arib-std-b67" }) { return "HLG" }
                return nil
            }()
            let external: [ExternalSubtitle] = streams
                .filter { $0.streamType == 3 && $0.key != nil }
                .compactMap { stream in
                    var subComps = URLComponents(string: baseURL + (stream.key ?? ""))
                    subComps?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
                    guard let subURL = subComps?.url else { return nil }
                    return ExternalSubtitle(title: stream.displayTitle, lang: stream.language ?? stream.languageTag, url: subURL)
                }

            infos.append(VersionInfo(
                url: fileURL,
                durationMs: part.duration ?? media.duration,
                partID: part.id,
                hasIndexes: part.indexes != nil,
                resolution: media.videoResolution,
                videoCodec: media.videoCodec,
                fileSizeGB: part.size.map { Double($0) / 1_073_741_824 },
                audioLangs: Array(NSOrderedSet(array: audio)) as? [String] ?? audio,
                subtitleLangs: Array(NSOrderedSet(array: subs)) as? [String] ?? subs,
                externalSubs: external,
                hdr: hdrLabel
            ))
        }
        return (infos, markers)
    }

    enum NextEpisodeOutcome: Sendable {
        case available(PlayableMedia)
        case missing(season: Int, episode: Int)
        case seriesEnd
    }

    /// Library item associated with what is playing (movie, or the episode's show).
    @MainActor
    static func libraryItem(for media: PlayableMedia) async -> MediaItem? {
        if media.isEpisode {
            guard let episode = try? await AppDatabase.shared.dbQueue.read({ db in
                try Episode.filter(Column("id") == media.refID).fetchOne(db)
            }) else { return nil }
            return try? await AppDatabase.shared.dbQueue.read { db in
                try MediaItem.filter(Column("id") == episode.showKey).fetchOne(db)
            }
        }
        return try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(Column("id") == media.refID).fetchOne(db)
        }
    }

    /// What comes after an episode: available, missing (with the expected S/E), or end of series.
    @MainActor
    static func nextEpisodeOutcome(after media: PlayableMedia) async -> NextEpisodeOutcome? {
        guard media.isEpisode else { return nil }
        guard let current = try? await AppDatabase.shared.dbQueue.read({ db in
            try Episode.filter(Column("id") == media.refID).fetchOne(db)
        }) else { return nil }
        guard let showCopy = try? await AppDatabase.shared.dbQueue.read({ db in
            try MediaItem.filter(Column("id") == current.showKey).fetchOne(db)
        }) else { return nil }

        // Episodes from all copies of the show, deduped by S/E, in order.
        let mergeKey = showCopy.mergeKey
        let copies: [MediaItem] = ((try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(Column("type") == "show").fetchAll(db)
        }) ?? []).filter { $0.mergeKey == mergeKey }
        let showKeys = copies.map(\.id)
        let episodes: [Episode] = (try? await AppDatabase.shared.dbQueue.read { db in
            try Episode
                .filter(showKeys.contains(Column("showKey")))
                .order(Column("seasonNumber").asc, Column("episodeNumber").asc)
                .fetchAll(db)
        }) ?? []

        var seen = Set<String>()
        let unique = episodes.filter { seen.insert("s\($0.seasonNumber)e\($0.episodeNumber)").inserted }

        // Expected episode according to TMDB (detects gaps); without TMDB, the next local one.
        var expected: (season: Int, episode: Int)?
        if let tmdbKey = SettingsStore.shared.tmdbKey, let tmdbID = showCopy.tmdbID {
            let seasons = await TMDBClient.tvSeasons(tmdbID: tmdbID, key: tmdbKey)
            let counts = seasons.reduce(into: [Int: Int]()) { $0[$1.number] = $1.episodeCount }
            if let count = counts[current.seasonNumber], current.episodeNumber < count {
                expected = (current.seasonNumber, current.episodeNumber + 1)
            } else if let nextSeason = counts.keys.filter({ $0 > current.seasonNumber }).min(),
                      (counts[nextSeason] ?? 0) > 0 {
                expected = (nextSeason, 1)
            }
        } else if let nextLocal = unique.first(where: {
            ($0.seasonNumber, $0.episodeNumber) > (current.seasonNumber, current.episodeNumber)
        }) {
            expected = (nextLocal.seasonNumber, nextLocal.episodeNumber)
        }

        guard let expected else { return .seriesEnd }

        let hasLocal = unique.contains { $0.seasonNumber == expected.season && $0.episodeNumber == expected.episode }
        guard hasLocal else { return .missing(season: expected.season, episode: expected.episode) }

        let versions = (try? await resolveVersions(item: showCopy, season: expected.season, episodeNumber: expected.episode)) ?? []
        guard let best = versions.first else {
            return .missing(season: expected.season, episode: expected.episode)
        }
        return .available(best.media)
    }

    /// Preview thumbnail at a given timestamp (requires "video preview thumbnails" in Plex).
    @MainActor
    static func previewThumbnailURL(partID: Int, timeMs: Int, serverID: String) -> URL? {
        guard let server = SettingsStore.shared.server(id: serverID),
              let token = SettingsStore.shared.token(forServer: serverID) else { return nil }
        var comps = URLComponents(string: server.url + "/photo/:/transcode")
        comps?.queryItems = [
            URLQueryItem(name: "width", value: "480"),
            URLQueryItem(name: "height", value: "270"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "url", value: "/library/parts/\(partID)/indexes/sd/\(timeMs)"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        return comps?.url
    }

    // MARK: Progress reporting

    enum TimelineState: String {
        case playing, paused, stopped
    }

    static func reportTimeline(media: PlayableMedia, state: TimelineState, timeMs: Int, durationMs: Int) async {
        // 1) To Plex (the server that owns the file), at the general level.
        let serverInfo = await MainActor.run { () -> (String, String)? in
            guard let server = SettingsStore.shared.server(id: media.serverID),
                  let token = SettingsStore.shared.token(forServer: media.serverID) else { return nil }
            return (server.url, token)
        }
        if let (baseURL, token) = serverInfo {
            var comps = URLComponents(string: baseURL + "/:/timeline")
            comps?.queryItems = [
                URLQueryItem(name: "ratingKey", value: media.ratingKey),
                URLQueryItem(name: "key", value: "/library/metadata/\(media.ratingKey)"),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "state", value: state.rawValue),
                URLQueryItem(name: "time", value: String(timeMs)),
                URLQueryItem(name: "duration", value: String(durationMs)),
                URLQueryItem(name: "X-Plex-Token", value: token),
            ]
            if let url = comps?.url {
                _ = try? await URLSession.shared.data(for: PlexClient.request(url, token: token))
            }
        }

        // 2) Internal per-user state, keyed by content identity.
        let userID = await MainActor.run { UserContext.currentUserID }
        await WatchStore.update(
            userID: userID,
            watchKey: media.watchKey,
            refID: media.refID,
            isEpisode: media.isEpisode,
            timeMs: timeMs,
            durationMs: durationMs
        )
    }

}
