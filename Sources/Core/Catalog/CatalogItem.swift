import SwiftUI

/// Unified catalog model: the UI does not distinguish whether a title lives on a server
/// or only on TMDB. Everything looks the same; the source is resolved at playback time.
struct CatalogItem: Identifiable, Hashable, Sendable {
    let tmdbID: Int?
    let isShow: Bool
    let title: String
    let year: Int?
    let rating: Double?
    let posterURL: URL?

    /// Backing data: local copy if it exists (server path) or TMDB item (discover path).
    let local: MediaItem?
    let discover: DiscoverItem?

    let id: String

    static func == (a: CatalogItem, b: CatalogItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    @MainActor
    init(local item: MediaItem) {
        tmdbID = item.tmdbID
        isShow = item.type == "show"
        title = item.displayTitle
        year = item.year
        rating = item.audienceRating
        posterURL = item.posterURL(width: 400, height: 600)
        local = item
        discover = nil
        id = item.tmdbID.map { "\(item.type == "show" ? "tv" : "movie")-\($0)" } ?? item.id
    }

    init(discover item: DiscoverItem) {
        tmdbID = item.tmdbID
        isShow = item.isShow
        title = item.title
        year = item.year
        rating = item.rating
        posterURL = item.posterURL
        local = nil
        discover = item
        id = item.id
    }
}

/// Opens the right detail view for a CatalogItem without the user noticing the source.
struct CatalogDetailRouter: View {
    let item: CatalogItem

    var body: some View {
        if let local = item.local {
            DetailView(item: local)
        } else if let discover = item.discover {
            DiscoverRouter(item: discover)
        } else {
            Theme.background
        }
    }
}
