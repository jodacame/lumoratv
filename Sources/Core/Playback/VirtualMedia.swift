import Foundation

/// Bridge between the TMDB virtual catalog and the single `MediaItem` model.
/// A "virtual" item lives on no server: empty `serverID`. The rest of the app
/// treats it like any other content — the source is resolved at playback time.
extension MediaItem {

    /// Is this a virtual item (from TMDB, with no server copy)?
    var isVirtual: Bool { serverID.isEmpty }

    /// Materializes a TMDB item into a full MediaItem (without touching the DB).
    static func virtual(from d: DiscoverItem, details: TMDBBrowse.Details, certification: String?) -> MediaItem {
        MediaItem(
            id: "tmdb:\(d.isShow ? "tv" : "movie"):\(d.tmdbID)",
            serverID: "",                          // no server → virtual
            ratingKey: String(d.tmdbID),
            libraryKey: "",
            type: d.isShow ? "show" : "movie",
            title: d.title,
            sortTitle: d.title,
            year: d.year,
            summary: d.overview,
            durationMs: details.runtimeMs,
            addedAt: 0,
            updatedAt: 0,
            viewCount: 0,
            viewOffsetMs: 0,
            lastViewedAt: nil,
            audienceRating: d.rating,
            contentRating: certification,
            genres: details.genres,
            tmdbID: d.tmdbID,
            thumbPath: nil,
            artPath: nil,
            logoURL: details.logoURL,
            videoResolution: nil,
            audioCodec: nil,
            audioChannels: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            tmdbTitle: d.title,
            tmdbSummary: d.overview,
            tmdbPosterPath: d.posterPath,
            tmdbBackdropPath: d.backdropPath,
            metaLang: nil,
            originalLanguage: details.originalLanguage,
            originCountry: details.originCountry
        )
    }

    /// Minimal version (poster/identity only) for virtual "similar" cards;
    /// when opened, the detail view enriches it with TMDB.
    static func virtualStub(from d: DiscoverItem) -> MediaItem {
        MediaItem(
            id: "tmdb:\(d.isShow ? "tv" : "movie"):\(d.tmdbID)",
            serverID: "",
            ratingKey: String(d.tmdbID),
            libraryKey: "",
            type: d.isShow ? "show" : "movie",
            title: d.title,
            sortTitle: d.title,
            year: d.year,
            summary: d.overview,
            durationMs: nil,
            addedAt: 0,
            updatedAt: 0,
            viewCount: 0,
            viewOffsetMs: 0,
            lastViewedAt: nil,
            audienceRating: d.rating,
            contentRating: nil,
            genres: "",
            tmdbID: d.tmdbID,
            thumbPath: nil,
            artPath: nil,
            logoURL: nil,
            videoResolution: nil,
            audioCodec: nil,
            audioChannels: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            tmdbTitle: d.title,
            tmdbSummary: d.overview,
            tmdbPosterPath: d.posterPath,
            tmdbBackdropPath: d.backdropPath,
            metaLang: nil,
            originalLanguage: nil,
            originCountry: nil
        )
    }

    /// Lazy enrichment of a virtual item (when opening its detail view).
    @MainActor
    func enrichedIfVirtual() async -> MediaItem {
        guard isVirtual, let tmdbID, genres.isEmpty, let key = SettingsStore.shared.tmdbKey else { return self }
        let isShow = type == "show"
        async let detailsTask = TMDBBrowse.details(tmdbID: tmdbID, isShow: isShow, key: key)
        async let certTask = TMDBBrowse.certification(tmdbID: tmdbID, isShow: isShow, key: key)
        let (details, cert) = await (detailsTask, certTask)
        var copy = self
        copy.genres = details.genres
        copy.durationMs = details.runtimeMs
        copy.logoURL = details.logoURL
        copy.originalLanguage = details.originalLanguage
        copy.originCountry = details.originCountry
        copy.contentRating = cert
        return copy
    }
}

extension DiscoverItem {
    /// Rebuilds a DiscoverItem from a MediaItem (to resolve torrents).
    init?(media: MediaItem) {
        guard let tmdbID = media.tmdbID else { return nil }
        self.init(
            tmdbID: tmdbID,
            isShow: media.type == "show",
            title: media.displayTitle,
            overview: media.displaySummary,
            posterPath: media.tmdbPosterPath,
            backdropPath: media.tmdbBackdropPath,
            year: media.year,
            rating: media.audienceRating
        )
    }
}
