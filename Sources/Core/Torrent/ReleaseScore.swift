import Foundation

/// Composite ranking for torrent releases — defines what "best source" means:
/// video quality, swarm health (seeders), the user's preferred audio/subtitle
/// languages, a reasonable size, freeleech, and the indexer's learned
/// reputation (see `IndexerReputation`).
///
/// Reads the language preferences straight from UserDefaults so it can run
/// from any isolation context (search runs off the main actor).
enum ReleaseScore {

    static func score(_ r: TorrentRelease) -> Double {
        var score = 0.0

        // 1) Video quality — bigger is better; unknown sits in the middle.
        let qualityPoints: Double = switch r.quality {
        case "4K": 100
        case "1080p": 85
        case "720p": 55
        case "480p": 25
        default: 50
        }
        score += qualityPoints

        // 2) Swarm health — dead torrents sink to the bottom of the list.
        if r.seeders <= 0 {
            score -= 80
        } else {
            score += 60.0 * min(Double(r.seeders), 100) / 100
        }

        // 3) Language match against the user's audio/subtitle preferences.
        score += languageBonus(r)

        // 4) Reasonable size — penalize releases far above what their
        //    resolution justifies (huge remuxes the network may not sustain).
        //    Hard ceiling philosophy: nothing should need more than ~20 GB.
        let allowanceGB: Double = switch r.quality {
        case "4K": 20
        case "1080p": 10
        case "720p": 4
        default: 6
        }
        if r.sizeGB > allowanceGB {
            score -= min(60, (r.sizeGB - allowanceGB) * 3)
        }

        // 5) Freeleech — kinder to private-tracker ratios, so prefer it.
        if r.isFreeleech { score += 25 }

        // 6) Indexer reputation learned from real playback outcomes.
        score += IndexerReputation.score(indexer: r.indexer) * 40

        // 7) Uploader (release group) reputation learned from real viewing
        //    behavior — groups whose releases get watched to the end with
        //    their embedded subtitles rank up. Lower weight than the indexer
        //    because the identity comes from a noisier title parse.
        score += UploaderReputation.score(uploader: r.releaseGroup) * 25

        // 8) Hardware-friendly encode — Apple TV decodes HEVC/H.264 (standard
        //    4:2:0 web/bluray) in hardware → smooth playback. AV1, 4:2:2 and
        //    12-bit fall back to software and can stutter on 4K, so they earn
        //    no bonus and stay below an equivalent standard encode.
        score += standardEncodeBonus(r)

        return score
    }

    /// Rewards encodes the Apple TV plays in hardware. Positive-only: it lifts
    /// standard releases rather than punishing others.
    private static func standardEncodeBonus(_ r: TorrentRelease) -> Double {
        let t = r.title.lowercased()
        // Markers of encodes that fall back to SOFTWARE on Apple TV → no bonus.
        let softwareOnly = t.contains("4:2:2") || t.contains(" 422 ") || t.contains(".422.")
            || t.contains("4:4:4") || t.contains("12bit") || t.contains("12-bit") || t.contains("12 bit")
        if softwareOnly { return 0 }

        var bonus = 0.0
        switch r.codec {
        case "HEVC": bonus += 20   // hardware-decoded + space-efficient: the sweet spot
        case "H264": bonus += 12   // always hardware-decoded, just bulkier
        default: break             // AV1 / unknown: no hardware decode on Apple TV
        }
        // Clean distribution source (standard 4:2:0) — plays reliably.
        if t.contains("web-dl") || t.contains("webdl") || t.contains("webrip")
            || t.contains("bluray") || t.contains("blu-ray") || t.contains("bdrip") {
            bonus += 8
        }
        return bonus
    }

    /// Bonus when the release's language tags match the configured audio
    /// (strong) and subtitle (mild) preferences. MULTI/DUAL releases likely
    /// include the preferred track.
    private static func languageBonus(_ r: TorrentRelease) -> Double {
        let defaults = UserDefaults.standard
        let audio = defaults.string(forKey: "audioLang") ?? "auto"
        let subs = defaults.string(forKey: "subtitleLang") ?? "off"
        let badges = r.languageBadges
        let multi = badges.contains("MULTI") || badges.contains("DUAL")
        var bonus = 0.0

        switch audio {
        case "es":
            if badges.contains("ES (LAT)") || badges.contains("ES (CAST)") {
                bonus += 45
            } else if multi {
                bonus += 25
            }
        case "en":
            let foreignAudio = badges.contains { $0 != "EN" && !$0.hasPrefix("SUB") && $0 != "MULTI" && $0 != "DUAL" }
            if badges.contains("EN") || multi {
                bonus += 25
            } else if !foreignAudio {
                // Untagged releases are almost always English audio.
                bonus += 15
            }
        default:
            break   // "auto": no language preference.
        }

        if subs == "es", badges.contains("SUB ES") || badges.contains("SUB") {
            bonus += 15
        }
        return bonus
    }
}
