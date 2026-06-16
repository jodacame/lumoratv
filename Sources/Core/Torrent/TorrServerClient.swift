import Foundation
import NaturalLanguage

/// Torrent→HTTP bridge: adds a magnet to TorrServer and gets the stream URL
/// of the largest video file. TorrServer runs outside the Apple TV.
enum TorrServerClient {

    enum TorrError: LocalizedError {
        case notConfigured, noMagnet, addFailed, noPlayableFile, compressed, metadataTimeout
        var errorDescription: String? {
            switch self {
            case .notConfigured: tr(L.torrServerNotConfigured)
            case .noMagnet: "El release no tiene un enlace magnet."
            case .addFailed: tr(L.torrServerAddFailed)
            case .noPlayableFile: "El torrent no contiene un archivo de video reproducible."
            case .compressed: tr(L.torrentCompressed)
            case .metadataTimeout: tr(L.torrentMetadataTimeout)
            }
        }
    }

    private static let archiveExtensions = ["rar", "zip", "7z", "001", "r00", "r01", "tar", "gz"]

    private static let videoExtensions = ["mkv", "mp4", "avi", "m4v", "mov", "ts", "webm", "flv", "wmv", "mpg", "mpeg"]
    private static let subtitleExtensions = ["srt", "ass", "ssa", "sub", "vtt"]

    struct Resolved: Sendable {
        let videoURL: URL
        let subtitles: [ExternalSubtitle]
    }

    /// Resolves a release to its video file + sidecar subtitles from the torrent.
    /// If season/episode is given (pack), picks the file for THAT episode;
    /// if there's no match (single-episode release), uses the largest video file.
    @MainActor
    static func resolve(for release: TorrentRelease, season: Int? = nil, episode: Int? = nil) async throws -> Resolved {
        let (base, hash, stats) = try await addAndList(release)
        let r = try resolved(base: base, hash: hash, stats: stats, season: season, episode: episode, requireEpisodeMatch: false)
        wake(r.videoURL)
        return Resolved(videoURL: r.videoURL, subtitles: await withDetectedLanguages(r.subtitles))
    }

    /// Resolves an episode inside an ALREADY-added torrent (same pack), by its hash.
    /// Returns nil if that episode is not among the torrent's files.
    @MainActor
    static func resolveInSameTorrent(hash: String, season: Int, episode: Int) async throws -> Resolved? {
        let pseudo = TorrentRelease(
            title: "", magnetURL: nil, downloadURL: nil, infoHash: hash,
            sizeBytes: 0, seeders: 0, leechers: 0, indexer: "", freeleech: nil
        )
        let (base, h, stats) = try await addAndList(pseudo)
        guard let r = try? resolved(base: base, hash: h, stats: stats, season: season, episode: episode, requireEpisodeMatch: true) else { return nil }
        wake(r.videoURL)
        return Resolved(videoURL: r.videoURL, subtitles: await withDetectedLanguages(r.subtitles))
    }

    /// Fills in the language of sidecar subtitles that don't carry it in the name: downloads a
    /// fragment and detects it with NaturalLanguage. (Embedded tracks without metadata
    /// can't be detected without playing them.)
    private static func withDetectedLanguages(_ subs: [ExternalSubtitle]) async -> [ExternalSubtitle] {
        var result: [ExternalSubtitle] = []
        var detections = 0
        for sub in subs {
            guard sub.lang == nil, detections < 15 else { result.append(sub); continue }
            detections += 1
            let lang = await detectLanguage(url: sub.url)
            result.append(ExternalSubtitle(title: sub.title, lang: lang, url: sub.url))
        }
        return result
    }

