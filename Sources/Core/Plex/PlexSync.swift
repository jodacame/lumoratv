import Foundation

// MARK: - Plex metadata models

struct PlexMetadataContainer: Decodable, Sendable {
    struct MC: Decodable, Sendable {
        let Metadata: [PlexMeta]?
    }
    let MediaContainer: MC
}

struct PlexMeta: Decodable, Sendable {
    let ratingKey: String
    let title: String
    let titleSort: String?
    let type: String?
    let year: Int?
    let summary: String?
    let duration: Int?
    let addedAt: Int?
    let updatedAt: Int?
    let viewCount: Int?
    let viewOffset: Int?
    let lastViewedAt: Int?
    let audienceRating: Double?
    let contentRating: String?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let thumb: String?
    let art: String?
    let grandparentRatingKey: String?
    let parentIndex: Int?
    let index: Int?

    struct Tag: Decodable, Sendable { let tag: String }
    let Genre: [Tag]?

    struct GuidEntry: Decodable, Sendable { let id: String }
    let Guid: [GuidEntry]?

    struct MediaInfo: Decodable, Sendable {
        let videoResolution: String?
        let audioCodec: String?
        let audioChannels: Int?
    }
    let Media: [MediaInfo]?

    var tmdbID: Int? {
        Guid?.compactMap { entry -> Int? in
            entry.id.hasPrefix("tmdb://") ? Int(entry.id.dropFirst(7)) : nil
        }.first
    }
}

// MARK: - Fetchers

extension PlexClient {
    /// Downloads all items in a section, paginating.
    /// type: 1=movie, 2=show, 4=episode
    static func fetchSectionItems(baseURL: String, token: String, sectionKey: String, type: Int) async throws -> [PlexMeta] {
        var all: [PlexMeta] = []
        var start = 0
        let pageSize = 400
        while true {
            var comps = URLComponents(string: baseURL + "/library/sections/\(sectionKey)/all")!
            comps.queryItems = [
                URLQueryItem(name: "type", value: String(type)),
                URLQueryItem(name: "includeGuids", value: "1"),
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize)),
            ]
            let req = request(comps.url!, token: token)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PlexError.badResponse }
            let batch = try JSONDecoder().decode(PlexMetadataContainer.self, from: data).MediaContainer.Metadata ?? []
            all.append(contentsOf: batch)
            if batch.count < pageSize { break }
            start += pageSize
        }
        return all
    }

    /// Items modified since a given moment: sorted by updatedAt desc with early cutoff.
    /// Much cheaper than the full catalog for frequent syncs.
    static func fetchSectionItemsUpdatedSince(
        baseURL: String, token: String, sectionKey: String, type: Int, since: Int
    ) async throws -> [PlexMeta] {
        var all: [PlexMeta] = []
        var start = 0
        let pageSize = 200
        while true {
            var comps = URLComponents(string: baseURL + "/library/sections/\(sectionKey)/all")!
            comps.queryItems = [
                URLQueryItem(name: "type", value: String(type)),
                URLQueryItem(name: "includeGuids", value: "1"),
                URLQueryItem(name: "sort", value: "updatedAt:desc"),
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize)),
            ]
            let req = request(comps.url!, token: token)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PlexError.badResponse }
            let batch = try JSONDecoder().decode(PlexMetadataContainer.self, from: data).MediaContainer.Metadata ?? []
            for meta in batch {
                let stamp = max(meta.updatedAt ?? 0, meta.addedAt ?? 0)
                if stamp >= since {
                    all.append(meta)
                } else {
                    return all  // cutoff: the rest is older
                }
            }
            if batch.count < pageSize { break }
            start += pageSize
        }
        return all
    }

    /// URL of an image transcoded by Plex to the requested size.
    static func imageURL(baseURL: String, token: String, path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var comps = URLComponents(string: baseURL + "/photo/:/transcode")
        comps?.queryItems = [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        return comps?.url
    }
}

// MARK: - Mapping to local records

