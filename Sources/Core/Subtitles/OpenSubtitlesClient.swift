import Foundation

/// Subtitle search result with a match indicator.
struct SubtitleResult: Identifiable, Sendable {
    let fileID: Int
    let language: String
    let release: String
    let downloads: Int
    let hashMatch: Bool       // exact match by moviehash
    let matchPercent: Int     // likelihood (hash=100, or text proximity + popularity)
    var id: Int { fileID }
}

/// Similarity between the file name and the subtitle name (releases usually share names).
enum TextSimilarity {
    private static let noise: Set<String> = [
        "1080p", "720p", "2160p", "4k", "x264", "x265", "h264", "h265", "hevc", "av1",
        "bluray", "bdrip", "webrip", "web", "dl", "webdl", "hdrip", "dvdrip", "hdtv",
        "aac", "ac3", "dts", "ddp5", "atmos", "remux", "10bit", "hdr", "dv", "proper", "repack",
    ]

    static func tokens(_ s: String) -> Set<String> {
        let cleaned = s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: " ", options: .regularExpression)
        return Set(cleaned.split(separator: " ").map(String.init).filter { $0.count > 1 && !noise.contains($0) })
    }

    /// 0–100: Jaccard of significant tokens.
    static func score(_ a: String, _ b: String) -> Int {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Int(Double(inter) / Double(union) * 100)
    }
}

/// OpenSubtitles client (api.opensubtitles.com v1). Requires an API key + account to download.
enum OpenSubtitlesClient {
    private static let base = "https://api.opensubtitles.com/api/v1"
    nonisolated(unsafe) private static var token: String?

