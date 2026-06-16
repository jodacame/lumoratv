import SwiftUI

/// A connected Plex server. The token lives in the global keychain under "plexToken-{id}".
struct PlexServerRef: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: String      // clientIdentifier of the plex.tv resource, or a UUID for manual
    var name: String
    var url: String
    var isLocal: Bool
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: GLOBAL (shared by all Apple TV users — user-independent keychain)

    @Published var isConfigured: Bool {
        didSet { GlobalStore.setBool(isConfigured, "isConfigured"); enqueueGlobalSync() }
    }
    @Published var servers: [PlexServerRef] {
        didSet { persistServers() }
    }
    @Published var hasTMDB: Bool

    // MARK: PER-USER personalization (standard, per-user keychain/defaults)

    // Personal-taste prefs: PER-PROFILE (namespaced by profile UUID locally, synced
    // per-profile via a CloudKit Prefs record). Switching profiles loads each
    // person's own audio/subtitle/HUD prefs without clobbering the others.
    /// Preferred audio language: "auto" (original) | "es" | "en"
    @Published var audioLang: String {
        didSet { writeProfilePref(audioLang, "audioLang") }
    }
    /// Preferred subtitle language: "off" | "es" | "en"
    @Published var subtitleLang: String {
        didSet { writeProfilePref(subtitleLang, "subtitleLang") }
    }
    /// Subtitle style: size "small"|"medium"|"large"
    @Published var subSize: String {
        didSet { writeProfilePref(subSize, "subSize") }
    }
    /// Font: "default"|"rounded"|"serif"|"mono"
    @Published var subFont: String {
        didSet { writeProfilePref(subFont, "subFont") }
    }
    /// Color: "white"|"yellow"|"cyan"
    @Published var subColor: String {
        didSet { writeProfilePref(subColor, "subColor") }
    }
    /// Picture mode: "normal" | "sleep" | "vivid". DEVICE-WIDE (depends on the TV/HDR
    /// panel), not per-profile.
    @Published var videoColorMode: String {
        didSet { defaults.set(videoColorMode, forKey: "videoColorMode") }
    }
    /// Language-learning mode (per-profile).
    @Published var learningModeEnabled: Bool {
        didSet { writeProfilePref(learningModeEnabled, "learningModeEnabled") }
    }

    // Extra info shown in the player (per-profile; all on by default).
    @Published var playerShowClock: Bool { didSet { writeProfilePref(playerShowClock, "playerShowClock") } }
    @Published var playerShowDate: Bool { didSet { writeProfilePref(playerShowDate, "playerShowDate") } }
    @Published var playerShowPG: Bool { didSet { writeProfilePref(playerShowPG, "playerShowPG") } }
    @Published var playerShowGenres: Bool { didSet { writeProfilePref(playerShowGenres, "playerShowGenres") } }
    @Published var playerShowRating: Bool { didSet { writeProfilePref(playerShowRating, "playerShowRating") } }
    @Published var playerShowYear: Bool { didSet { writeProfilePref(playerShowYear, "playerShowYear") } }
    @Published var playerShowQuality: Bool { didSet { writeProfilePref(playerShowQuality, "playerShowQuality") } }
    @Published var playerShowAudio: Bool { didSet { writeProfilePref(playerShowAudio, "playerShowAudio") } }
    @Published var playerShowSubtitle: Bool { didSet { writeProfilePref(playerShowSubtitle, "playerShowSubtitle") } }
    @Published var autoNextEpisode: Bool { didSet { writeProfilePref(autoNextEpisode, "autoNextEpisode") } }
    @Published var playerShowNerdStats: Bool { didSet { writeProfilePref(playerShowNerdStats, "playerShowNerdStats") } }
    /// Audio passthrough (bitstream). DEVICE-WIDE (depends on the AV receiver wired to
    /// THIS Apple TV), not per-profile.
    @Published var audioPassthrough: Bool { didSet { defaults.set(audioPassthrough, forKey: "audioPassthrough") } }

    // MARK: GLOBAL service config (user-independent keychain)

    /// AI provider for word explanations (any OpenAI-compatible API).
    @Published var aiProvider: String { didSet { GlobalStore.setString(aiProvider, "aiProvider"); enqueueGlobalSync() } }
    @Published var aiBaseURL: String { didSet { GlobalStore.setString(aiBaseURL, "aiBaseURL"); enqueueGlobalSync() } }
    @Published var aiModel: String { didSet { GlobalStore.setString(aiModel, "aiModel"); enqueueGlobalSync() } }
    /// Image cache limit in GB (0 = no limit) — device-level.
    @Published var cacheLimitGB: Int { didSet { GlobalStore.setInt(cacheLimitGB, "cacheLimitGB"); enqueueGlobalSync() } }
    /// Streaming Mode (external torrent source). Persisted key stays "discoverEnabled".
    @Published var streamingModeEnabled: Bool { didSet { GlobalStore.setBool(streamingModeEnabled, "discoverEnabled"); enqueueGlobalSync() } }
    @Published var autoBestSource: Bool { didSet { GlobalStore.setBool(autoBestSource, "autoBestSource"); enqueueGlobalSync() } }
    @Published var prowlarrURL: String { didSet { GlobalStore.setString(prowlarrURL, "prowlarrURL"); enqueueGlobalSync() } }
    @Published var torrServerURL: String { didSet { GlobalStore.setString(torrServerURL, "torrServerURL"); fluxTorrentAvailable = false; enqueueGlobalSync() } }
    /// True when the configured torrent server identifies as FluxTorrent (via /echo).
    /// Not persisted — re-detected.
    @Published var fluxTorrentAvailable = false
    /// OpenSubtitles username (the password/key are secrets).
    @Published var openSubtitlesUser: String { didSet { GlobalStore.setString(openSubtitlesUser, "osUser"); enqueueGlobalSync() } }

    /// Re-runs FluxTorrent detection against the configured server.
    func refreshFluxTorrentDetection() async {
        fluxTorrentAvailable = await FluxTorrentClient.detect()
    }

    private let defaults = UserDefaults.standard
    /// True once init finished (so didSets during init don't enqueue syncs).
    private var ready = false
    /// True while applying a remote global-config change (prevents a push echo).
    private var applyingRemote = false
    /// True while loading a profile's prefs / applying a remote prefs snapshot
    /// (suppresses the per-profile pref push echo).
    private var reloadingPrefs = false

    /// Queue a cross-device push of the global config + secrets (iCloud build only).
    private func enqueueGlobalSync() {
        #if LUMORA_ICLOUD
        guard ready, !applyingRemote else { return }
        SyncCoordinator.shared.enqueue(.globalConfig)
        #endif
    }

    // MARK: - Per-profile preferences (audio/subtitle/HUD; one set per app profile)

    private static func pkey(_ base: String) -> String { "\(base)#\(UserContext.currentUserID)" }
    private static func prefsStampKey() -> String { "lumora.prefsUpdatedAt#\(UserContext.currentUserID)" }

    /// Reads a per-profile string; falls back to the legacy device-wide value the
    /// first time (migrates the existing setting into the active profile), then `def`.
    private static func readProfileString(_ base: String, _ def: String) -> String {
        let d = UserDefaults.standard
        return d.string(forKey: pkey(base)) ?? d.string(forKey: base) ?? def
    }
    private static func readProfileBool(_ base: String, _ def: Bool) -> Bool {
        let d = UserDefaults.standard
        return (d.object(forKey: pkey(base)) ?? d.object(forKey: base)) as? Bool ?? def
    }

    /// Persists a per-profile pref under the active profile's key; stamps it and
    /// enqueues a sync push (suppressed during init / profile load / remote apply).
    private func writeProfilePref(_ value: Any, _ base: String) {
        defaults.set(value, forKey: Self.pkey(base))
        guard ready, !applyingRemote, !reloadingPrefs else { return }
        defaults.set(Int(Date().timeIntervalSince1970), forKey: Self.prefsStampKey())
        #if LUMORA_ICLOUD
        SyncCoordinator.shared.enqueue(.prefs(userID: UserContext.currentUserID))
        #endif
    }

    /// Reloads the active profile's personal prefs into the published vars. Called on
    /// profile switch so each person sees their own audio/subtitle/HUD settings.
    func reloadProfilePrefs() {
        reloadingPrefs = true
        defer { reloadingPrefs = false }
        audioLang = Self.readProfileString("audioLang", "auto")
        subtitleLang = Self.readProfileString("subtitleLang", "off")
        subSize = Self.readProfileString("subSize", "medium")
        subFont = Self.readProfileString("subFont", "default")
        subColor = Self.readProfileString("subColor", "white")
        learningModeEnabled = Self.readProfileBool("learningModeEnabled", false)
        autoNextEpisode = Self.readProfileBool("autoNextEpisode", true)
        playerShowClock = Self.readProfileBool("playerShowClock", true)
        playerShowDate = Self.readProfileBool("playerShowDate", true)
        playerShowPG = Self.readProfileBool("playerShowPG", true)
        playerShowGenres = Self.readProfileBool("playerShowGenres", true)
        playerShowRating = Self.readProfileBool("playerShowRating", true)
        playerShowYear = Self.readProfileBool("playerShowYear", true)
        playerShowQuality = Self.readProfileBool("playerShowQuality", true)
        playerShowAudio = Self.readProfileBool("playerShowAudio", true)
        playerShowSubtitle = Self.readProfileBool("playerShowSubtitle", true)
        playerShowNerdStats = Self.readProfileBool("playerShowNerdStats", false)
    }

    /// Snapshot of the active profile's personal prefs for cross-device sync.
    func prefsSnapshot() -> (dict: [String: String], updatedAt: Int) {
        let dict: [String: String] = [
            "audioLang": audioLang, "subtitleLang": subtitleLang, "subSize": subSize,
            "subFont": subFont, "subColor": subColor,
            "learningModeEnabled": learningModeEnabled ? "1" : "0",
            "autoNextEpisode": autoNextEpisode ? "1" : "0",
            "playerShowClock": playerShowClock ? "1" : "0",
            "playerShowDate": playerShowDate ? "1" : "0",
            "playerShowPG": playerShowPG ? "1" : "0",
            "playerShowGenres": playerShowGenres ? "1" : "0",
            "playerShowRating": playerShowRating ? "1" : "0",
            "playerShowYear": playerShowYear ? "1" : "0",
            "playerShowQuality": playerShowQuality ? "1" : "0",
            "playerShowAudio": playerShowAudio ? "1" : "0",
            "playerShowSubtitle": playerShowSubtitle ? "1" : "0",
            "playerShowNerdStats": playerShowNerdStats ? "1" : "0",
        ]
        return (dict, defaults.integer(forKey: Self.prefsStampKey()))
    }

    /// Applies a remote prefs snapshot if it's newer (newest-wins by `updatedAt`).
    func applyRemotePrefs(_ dict: [String: String], updatedAt: Int) {
        guard updatedAt > defaults.integer(forKey: Self.prefsStampKey()) else { return }
        reloadingPrefs = true
        defer { reloadingPrefs = false }
        func b(_ k: String) -> Bool? { dict[k].map { $0 == "1" } }
        if let v = dict["audioLang"] { audioLang = v }
        if let v = dict["subtitleLang"] { subtitleLang = v }
        if let v = dict["subSize"] { subSize = v }
        if let v = dict["subFont"] { subFont = v }
        if let v = dict["subColor"] { subColor = v }
        if let v = b("learningModeEnabled") { learningModeEnabled = v }
        if let v = b("autoNextEpisode") { autoNextEpisode = v }
        if let v = b("playerShowClock") { playerShowClock = v }
        if let v = b("playerShowDate") { playerShowDate = v }
        if let v = b("playerShowPG") { playerShowPG = v }
        if let v = b("playerShowGenres") { playerShowGenres = v }
        if let v = b("playerShowRating") { playerShowRating = v }
        if let v = b("playerShowYear") { playerShowYear = v }
        if let v = b("playerShowQuality") { playerShowQuality = v }
        if let v = b("playerShowAudio") { playerShowAudio = v }
        if let v = b("playerShowSubtitle") { playerShowSubtitle = v }
        if let v = b("playerShowNerdStats") { playerShowNerdStats = v }
        defaults.set(updatedAt, forKey: Self.prefsStampKey())
        SyncStatus.shared.generation += 1
    }

    private init() {
        // Migrate any config/secrets from older (per-user) builds into the global
        // store, once per device, BEFORE reading the values below.
        Self.migrateGlobalsIfNeeded()

        // Global
        isConfigured = GlobalStore.bool("isConfigured", default: false)
        hasTMDB = Keychain.getSecret("tmdbKey") != nil
        aiProvider = GlobalStore.string("aiProvider") ?? "openai"
        aiBaseURL = GlobalStore.string("aiBaseURL") ?? ""
        aiModel = GlobalStore.string("aiModel") ?? "gpt-4o-mini"
        cacheLimitGB = GlobalStore.int("cacheLimitGB", default: 2)
        streamingModeEnabled = GlobalStore.bool("discoverEnabled", default: false)
        autoBestSource = GlobalStore.bool("autoBestSource", default: false)
        prowlarrURL = GlobalStore.string("prowlarrURL") ?? ""
        torrServerURL = GlobalStore.string("torrServerURL") ?? ""
        openSubtitlesUser = GlobalStore.string("osUser") ?? ""

        // Per-profile personal prefs (fall back to the legacy device-wide value the
        // first time a profile reads them → migrates the existing setting in).
        audioLang = Self.readProfileString("audioLang", "auto")
        subtitleLang = Self.readProfileString("subtitleLang", "off")
        subSize = Self.readProfileString("subSize", "medium")
        subFont = Self.readProfileString("subFont", "default")
        subColor = Self.readProfileString("subColor", "white")
        learningModeEnabled = Self.readProfileBool("learningModeEnabled", false)
        playerShowClock = Self.readProfileBool("playerShowClock", true)
        playerShowDate = Self.readProfileBool("playerShowDate", true)
        playerShowPG = Self.readProfileBool("playerShowPG", true)
        playerShowGenres = Self.readProfileBool("playerShowGenres", true)
        playerShowRating = Self.readProfileBool("playerShowRating", true)
        playerShowYear = Self.readProfileBool("playerShowYear", true)
        playerShowQuality = Self.readProfileBool("playerShowQuality", true)
        playerShowAudio = Self.readProfileBool("playerShowAudio", true)
        playerShowSubtitle = Self.readProfileBool("playerShowSubtitle", true)
        autoNextEpisode = Self.readProfileBool("autoNextEpisode", true)
        playerShowNerdStats = Self.readProfileBool("playerShowNerdStats", false)
        // Device-wide (hardware): picture mode + audio passthrough.
        videoColorMode = defaults.string(forKey: "videoColorMode") ?? "normal"
        audioPassthrough = defaults.bool(forKey: "audioPassthrough")

        // Servers (global)
        if let data = GlobalStore.data("servers"),
           let decoded = try? JSONDecoder().decode([PlexServerRef].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }

        ready = true
    }

    /// Re-reads the GLOBAL config from the device-wide store after a remote
    /// CloudKit sync. Guarded so the resulting didSets don't echo a push back.
    @MainActor
    func reloadGlobalsFromStore() {
        applyingRemote = true
        defer { applyingRemote = false }
        isConfigured = GlobalStore.bool("isConfigured", default: false)
        hasTMDB = Keychain.getSecret("tmdbKey") != nil
        aiProvider = GlobalStore.string("aiProvider") ?? "openai"
        aiBaseURL = GlobalStore.string("aiBaseURL") ?? ""
        aiModel = GlobalStore.string("aiModel") ?? "gpt-4o-mini"
        cacheLimitGB = GlobalStore.int("cacheLimitGB", default: 2)
        streamingModeEnabled = GlobalStore.bool("discoverEnabled", default: false)
        autoBestSource = GlobalStore.bool("autoBestSource", default: false)
        prowlarrURL = GlobalStore.string("prowlarrURL") ?? ""
        torrServerURL = GlobalStore.string("torrServerURL") ?? ""
        openSubtitlesUser = GlobalStore.string("osUser") ?? ""
        if let data = GlobalStore.data("servers"),
           let decoded = try? JSONDecoder().decode([PlexServerRef].self, from: data) {
            servers = decoded
        }
    }

    /// One-time, per-device migration of config & secrets from the old per-user
    /// storage into the global (user-independent) store. Idempotent.
    private static func migrateGlobalsIfNeeded() {
        guard !GlobalStore.bool("didMigrateGlobals", default: false) else { return }
        let defaults = UserDefaults.standard

        // Secrets → global keychain.
        var secretKeys = ["plexAccountToken", "tmdbKey", "prowlarrKey", "osKey", "osPass",
                          "aiKey", "traktClientID", "traktClientSecret", "plexToken", "plexToken-legacy"]
        if let data = defaults.data(forKey: "servers"),
           let decoded = try? JSONDecoder().decode([PlexServerRef].self, from: data) {
            secretKeys += decoded.map { "plexToken-\($0.id)" }
        }
        for key in secretKeys { Keychain.promoteToGlobal(key) }

        // Non-secret global config: defaults → GlobalStore (only if not already set).
        for key in ["prowlarrURL", "torrServerURL", "osUser", "aiProvider", "aiBaseURL", "aiModel"] {
            if GlobalStore.string(key) == nil, let v = defaults.string(forKey: key) { GlobalStore.setString(v, key) }
        }
        for key in ["discoverEnabled", "autoBestSource"] {
            if GlobalStore.string(key) == nil, defaults.object(forKey: key) != nil { GlobalStore.setBool(defaults.bool(forKey: key), key) }
        }
        if GlobalStore.string("cacheLimitGB") == nil, let c = defaults.object(forKey: "cacheLimitGB") as? Int { GlobalStore.setInt(c, "cacheLimitGB") }
        if GlobalStore.string("isConfigured") == nil, defaults.object(forKey: "isConfigured") != nil { GlobalStore.setBool(defaults.bool(forKey: "isConfigured"), "isConfigured") }
        if GlobalStore.data("servers") == nil, let d = defaults.data(forKey: "servers") { GlobalStore.setData(d, "servers") }

        GlobalStore.setBool(true, "didMigrateGlobals")
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            GlobalStore.setData(data, "servers")
        }
        enqueueGlobalSync()
    }

    // MARK: Servers

    var primaryServer: PlexServerRef? { servers.first }

    func server(id: String) -> PlexServerRef? {
        servers.first { $0.id == id }
    }

    func token(forServer id: String) -> String? {
        Keychain.getSecret("plexToken-\(id)")
    }

    func addServer(_ server: PlexServerRef, token: String) {
        Keychain.setSecret(token, for: "plexToken-\(server.id)")
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
    }

    func removeServer(id: String) {
        Keychain.deleteSecret("plexToken-\(id)")
        servers.removeAll { $0.id == id }
    }

    /// Wipes the entire Plex connection (servers + account token) and returns to
    /// onboarding to re-link. Keeps TMDB and the torrent config.
    func resetPlex() {
        for server in servers {
            Keychain.deleteSecret("plexToken-\(server.id)")
        }
        servers = []
        Keychain.deleteSecret("plexToken")
        Keychain.deleteSecret("plexAccountToken")
        isConfigured = false
    }

    // MARK: Account / TMDB / secrets (all global)

    var plexAccountToken: String? { Keychain.getSecret("plexAccountToken") }
    var tmdbKey: String? { Keychain.getSecret("tmdbKey") }
    var prowlarrKey: String? { Keychain.getSecret("prowlarrKey") }
    var openSubtitlesKey: String? { Keychain.getSecret("osKey") }
    var openSubtitlesPass: String? { Keychain.getSecret("osPass") }

    func saveProwlarrKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { Keychain.deleteSecret("prowlarrKey") } else { Keychain.setSecret(clean, for: "prowlarrKey") }
        enqueueGlobalSync()
    }
    func saveOpenSubtitlesKey(_ key: String) { Keychain.setSecret(key, for: "osKey"); enqueueGlobalSync() }
    func saveOpenSubtitlesPass(_ pass: String) { Keychain.setSecret(pass, for: "osPass"); enqueueGlobalSync() }

    var aiKey: String? { Keychain.getSecret("aiKey") }
    func saveAIKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { Keychain.deleteSecret("aiKey") } else { Keychain.setSecret(clean, for: "aiKey") }
        enqueueGlobalSync()
    }
    /// Trakt Client ID (global service config).
    var traktClientID: String? { Keychain.getSecret("traktClientID") }
    func saveTraktClientID(_ id: String) {
        let clean = id.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { Keychain.deleteSecret("traktClientID") } else { Keychain.setSecret(clean, for: "traktClientID") }
        enqueueGlobalSync()
    }
    var traktReady: Bool { (traktClientID?.isEmpty == false) }
    /// Trakt Client Secret (global service config; needed for device-code login).
    var traktClientSecret: String? { Keychain.getSecret("traktClientSecret") }
    func saveTraktClientSecret(_ s: String) {
        let clean = s.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { Keychain.deleteSecret("traktClientSecret") } else { Keychain.setSecret(clean, for: "traktClientSecret") }
        enqueueGlobalSync()
    }

    var aiReady: Bool {
        !aiModel.trimmingCharacters(in: .whitespaces).isEmpty
            && (aiKey != nil || (aiProvider == "custom" && !aiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty))
    }

    var openSubtitlesReady: Bool {
        openSubtitlesKey != nil && !openSubtitlesUser.isEmpty && openSubtitlesPass != nil
    }

    /// Show the full TMDB catalog? Only requires TMDB; enabled by Streaming Mode OR
    /// when NO server is configured.
    var fullCatalogEnabled: Bool {
        tmdbKey != nil && (streamingModeEnabled || servers.isEmpty)
    }

    /// Ready to play from torrents? Behind the explicit Streaming Mode toggle + Prowlarr + TorrServer.
    var streamingModeReady: Bool {
        streamingModeEnabled && tmdbKey != nil && !prowlarrURL.isEmpty && prowlarrKey != nil && !torrServerURL.isEmpty
    }

    func saveAccountToken(_ token: String) {
        Keychain.setSecret(token, for: "plexAccountToken")
        enqueueGlobalSync()
    }

    func saveTMDBKey(_ key: String) {
        Keychain.setSecret(key, for: "tmdbKey")
        hasTMDB = true
        enqueueGlobalSync()
    }

    #if LUMORA_ICLOUD
    /// Re-reads PER-USER config from UserDefaults after iCloud KVS delivered remote
    /// changes. Global config lives in the user-independent keychain (not via KVS).
    /// Re-reads the DEVICE-WIDE prefs mirrored via KVS (picture mode + audio
    /// passthrough; app language is owned by L10nStore). Personal audio/subtitle/HUD
    /// prefs are PER-PROFILE now → they are reloaded from the active profile's keys
    /// (NEVER from the legacy device-wide keys, which would clobber the profile).
    func reloadFromDefaults() {
        let cm = defaults.string(forKey: "videoColorMode") ?? "normal"
        if videoColorMode != cm { videoColorMode = cm }
        let pt = (defaults.object(forKey: "audioPassthrough") as? Bool) ?? false
        if audioPassthrough != pt { audioPassthrough = pt }
        reloadProfilePrefs()
    }
    #endif

    func completeOnboarding() {
        isConfigured = true
    }

    func reset() {
        for server in servers {
            Keychain.deleteSecret("plexToken-\(server.id)")
        }
        isConfigured = false
        servers = []
        hasTMDB = false
        Keychain.deleteSecret("plexToken")
        Keychain.deleteSecret("plexAccountToken")
        Keychain.deleteSecret("tmdbKey")
    }
}