    private static func detectLanguage(url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let slice = data.prefix(16_384)
        guard let raw = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1) else { return nil }
        // Strip SRT/VTT indexes and timecodes, keep only dialogue.
        let text = raw.split(separator: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && Int(t) == nil && !t.contains("-->") && !t.hasPrefix("WEBVTT")
        }.joined(separator: " ")
        return detectLanguage(in: text)
    }

    /// Dominant language of a chunk of dialogue ("es", "en", "pt"…), or nil
    /// when there isn't enough signal. Used to label sidecar subtitle files
    /// that don't carry a language in their name.
    private static func detectLanguage(in text: String) -> String? {
        guard text.count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Builds the Resolved by choosing a video file (by episode or the largest) + sidecar subs.
    private static func resolved(base: String, hash: String, stats: [FileStat],
                                 season: Int?, episode: Int?, requireEpisodeMatch: Bool) throws -> Resolved {
        let videoFiles = stats.filter { Self.videoExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }

        var chosen: FileStat?
        if let season, let episode {
            chosen = videoFiles.first {
                EpisodeMatch.matchesExact(($0.path as NSString).lastPathComponent, season: season, episode: episode)
            }
        }
        if chosen == nil {
            if requireEpisodeMatch { throw TorrError.noPlayableFile }   // the episode isn't in this torrent
            chosen = videoFiles.max(by: { $0.length < $1.length })
        }
        guard let chosen else {
            // Diagnostics: no file list (metadata) or is it compressed?
            if stats.isEmpty { throw TorrError.metadataTimeout }
            let hasArchive = stats.contains { Self.archiveExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            throw hasArchive ? TorrError.compressed : TorrError.noPlayableFile
        }
        let videoURL = streamLink(base: base, hash: hash, index: chosen.id)

        // Sidecar subtitles (loose .srt/.ass files in the torrent).
        let subs: [ExternalSubtitle] = stats
            .filter { Self.subtitleExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            .compactMap { stat in
                let name = (stat.path as NSString).lastPathComponent
                let url = streamLink(base: base, hash: hash, index: stat.id)
                return ExternalSubtitle(title: Self.cleanSubtitleTitle(name), lang: Self.langFromName(name), url: url)
            }
        return Resolved(videoURL: videoURL, subtitles: subs)
    }

    /// Guesses the language (ISO 639-2) from the subtitle file name. Covers common
    /// names and codes; tokenizes separators to avoid substring confusion.
    static func langFromName(_ name: String) -> String? {
        // Without extension, separators → spaces.
        let base = (name as NSString).deletingPathExtension.lowercased()
        let tokens = Set(base.components(separatedBy: CharacterSet(charactersIn: " ._-[]()")).filter { !$0.isEmpty })
        // (ISO 639-2, possible names and codes in the file name).
        let table: [(code: String, keys: [String])] = [
            ("spa", ["spanish", "espanol", "español", "castellano", "latino", "spa", "esp", "es", "lat"]),
            ("eng", ["english", "ingles", "eng", "en"]),
            ("por", ["portuguese", "portugues", "português", "brazilian", "brasil", "por", "pt", "ptbr", "pob"]),
            ("fra", ["french", "francais", "français", "vff", "vof", "fra", "fre", "fr"]),
            ("ita", ["italian", "italiano", "ita", "it"]),
            ("deu", ["german", "deutsch", "aleman", "ger", "deu", "de"]),
            ("jpn", ["japanese", "japones", "jpn", "jap", "ja"]),
            ("kor", ["korean", "coreano", "kor", "ko"]),
            ("zho", ["chinese", "chino", "mandarin", "zho", "chi", "zh", "cmn"]),
            ("rus", ["russian", "ruso", "rus", "ru"]),
            ("ara", ["arabic", "arabe", "ara", "ar"]),
            ("nld", ["dutch", "nederlands", "nld", "dut", "nl"]),
            ("pol", ["polish", "polski", "pol", "pl"]),
            ("tur", ["turkish", "turkce", "tur", "tr"]),
        ]
        for entry in table where entry.keys.contains(where: { tokens.contains($0) }) {
            return entry.code
        }
        // Last resort: substrings of long, unambiguous names.
        for entry in table where entry.keys.contains(where: { $0.count >= 5 && base.contains($0) }) {
            return entry.code
        }
        return nil
    }

    /// Readable label for a sidecar subtitle whose language isn't recognized.
    private static func cleanSubtitleTitle(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    private static func streamLink(base: String, hash: String, index: Int) -> URL {
        var comps = URLComponents(string: base + "/stream")
        comps?.queryItems = [
            URLQueryItem(name: "link", value: hash),
            URLQueryItem(name: "index", value: String(index)),
            URLQueryItem(name: "play", value: nil),
        ]
        return comps!.url!
    }

    private struct FileStat: Decodable {
        let id: Int
        let path: String
        let length: Int64
    }

    @MainActor
    private static func addAndList(_ release: TorrentRelease) async throws -> (String, String, [FileStat]) {
        let base = SettingsStore.shared.torrServerURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw TorrError.notConfigured }

        let link = release.magnetURL
            ?? release.infoHash.map { "magnet:?xt=urn:btih:\($0)" }
            ?? release.downloadURL
        guard let link else { throw TorrError.noMagnet }

        struct AddBody: Encodable {
            let action = "add"
            let link: String
            let save_to_db = false
        }
        struct TorrentInfo: Decodable {
            let hash: String?
            let file_stats: [FileStat]?
        }

        guard let addURL = URL(string: base + "/torrents") else { throw TorrError.addFailed }
        var addReq = URLRequest(url: addURL)
        addReq.httpMethod = "POST"
        addReq.timeoutInterval = 30
        addReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addReq.httpBody = try JSONEncoder().encode(AddBody(link: link))

        let (data, resp) = try await URLSession.shared.data(for: addReq)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(TorrentInfo.self, from: data),
              let hash = info.hash else {
            throw TorrError.addFailed
        }

        // The file list can come back empty right after adding: TorrServer is still
        // downloading the torrent's metadata (DHT/peers). We poll.
        var stats = info.file_stats ?? []
        var attempts = 0
        while stats.isEmpty && attempts < 20 {   // ~30s max
            try? await Task.sleep(for: .milliseconds(1500))
            stats = await fileStats(base: base, hash: hash)
            attempts += 1
        }
        return (base, hash, stats)
    }

    /// Wakes a torrent that TorrServer keeps in the closed/dropped state:
    /// re-adding via the API returns the stored entry WITHOUT reconnecting the
    /// engine, and the player would sit at "finding peers 0/0" forever. A tiny
    /// ranged request on the stream endpoint forces TorrServer to start the
    /// torrent client before (or alongside) mpv's own requests. Fire-and-forget.
    private static func wake(_ streamURL: URL) {
        Task.detached {
            var req = URLRequest(url: streamURL)
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            req.timeoutInterval = 60
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Tells TorrServer we stopped watching: the "drop" action closes the
    /// torrent's connections and frees its memory on the server WITHOUT
    /// deleting it from TorrServer's database (resuming later re-adds it
    /// instantly). Fire-and-forget: a failure here must never affect the app.
    static func drop(hash: String) async {
        let base = await MainActor.run { SettingsStore.shared.torrServerURL }
        guard !base.isEmpty, !hash.isEmpty, let url = URL(string: base + "/torrents") else { return }
        struct DropBody: Encodable { let action = "drop"; let hash: String }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(DropBody(hash: hash))
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    /// File list of an already-added torrent ("get" action).
    private static func fileStats(base: String, hash: String) async -> [FileStat] {
        struct GetBody: Encodable { let action = "get"; let hash: String }
        struct Info: Decodable { let file_stats: [FileStat]? }
        guard let url = URL(string: base + "/torrents") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(GetBody(hash: hash))
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(Info.self, from: data) else { return [] }
        return info.file_stats ?? []
    }

    /// Compatibility: just the video URL.
    @MainActor
    static func streamURL(for release: TorrentRelease) async throws -> URL {
        try await resolve(for: release).videoURL
    }

    /// Tests the TorrServer connection (the /echo endpoint returns the version).
    @MainActor
    static func testConnection() async -> ServiceTest {
        let base = SettingsStore.shared.torrServerURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + "/echo") else {
            return .fail(tr(L.torrServerBadConfig))
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return .fail(tr(L.noResponse))
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { return .fail("HTTP \(code).") }
        let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .ok(version.isEmpty ? "Conectado" : "TorrServer \(version.prefix(20))")
    }

    // MARK: Live streaming stats

    struct Stats: Sendable {
        let downloadSpeedBps: Double
        let activePeers: Int
        let totalPeers: Int
        let connectedSeeders: Int
        let preloadedBytes: Int64
        let torrentSize: Int64

        var downloadMbps: Double { downloadSpeedBps * 8 / 1_000_000 }
        var progress: Double { torrentSize > 0 ? min(Double(preloadedBytes) / Double(torrentSize), 1) : 0 }
    }

    /// Torrent hash embedded in the stream URL (?link=HASH).
    static func hash(from streamURL: URL) -> String? {
        URLComponents(url: streamURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "link" }?.value
    }

    /// Live stats of a torrent being played.
    @MainActor
    static func stats(hash: String) async -> Stats? {
        let base = SettingsStore.shared.torrServerURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + "/torrents") else { return nil }

        struct GetBody: Encodable {
            let action = "get"
            let hash: String
        }
        struct Info: Decodable {
            let download_speed: Double?
            let active_peers: Int?
            let total_peers: Int?
            let connected_seeders: Int?
            let preloaded_bytes: Int64?
            let torrent_size: Int64?
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(GetBody(hash: hash))

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(Info.self, from: data) else { return nil }
        return Stats(
            downloadSpeedBps: info.download_speed ?? 0,
            activePeers: info.active_peers ?? 0,
            totalPeers: info.total_peers ?? 0,
            connectedSeeders: info.connected_seeders ?? 0,
            preloadedBytes: info.preloaded_bytes ?? 0,
            torrentSize: info.torrent_size ?? 0
        )
    }
}