    enum OSError: LocalizedError {
        case notConfigured, loginFailed, searchFailed, downloadFailed, quota
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Configura OpenSubtitles en Ajustes."
            case .loginFailed: tr(L.osLoginFailed)
            case .searchFailed: tr(L.osSearchFailed)
            case .downloadFailed: tr(L.osDownloadFailed)
            case .quota: tr(L.osQuota)
            }
        }
    }

    @MainActor
    private static func config() -> (apiKey: String, user: String, pass: String)? {
        let s = SettingsStore.shared
        guard let key = s.openSubtitlesKey, !key.isEmpty,
              !s.openSubtitlesUser.isEmpty, let pass = s.openSubtitlesPass, !pass.isEmpty else { return nil }
        return (key, s.openSubtitlesUser, pass)
    }

    private static func request(_ path: String, apiKey: String, method: String = "GET", body: Data? = nil, auth: Bool = false) -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue("LumoraTV v1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        return req
    }

    private static func login(apiKey: String, user: String, pass: String) async throws {
        if token != nil { return }
        struct Body: Encodable { let username: String; let password: String }
        struct Resp: Decodable { let token: String? }
        let body = try JSONEncoder().encode(Body(username: user, password: pass))
        let req = request("/login", apiKey: apiKey, method: "POST", body: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let t = try? JSONDecoder().decode(Resp.self, from: data).token else {
            throw OSError.loginFailed
        }
        token = t
    }

    /// Tests the configuration: validates API key + login (username/password).
    @MainActor
    static func testConnection() async -> ServiceTest {
        guard let cfg = config() else {
            return .fail(tr(L.osMissingCreds))
        }
        token = nil
        do {
            try await login(apiKey: cfg.apiKey, user: cfg.user, pass: cfg.pass)
            return .ok(trf(L.osLoggedInAs, cfg.user))
        } catch {
            return .fail(tr(L.osLoginCheck))
        }
    }

    /// Searches subtitles for the content being played.
    static func search(media: PlayableMedia, languages: [String]) async throws -> [SubtitleResult] {
        guard let cfg = await config() else { throw OSError.notConfigured }
        let moviehash = await MovieHash.compute(url: media.url)
        // Reference file name for text proximity.
        let referenceName = media.url.deletingPathExtension().lastPathComponent
            .removingPercentEncoding ?? media.title

        var comps = URLComponents(string: base + "/subtitles")!
        var query = [URLQueryItem(name: "languages", value: languages.joined(separator: ","))]
        if let tmdbID = media.tmdbID {
            query.append(URLQueryItem(name: media.tmdbIsShow ? "parent_tmdb_id" : "tmdb_id", value: String(tmdbID)))
        }
        if let moviehash { query.append(URLQueryItem(name: "moviehash", value: moviehash)) }
        if media.tmdbID == nil { query.append(URLQueryItem(name: "query", value: media.title)) }
        comps.queryItems = query

        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue(cfg.apiKey, forHTTPHeaderField: "Api-Key")
        req.setValue("LumoraTV v1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        struct Resp: Decodable {
            struct Item: Decodable {
                struct Attr: Decodable {
                    struct File: Decodable { let file_id: Int? }
                    let language: String?
                    let release: String?
                    let download_count: Int?
                    let moviehash_match: Bool?
                    let files: [File]?
                }
                let attributes: Attr?
            }
            let data: [Item]?
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Resp.self, from: data) else {
            throw OSError.searchFailed
        }
        let results: [SubtitleResult] = (decoded.data ?? []).compactMap { item in
            guard let attr = item.attributes, let fileID = attr.files?.first?.file_id else { return nil }
            let release = attr.release ?? ""
            let hashMatch = attr.moviehash_match ?? false
            let downloads = attr.download_count ?? 0
            // Likelihood: exact hash = 100; otherwise, text proximity + a slight popularity boost.
            let percent: Int
            if hashMatch {
                percent = 100
            } else {
                let proximity = TextSimilarity.score(referenceName, release)
                let popularity = min(15, Int(5.0 * log10(Double(max(downloads, 1)) + 1)))
                percent = min(98, max(proximity, 0) + popularity)
            }
            return SubtitleResult(
                fileID: fileID,
                language: attr.language ?? "?",
                release: release,
                downloads: downloads,
                hashMatch: hashMatch,
                matchPercent: percent
            )
        }
        // Exact match first, then by likelihood.
        return results.sorted { $0.matchPercent > $1.matchPercent }
    }

    /// Downloads the subtitle to a temporary file and returns its local URL.
    static func download(fileID: Int) async throws -> URL {
        guard let cfg = await config() else { throw OSError.notConfigured }
        try await login(apiKey: cfg.apiKey, user: cfg.user, pass: cfg.pass)

        struct Body: Encodable { let file_id: Int }
        struct Resp: Decodable { let link: String?; let file_name: String? }
        let body = try JSONEncoder().encode(Body(file_id: fileID))
        let req = request("/download", apiKey: cfg.apiKey, method: "POST", body: body, auth: true)

        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { throw OSError.downloadFailed }
        if (resp as? HTTPURLResponse)?.statusCode == 406 { throw OSError.quota }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Resp.self, from: data),
              let linkStr = decoded.link, let link = URL(string: linkStr) else {
            throw OSError.downloadFailed
        }

        guard let (subData, subResp) = try? await URLSession.shared.data(from: link),
              (subResp as? HTTPURLResponse)?.statusCode == 200 else { throw OSError.downloadFailed }

        let name = decoded.file_name ?? "subtitle-\(fileID).srt"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try subData.write(to: tmp)
        return tmp
    }
}

/// OpenSubtitles hash: size + checksum of the first and last 64 KB.
/// Enables exact file↔subtitle matching without relying on metadata.
enum MovieHash {
    private static let chunk = 65536

    static func compute(url: URL) async -> String? {
        guard let total = await totalSize(url: url), total >= Int64(chunk) else { return nil }
        guard let head = await rangedData(url: url, start: 0, length: chunk),
              let tail = await rangedData(url: url, start: total - Int64(chunk), length: chunk),
              head.count == chunk, tail.count == chunk else { return nil }

        var hash = UInt64(bitPattern: total)
        hash = hash &+ sum(head)
        hash = hash &+ sum(tail)
        return String(format: "%016x", hash)
    }

    private static func sum(_ data: Data) -> UInt64 {
        var acc: UInt64 = 0
        data.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for w in words { acc = acc &+ UInt64(littleEndian: w) }
        }
        return acc
    }

    private static func totalSize(url: URL) async -> Int64? {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        req.timeoutInterval = 10
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        // Content-Range: bytes 0-1/12345678
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let total = cr.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    private static func rangedData(url: URL, start: Int64, length: Int) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return data
    }
}
