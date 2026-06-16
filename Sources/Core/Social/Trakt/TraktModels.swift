import Foundation
import NaturalLanguage

// MARK: - Read models

/// A community comment from Trakt. Language is detected on-device (NaturalLanguage)
/// — no AI, no translation; comments stay in their original language.
struct TraktComment: Identifiable, Sendable {
    let id: Int
    let text: String
    let spoiler: Bool
    let isReview: Bool
    let likes: Int
    let userName: String
    let userRating: Int?     // the author's own 1–10 score, if any
    let createdAt: String?
    let lang: String         // detected ISO code, e.g. "en", "es", or "und"

    /// On-device language detection (no network, no AI).
    static func detectLanguage(_ text: String) -> String {
        guard text.count >= 8 else { return "und" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "und"
    }
}

/// Community content for a title/episode: aggregate rating + comments.
struct TraktContent: Sendable {
    var rating: Double?      // 0–10 community average
    var votes: Int
    var comments: [TraktComment]
    var isEmpty: Bool { comments.isEmpty && rating == nil }
    static let none = TraktContent(rating: nil, votes: 0, comments: [])
}

// MARK: - Identity

/// Identifies a piece of content for any Trakt endpoint, from our `tmdbID`
/// (+ season/episode for episodes). The single shape every method takes.
struct TraktRef: Sendable, Hashable {
    let tmdbID: Int
    let isShow: Bool
    let season: Int?     // episodes only
    let episode: Int?    // episodes only

    var isEpisode: Bool { season != nil && episode != nil }

    static func movie(_ tmdbID: Int) -> TraktRef { .init(tmdbID: tmdbID, isShow: false, season: nil, episode: nil) }
    static func show(_ tmdbID: Int) -> TraktRef { .init(tmdbID: tmdbID, isShow: true, season: nil, episode: nil) }
    static func episode(showTmdbID: Int, season: Int, number: Int) -> TraktRef {
        .init(tmdbID: showTmdbID, isShow: true, season: season, episode: number)
    }
}

// MARK: - Auth (device-code flow, phase 2)

/// Response of `POST /oauth/device/code`. The user enters `userCode` at
/// `verificationURL` (we show it as a QR, like plex.tv/link).
struct TraktDeviceCode: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let interval: Int       // seconds between polls
    let expiresIn: Int      // seconds until the code dies
}

/// Per-user OAuth tokens, persisted (Keychain, synchronizable) per `userID`.
struct TraktTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

// MARK: - Write actions

/// Scrobble action for `/scrobble/*` (phase 2 — reflects what you're watching on
/// your Trakt profile; NOT used for app sync, which Apple handles).
enum TraktScrobbleAction: String, Sendable {
    case start, pause, stop
}
