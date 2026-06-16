import Foundation

/// Read-only client for FluxTorrent's own `/api` namespace (a TorrServer-compatible
/// server by the same author). Powers the optional FluxTorrent dashboard tab, which
/// is shown ONLY when the configured server identifies as FluxTorrent via `/echo`.
/// A plain TorrServer (no `/api`) is not detected, so the tab stays hidden.
enum FluxTorrentClient {

    private static func base() async -> String? {
        let raw = await MainActor.run { SettingsStore.shared.torrServerURL }
        let b = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return b.isEmpty ? nil : b
    }

    /// True only if the configured server's `/echo` banner identifies as FluxTorrent.
    static func detect() async -> Bool {
        guard let base = await base(), let url = URL(string: base + "/echo") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: data, encoding: .utf8) else { return false }
        return s.localizedCaseInsensitiveContains("fluxtorrent")
    }

    // MARK: - Models (decode the /api shapes verbatim)

    struct File: Decodable, Hashable, Sendable {
        let index: Int
        let path: String
        let sizeBytes: Int64
        let playable: Bool
    }

    struct Stats: Decodable, Hashable, Sendable {
        let peers: Int
        let seeders: Int
        let downKbps: Double        // kilobits/s
        let upKbps: Double          // kilobits/s
        let progress: Double        // 0…1
        let cacheFillMB: Double     // MiB cached on disk
        let state: String           // "downloading" | "seeding" | "searching" | …
        let ratio: Double
        let uploadedBytes: Int64
    }

    struct Peer: Decodable, Hashable, Sendable {
        let addr: String
        let client: String?
        let seeder: Bool?
        let downKbps: Double?
    }

    struct Torrent: Decodable, Identifiable, Hashable, Sendable {
        let hash: String
        let name: String
        let sizeBytes: Int64
        let files: [File]
        let stats: Stats
        let storageMode: String?
        let addedAt: Int?
        let `private`: Bool?
        let keepSeed: Bool?
        let seedTargetRatio: Double?
        let seedTargetMinutes: Int?
        let seedElapsedMin: Int?
        let peers: [Peer]?
        let trackers: [String]?
        var id: String { hash }
    }

    struct DiskInfo: Decodable, Hashable, Sendable {
        let available: Bool
        let freeBytes: Int64
        let totalBytes: Int64
        let usedBytes: Int64
        let path: String
    }

    struct ServerSettings: Decodable, Sendable {
        struct Cache: Decodable { let mode: String?; let sizeMB: Int?; let path: String? }
        struct Net: Decodable { let maxConns: Int?; let downKbps: Int?; let upKbps: Int? }
        struct Limits: Decodable { let maxActiveTorrents: Int? }
        let cache: Cache?
        let net: Net?
        let limits: Limits?
    }

    /// Snapshot of everything the dashboard needs in one call set.
    struct Snapshot: Sendable {
        let torrents: [Torrent]
        let disk: DiskInfo?
        let settings: ServerSettings?
    }

    // MARK: - Endpoints

    private static func get<T: Decodable>(_ path: String, as: T.Type) async -> T? {
        guard let base = await base(), let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Decodes per element so a single malformed torrent can't drop the whole list.
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    static func torrents() async -> [Torrent] {
        guard let base = await base(), let url = URL(string: base + "/api/torrents") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        if let list = try? JSONDecoder().decode([Torrent].self, from: data) { return list }
        let lenient = (try? JSONDecoder().decode([Failable<Torrent>].self, from: data)) ?? []
        return lenient.compactMap(\.value)
    }

    static func disk() async -> DiskInfo? { await get("/api/disk", as: DiskInfo.self) }
    static func settings() async -> ServerSettings? { await get("/api/settings", as: ServerSettings.self) }

    /// Torrents + disk fetched concurrently; settings only when requested (static-ish).
    static func snapshot(includeSettings: Bool) async -> Snapshot {
        async let t = torrents()
        async let d = disk()
        async let s = includeSettings ? settings() : nil
        return await Snapshot(torrents: t, disk: d, settings: s)
    }
}