extension MediaItem {
    @MainActor
    var server: PlexServerRef? { SettingsStore.shared.server(id: serverID) }

    /// Poster in the user's language (TMDB) with fallback to the Plex one (on its server).
    @MainActor
    func posterURL(width: Int, height: Int) -> URL? {
        if let tmdbPosterPath {
            return URL(string: "https://image.tmdb.org/t/p/w500" + tmdbPosterPath)
        }
        return plexImageURL(path: thumbPath, width: width, height: height)
    }

    /// Backdrop (art) from its server, with fallback to TMDB (virtual items without a server).
    @MainActor
    func artURL(width: Int, height: Int) -> URL? {
        if let url = plexImageURL(path: artPath ?? thumbPath, width: width, height: height) {
            return url
        }
        if let tmdbBackdropPath {
            return URL(string: "https://image.tmdb.org/t/p/w1280" + tmdbBackdropPath)
        }
        return nil
    }

    @MainActor
    func plexImageURL(path: String?, width: Int, height: Int) -> URL? {
        guard let server, let token = SettingsStore.shared.token(forServer: serverID) else { return nil }
        return PlexClient.imageURL(baseURL: server.url, token: token, path: path, width: width, height: height)
    }
}

/// Enriched fields that survive a re-sync.
struct PreservedMeta: Sendable {
    let logoURL: String?
    let tmdbTitle: String?
    let tmdbSummary: String?
    let tmdbPosterPath: String?
    let metaLang: String?
    let originalLanguage: String?
    let originCountry: String?
}

extension MediaItem {
    init(meta: PlexMeta, serverID: String, libraryKey: String, type: String, preserved: PreservedMeta?) {
        self.init(
            id: "\(serverID):\(meta.ratingKey)",
            serverID: serverID,
            ratingKey: meta.ratingKey,
            libraryKey: libraryKey,
            type: type,
            title: meta.title,
            sortTitle: meta.titleSort ?? meta.title,
            year: meta.year,
            summary: meta.summary ?? "",
            durationMs: meta.duration,
            addedAt: meta.addedAt ?? 0,
            updatedAt: meta.updatedAt ?? 0,
            viewCount: meta.viewCount ?? 0,
            viewOffsetMs: meta.viewOffset ?? 0,
            lastViewedAt: meta.lastViewedAt,
            audienceRating: meta.audienceRating,
            contentRating: meta.contentRating,
            genres: (meta.Genre ?? []).map(\.tag).joined(separator: "|"),
            tmdbID: meta.tmdbID,
            thumbPath: meta.thumb,
            artPath: meta.art,
            logoURL: preserved?.logoURL,
            videoResolution: meta.Media?.first?.videoResolution,
            audioCodec: meta.Media?.first?.audioCodec,
            audioChannels: meta.Media?.first?.audioChannels,
            leafCount: meta.leafCount,
            viewedLeafCount: meta.viewedLeafCount,
            tmdbTitle: preserved?.tmdbTitle,
            tmdbSummary: preserved?.tmdbSummary,
            tmdbPosterPath: preserved?.tmdbPosterPath,
            tmdbBackdropPath: nil,
            metaLang: preserved?.metaLang,
            originalLanguage: preserved?.originalLanguage,
            originCountry: preserved?.originCountry
        )
    }
}

extension Episode {
    init?(meta: PlexMeta, serverID: String) {
        guard let showKey = meta.grandparentRatingKey else { return nil }
        self.init(
            id: "\(serverID):\(meta.ratingKey)",
            serverID: serverID,
            ratingKey: meta.ratingKey,
            showKey: "\(serverID):\(showKey)",
            seasonNumber: meta.parentIndex ?? 0,
            episodeNumber: meta.index ?? 0,
            title: meta.title,
            durationMs: meta.duration,
            viewOffsetMs: meta.viewOffset ?? 0,
            viewCount: meta.viewCount ?? 0,
            lastViewedAt: meta.lastViewedAt,
            addedAt: meta.addedAt ?? 0,
            thumbPath: meta.thumb
        )
    }
}
