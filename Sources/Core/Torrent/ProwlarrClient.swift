import Foundation

/// A release found by Prowlarr (a candidate torrent).
struct TorrentRelease: Identifiable, Sendable, Hashable, Codable {
    let title: String
    let magnetURL: String?
    let downloadURL: String?
    let infoHash: String?
    let sizeBytes: Int64
    let seeders: Int
    let leechers: Int
    let indexer: String
    /// Freeleech flag reported by Prowlarr (nil when the indexer doesn't say).
    /// Optional so previously persisted releases keep decoding.
    let freeleech: Bool?
    var id: String { (infoHash ?? magnetURL ?? downloadURL ?? title) + indexer }

    /// Freeleech: reported flag, or inferred from the title.
    var isFreeleech: Bool {
        if let freeleech { return freeleech }
        let t = title.lowercased()
        return t.contains("freeleech") || t.contains("[fl]")
    }

    var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }

    /// Torrent hash (infoHash or the magnet's btih), lowercased, to compare
    /// against the source being played.
    var torrentHash: String? {
        if let h = infoHash, !h.isEmpty { return h.lowercased() }
        guard let m = magnetURL, let r = m.range(of: "btih:", options: .caseInsensitive) else { return nil }
        let rest = m[r.upperBound...].prefix { $0 != "&" }
        return rest.isEmpty ? nil : String(rest).lowercased()
    }

    /// Quality inferred from the release title.
    var quality: String? {
        let t = title.lowercased()
        if t.contains("2160p") || t.contains("4k") { return "4K" }
        if t.contains("1080p") { return "1080p" }
        if t.contains("720p") { return "720p" }
        if t.contains("480p") { return "480p" }
        return nil
    }

    var hdr: String? {
        let t = title.lowercased()
        if t.contains("dovi") || t.contains("dolby vision") || t.contains(" dv ") { return "DV" }
        if t.contains("hdr10+") { return "HDR10+" }
        if t.contains("hdr") { return "HDR" }
        return nil
    }

    var codec: String? {
        let t = title.lowercased()
        if t.contains("x265") || t.contains("hevc") || t.contains("h265") { return "HEVC" }
        if t.contains("av1") { return "AV1" }
        if t.contains("x264") || t.contains("h264") { return "H264" }
        return nil
    }

    /// Compact label for the picker.
    var qualityLabel: String {
        [quality, codec, hdr].compactMap { $0 }.joined(separator: " · ")
    }

    /// Languages/tracks inferred from the release title (heuristic, not guaranteed).
    var languageBadges: [String] {
        // Normalize separators to spaces to detect standalone tokens.
        let t = " " + title.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ") + " "

        var badges: [String] = []
        // Multi-track / dual first.
        if t.contains(" multi ") { badges.append("MULTI") }
        if t.contains(" dual ") { badges.append("DUAL") }
        // Common languages (audio).
        let langs: [(label: String, tokens: [String])] = [
            ("ES (LAT)", ["latino", "lat", "español latino"]),
            ("ES (CAST)", ["castellano", "cast", "spanish", "español", "esp", "spa"]),
            ("EN", ["english", "eng", "ingles"]),
            ("IT", ["italian", "ita"]),
            ("FR", ["french", "truefrench", "vff", "fra", "fre"]),
            ("DE", ["german", "ger", "deu"]),
            ("PT", ["portuguese", "dublado", "nacional", "por"]),
            ("JP", ["japanese", "jpn", "jap"]),
            ("KR", ["korean", "kor"]),
        ]
        for lang in langs where lang.tokens.contains(where: { t.contains(" \($0) ") }) {
            if !badges.contains(lang.label) { badges.append(lang.label) }
        }
        // Subtitled (subtitled original version).
        if t.contains(" vose ") || t.contains(" vos ") { badges.append("SUB ES") }
        if t.contains(" vostfr ") { badges.append("SUB FR") }
        if t.contains(" subbed ") || t.contains(" subs ") { badges.append("SUB") }

        return Array(badges.prefix(4))
    }

    /// Release group / uploader parsed from the title's scene/P2P convention
    /// (`Movie.2024.1080p.x265-GalaxyRG`, `Movie (2024) [YTS.MX]`), normalized
    /// to lowercase. Returns nil when no confident candidate exists — the
    /// learning layer (`UploaderReputation`) prefers no data over noisy data,
    /// and mis-parses that slip through dilute to neutral on their own.
    var releaseGroup: String? {
        var t = title.trimmingCharacters(in: .whitespaces)

        // Trailing bracket tags: distribution-site noise ([TGx]) is dropped;
        // a valid group tag ([YTS.MX], [QxR]) wins immediately.
        while t.hasSuffix("]"), let open = t.range(of: "[", options: .backwards) {
            let tag = String(t[t.index(after: open.lowerBound)..<t.index(before: t.endIndex)])
            if let group = Self.validGroup(tag) { return group }
            t = String(t[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        // Scene convention: the token after the LAST hyphen.
        guard let dash = t.range(of: "-", options: .backwards) else { return nil }
        var candidate = String(t[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Some titles append " [tag]" or trailing junk after the group.
        if let bracket = candidate.firstIndex(of: "[") {
            candidate = String(candidate[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        return Self.validGroup(candidate)
    }

    /// Tokens that look like a group slot but are codecs/qualities/languages/etc.
    private static let groupBlocklist: Set<String> = [
        // resolutions / sources
        "480p", "720p", "1080p", "2160p", "4k", "uhd", "hd", "sd",
        "web", "webdl", "dl", "webrip", "bluray", "bdrip", "brrip", "hdrip",
        "dvdrip", "hdtv", "cam", "ts", "tc", "remux", "rip",
        // codecs / containers
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid", "divx",
        "vp9", "mkv", "mp4", "avi",
        // audio
        "aac", "ac3", "eac3", "dts", "dd5", "ddp", "ddp5", "truehd", "atmos",
        "flac", "mp3", "opus",
        // hdr / color
        "hdr", "hdr10", "hdr10+", "dv", "dovi", "sdr", "10bit", "8bit",
        // languages
        "multi", "dual", "lat", "latino", "cast", "castellano", "esp", "spanish",
        "english", "eng", "ingles", "vose", "subs", "sub", "esubs", "dub", "dubbed",
        // release flags
        "final", "repack", "proper", "extended", "unrated", "remastered",
        "complete", "internal", "limited", "hybrid", "imax", "3d", "hc",
        // distribution-site tags (not uploaders)
        "tgx", "rartv", "rarbg", "eztv", "ettv", "etrg",
    ]

    /// Validates and normalizes a group candidate; nil when it's noise.
    private static func validGroup(_ raw: String) -> String? {
        var g = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard g.count >= 2, g.count <= 20,
              !g.contains(" "),
              g.contains(where: { $0.isLetter }),
              g.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" })
        else { return nil }
        // Domain-styled names collapse to the brand: yts.mx / yts.ag → yts.
        if let dot = g.firstIndex(of: "."), g.distance(from: g.startIndex, to: dot) >= 3 {
            g = String(g[..<dot])
        }
        guard !groupBlocklist.contains(g) else { return nil }
        return g
    }
}

/// Client for Prowlarr's native v1 API (aggregated search across all indexers).
enum ProwlarrClient {

    enum ProwlarrError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String?)
        var errorDescription: String? {
            switch self {
            case .notConfigured: tr(L.prowlarrNotConfigured)
            case .badURL: tr(L.prowlarrBadURL)
            case .http(let code, let body):
                if let body, !body.isEmpty {
                    "HTTP \(code) — \(body.prefix(140))"
                } else {
                    trf(L.prowlarrHTTPError, code)
                }
            }
        }
    }

    /// Tests the connection: counts enabled indexers. nil = OK; otherwise an error message.
    @MainActor
    static func testConnection() async -> ServiceTest {
        let settings = SettingsStore.shared
        guard !settings.prowlarrURL.isEmpty, let key = settings.prowlarrKey else {
            return .fail(ProwlarrError.notConfigured.localizedDescription)
        }
        let base = settings.prowlarrURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: base + "/api/v1/indexer") else { return .fail(tr(L.invalidURL)) }
        comps.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = comps.url else { return .fail(tr(L.invalidURL)) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(key, forHTTPHeaderField: "X-Api-Key")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return .fail(tr(L.noResponse))
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { return .fail(trf(L.httpCodeCheckKey, code)) }
        struct Indexer: Decodable { let enable: Bool? }
        let list = (try? JSONDecoder().decode([Indexer].self, from: data)) ?? []
        let enabled = list.filter { $0.enable ?? false }.count
        return .ok("\(enabled) indexer(s) habilitado(s)")
    }

    private struct RawRelease: Decodable {
        let title: String?
        let magnetUrl: String?
        let downloadUrl: String?
        let infoHash: String?
        let size: Int64?
        let seeders: Int?
        let leechers: Int?
        let indexer: String?
        let indexerFlags: [String]?
        let downloadVolumeFactor: Double?
        let protocolType: String?
        enum CodingKeys: String, CodingKey {
            case title, magnetUrl, downloadUrl, infoHash, size, seeders, leechers, indexer
            case indexerFlags, downloadVolumeFactor
            case protocolType = "protocol"
        }
    }

    /// Searches releases for a title. `imdbID` refines the match when available.
    @MainActor
    static func search(query: String, imdbID: String?, isShow: Bool) async throws -> [TorrentRelease] {
        let settings = SettingsStore.shared
        guard !settings.prowlarrURL.isEmpty, let key = settings.prowlarrKey else {
            throw ProwlarrError.notConfigured
        }
        let base = settings.prowlarrURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 1) Categorized search (2000 movies / 5000 TV).
        let category = isShow ? "5000" : "2000"
        var raw = try await fetch(base: base, key: key, query: query, category: category)

        // 2) Fallback without a category: many indexers mislabel categories,
        //    so if the categorized search came back empty we try an open one.
        if raw.isEmpty {
            raw = try await fetch(base: base, key: key, query: query, category: nil)
        }

        return raw
            .filter { $0.protocolType == nil || $0.protocolType == "torrent" }
            .compactMap { r -> TorrentRelease? in
                guard let title = r.title, r.magnetUrl != nil || r.infoHash != nil || r.downloadUrl != nil else { return nil }
                // Freeleech: explicit flag, or downloadVolumeFactor == 0 (no download cost).
                let flagged = r.indexerFlags?.contains { $0.lowercased().contains("freeleech") } ?? false
                let free = flagged || (r.downloadVolumeFactor.map { $0 == 0 } ?? false)
                return TorrentRelease(
                    title: title,
                    magnetURL: r.magnetUrl,
                    downloadURL: r.downloadUrl,
                    infoHash: r.infoHash,
                    sizeBytes: r.size ?? 0,
                    seeders: r.seeders ?? 0,
                    leechers: r.leechers ?? 0,
                    indexer: r.indexer ?? "?",
                    freeleech: free ? true : nil
                )
            }
            // Composite ranking: quality + health + language + size + freeleech + reputation.
            .sorted { ReleaseScore.score($0) > ReleaseScore.score($1) }
    }

    /// A single search request to Prowlarr. `category` nil = no category filter.
    private static func fetch(base: String, key: String, query: String, category: String?) async throws -> [RawRelease] {
        var comps = URLComponents(string: base + "/api/v1/search")
        // Do NOT send indexerIds: in the native v1 API it's a list of real indexer
        // IDs. Omitting it makes Prowlarr search ALL enabled indexers.
        // (Passing -1 is interpreted as "indexer #-1" → "all selected unavailable".)
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "type", value: "search"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "apikey", value: key),
        ]
        if let category {
            items.append(URLQueryItem(name: "categories", value: category))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { throw ProwlarrError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue(key, forHTTPHeaderField: "X-Api-Key")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProwlarrError.http(code, body)
        }
        return try JSONDecoder().decode([RawRelease].self, from: data)
    }
}
