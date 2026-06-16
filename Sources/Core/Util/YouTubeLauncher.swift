import UIKit

/// Opens a YouTube video in the YouTube tvOS app. tvOS has no web browser/WebKit,
/// so trailers (TMDB videos are almost always YouTube) are handed off to the
/// YouTube app via its URL scheme. Best-effort: tries the known schemes in order
/// and silently gives up if none can be opened (e.g. the app isn't installed).
enum YouTubeLauncher {
    @MainActor
    static func open(videoKey: String) {
        let candidates = [
            "youtube://www.youtube.com/watch?v=\(videoKey)",
            "youtube://\(videoKey)",
            "vnd.youtube://\(videoKey)",
            "https://www.youtube.com/watch?v=\(videoKey)",
        ].compactMap { URL(string: $0) }
        openFirst(candidates)
    }

    @MainActor
    private static func openFirst(_ urls: [URL]) {
        guard let url = urls.first else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { openFirst(Array(urls.dropFirst())) }
        }
    }
}
