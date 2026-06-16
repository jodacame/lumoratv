import Foundation

/// Season/episode detection in release and file names
/// (to distinguish single episodes from packs and pick the right file).
enum EpisodeMatch {

    /// Does the text contain exactly episode SxxEyy? (not an E inside a range).
    /// Accepts common separators: "S01E03", "s1.e3", "1x03".
    static func matchesExact(_ text: String, season: Int, episode: Int) -> Bool {
        let t = normalize(text)
        // sXXeYY format (with or without leading zeros) followed by something that isn't another digit.
        let sxe = "s0*\(season)[ ._-]?e0*\(episode)(?![0-9])"
        // Alternative NxMM format (1x03).
        let nx = "(?<![0-9])0*\(season)x0*\(episode)(?![0-9])"
        return regexMatches(t, sxe) || regexMatches(t, nx)
    }

    /// Does the text represent an episode range (E01-E10)? → it's a pack.
    static func isEpisodeRange(_ text: String) -> Bool {
        let t = normalize(text)
        return regexMatches(t, "e0*[0-9]+[ ._-]?-[ ._-]?e?0*[0-9]+")
    }

    /// Does it look like a full-season pack (no single episode)?
    static func looksLikePack(_ text: String, season: Int, episode: Int) -> Bool {
        let t = normalize(text)
        if isEpisodeRange(t) { return true }
        if t.contains("complete") || t.contains("full season") || t.contains("temporada completa") || t.contains("season pack") {
            return true
        }
        // Mentions the season but not the specific episode → pack.
        let mentionsSeason = regexMatches(t, "s0*\(season)(?![0-9])") || regexMatches(t, "season 0*\(season)(?![0-9])")
        return mentionsSeason && !matchesExact(t, season: season, episode: episode)
    }

    /// Ranks a release against the requested episode: 0 = exact episode, 1 = pack, 2 = other/ambiguous.
    static func rank(_ title: String, season: Int, episode: Int) -> Int {
        if matchesExact(title, season: season, episode: episode), !isEpisodeRange(title) { return 0 }
        if looksLikePack(title, season: season, episode: episode) { return 1 }
        return 2
    }

    /// Relevance of a release with respect to the requested episode.
    /// `.different` = clearly belongs to ANOTHER episode/season → must be discarded.
    enum Relevance: Int, Sendable {
        case exact = 0      // SxxEyy of the requested episode
        case pack = 1       // pack that contains it (range/season/complete series)
        case ambiguous = 2  // no clear episode marker (possibly a single or a series)
        case different = 3  // another episode or season
    }

    static func relevance(_ title: String, season: Int, episode: Int) -> Relevance {
        let t = normalize(title)

        // SxxEyy tokens (with a possible Eyyy range).
        var sawEpisodeToken = false
        for m in captures("s(\\d{1,2})[ ._-]?e(\\d{1,3})(?:[ ._-]?e(\\d{1,3}))?", t) {
            guard let s = Int(m[1]), let e1 = Int(m[2]) else { continue }
            sawEpisodeToken = true
            guard s == season else { continue }
            if m.count > 3, !m[3].isEmpty, let e2 = Int(m[3]) {
                if episode >= e1 && episode <= e2 { return .pack }   // range covers the episode
            } else if e1 == episode {
                return .exact
            }
        }
        // 1x03 format.
        for m in captures("(?<![0-9])(\\d{1,2})x(\\d{1,3})", t) {
            guard let s = Int(m[1]), let e = Int(m[2]) else { continue }
            sawEpisodeToken = true
            if s == season && e == episode { return .exact }
        }

        let packWords = ["complete", "full season", "season pack", "temporada completa", "integrale", "batch", "complete series", "serie completa"]
        let saysPack = packWords.contains { t.contains($0) }
        let mentionsSeason = regexMatches(t, "s0*\(season)(?![0-9])")
            || regexMatches(t, "season[ ._-]?0*\(season)(?![0-9])")
            || regexMatches(t, "temporada[ ._-]?0*\(season)(?![0-9])")
        let mentionsAnySeason = regexMatches(t, "s0*[0-9]+(?![0-9])")
            || regexMatches(t, "season[ ._-]?0*[0-9]+")
            || regexMatches(t, "temporada[ ._-]?0*[0-9]+")
        let mentionsOtherSeason = mentionsAnySeason && !mentionsSeason

        if saysPack {
            if mentionsSeason || !mentionsAnySeason { return .pack }
        }
        if sawEpisodeToken { return .different }     // had SxxEyy tokens but none matched
        if mentionsSeason { return .pack }           // "Season X" with no episodes
        if mentionsOtherSeason { return .different }
        return .ambiguous
    }

    private static func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
    }

    private static func regexMatches(_ text: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, range: range) != nil
    }
}
