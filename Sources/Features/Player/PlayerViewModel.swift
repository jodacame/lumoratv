import SwiftUI
import QuartzCore
import GRDB
import UIKit

@MainActor
final class PlayerViewModel: ObservableObject {
    enum PanelTab: Hashable {
        case info, episodes, cast, audio, subtitles, source, settings
    }

    @Published private(set) var media: PlayableMedia
    let client = MPVClient()

    // Playback state
    @Published var timePos: Double = 0
    @Published var duration: Double
    @Published var paused = false
    @Published var buffering = true
    @Published var isHDR = false
    @Published var finished = false

    // UI state
    @Published var transportVisible = true {
        didSet {
            // Raise the subtitles while the bottom controls are up so they don't
            // sit behind them.
            guard transportVisible != oldValue else { return }
            client.setSubtitlePosition(raised: transportVisible)
        }
    }
    @Published var panelVisible = false
    @Published var panelTab: PanelTab = .info
    /// Target position during a cumulative seek (shows the floating thumbnail).
    @Published var seekTarget: Double?

    @Published var audioTracks: [MPVTrack] = []
    @Published var subTracks: [MPVTrack] = []
    @Published var cast: [CastMember] = []

    /// "Stats for nerds" overlay (polled every second while enabled).
    @Published var nerdStats: MPVClient.NerdStats?
    private var nerdStatsTask: Task<Void, Never>?


    // Torrent (external source): live stats and release switching.
    @Published var torrentStats: TorrServerClient.Stats?
    @Published var sourceReleases: [TorrentRelease] = []
    @Published var sourceLoading = false
    @Published var showSourcePicker = false   // player-level source picker

    // Social (Trakt) — community comments panel (read-only, phase 1).
    @Published var showComments = false
    @Published var comments: [TraktComment] = []
    @Published var commentsLoading = false
    @Published var communityRating: Double?
    @Published var communityVotes = 0
    @Published var revealedSpoilers: Set<Int> = []
    private var commentsLoaded = false
    private var lastScrobble: TraktScrobbleAction?
    private var scrobbleStarted = false
    private var markedWatched = false

    var isTorrent: Bool { media.serverID == "torrent" }
    private var statsTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var subReassertTask: Task<Void, Never>?
    private var scrobbleTimer: Task<Void, Never>?
    private var pendingLayer: CAMetalLayer?
    private var sourceLoaded = false

    // MARK: Auto failover (auto-best source)
    /// On-screen notice shown in the loading overlay while auto-switching sources.
    @Published var failoverNotice: String?
    /// Releases already tried in this session, so failover never repeats one.
    private var triedReleaseIDs: Set<String> = []
    /// True once a file actually loaded. From then on, a failure NEVER
    /// auto-switches the source — the user is already watching.
    private var playbackEverStarted = false
    /// True once mpv has been started (vs. still resolving the pending torrent).
    private var clientStarted = false
    private var failoverBusy = false
    /// Set while starting the user's remembered torrent (continue watching):
    /// grants extra startup patience; a startup failure clears this memory so
    /// a dead choice isn't retried forever.
    private var rememberedWatchKey: String?

    /// Unified panel episode (works for the Plex library and for torrents/TMDB).
    struct PanelEpisode: Identifiable, Sendable {
        let seasonNumber: Int
        let episodeNumber: Int
        let title: String
        let thumbURL: URL?
        let refID: String?    // == media.refID to mark the one currently playing
        var id: String { "s\(seasonNumber)e\(episodeNumber)" }
    }
    /// Seasons/episodes of the show being played (Episodes tab).
    struct PanelSeason: Identifiable {
        let number: Int
        var episodes: [PanelEpisode]
        var id: Int { number }
    }
    @Published var chapters: [MPVClient.MPVChapter] = []
    @Published var panelSeasons: [PanelSeason] = []
    @Published var panelSeason = 1
    private var panelShowItem: MediaItem?
    private var episodesLoading = false

    /// Active marker under the playback cursor (intro/credits).
    @Published var activeMarker: PlayerMarker?
    /// Network/file error mid-playback.
    @Published var playbackFailed = false
    /// Concrete reason for the last failure (mpv error / log line), shown on the
    /// error overlay so a misconfigured source is diagnosable on-screen.
    @Published var playbackErrorDetail: String?
    /// Post-play screen when finishing (movie, end of series, or missing episode).
    @Published var postPlay: PostPlayState?
    @Published var postPlayLiked: Bool?

    struct PostPlayState {
        enum Kind {
            case movieFinished
            case seriesFinished
            case missingNext(season: Int, episode: Int)
        }
        let kind: Kind
        let item: MediaItem?
        let similar: [MediaItem]
        /// true when `similar` came from the personal recommender ("For You")
        /// because no content-similar titles were found.
        var similarIsPersonal: Bool = false
    }
    /// Next episode ready to chain (card with countdown).
    @Published var nextUp: PlayableMedia?
    @Published var nextCountdown = 15
    /// True while the final auto-advance countdown is actually running (vs the
    /// card just being shown during the credits, where it stays manual).
    @Published var nextCountingDown = false
    /// Length (s) of the auto-advance countdown at the end of an episode.
    private let nextUpCountdownSeconds = 15
    /// Series progress for the player line: total aired episodes and the 1-based
    /// position of the current episode. Everything before the current episode is
    /// assumed watched (progress is based on where you are now).
    @Published var seriesTotal = 0
    @Published var seriesIndex = 0
    /// Adjacent episodes (for the "‹ prev · next ›" line). nil = start/end of series.
    @Published var prevEpisodeRef: SeriesEpisodeRef?
    @Published var nextEpisodeRef: SeriesEpisodeRef?

    struct SeriesEpisodeRef: Equatable {
        let season: Int
        let number: Int
        let name: String
    }

    // MARK: Learning mode (opt-in; everything below is inert when off)
    /// True while learning mode is actually drawing the styled subtitle.
    @Published var learningActive = false
    /// Styled segments of the current target-language line (new words highlighted).
    @Published var targetSegments: [SubtitleAnalyzer.Segment] = []
    /// Current native-language line (dim, for meaning).
    @Published var nativeSubLine = ""
    /// "What was said?" recall panel (shown while paused in learning mode).
    @Published var showLearningRecall = false
    @Published private(set) var recallLines: [RecallLine] = []
    @Published private(set) var sessionNewWords = 0
    struct RecallLine: Identifiable, Equatable { let id = UUID(); let target: String; let native: String; let timeSec: Double }
    private var currentTargetRaw = ""
    private var learningTargetLang = "en"
    private var episodeContentTotal = 0
    private var episodeKnownTotal = 0
    /// % of content words seen this episode that you already know.
    var sessionComprehension: Int {
        episodeContentTotal > 0 ? Int(Double(episodeKnownTotal) / Double(episodeContentTotal) * 100) : 0
    }
    /// Start time (s) of an embedded "credits" chapter for the current file, if any.
    private var chapterCreditsStart: Double?

    private var castLoaded = false
    private var pendingStartSeconds: Double = 0
    /// The user dismissed the card during the credits: respect their decision.
    private var nextUpDismissed = false
    private var reachedEnd = false
    private var fetchingNext = false

    private var hideTask: Task<Void, Never>?
    private var seekPreviewTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    init(media: PlayableMedia) {
        self.media = media
        duration = Double(media.durationMs) / 1000
        timePos = Double(media.startOffsetMs) / 1000
    }

    // MARK: Lifecycle

    func attach(layer: CAMetalLayer) {
        guard !started else { return }
        started = true
        pendingLayer = layer
        AudioSession.configureForPlayback()

        // Torrent pending resolution: the player is already open; we resolve the stream here
        // showing the loading overlay (instead of blocking the detail view on "Searching sources").
        if let pending = media.pendingTorrent {
            buffering = true
            triedReleaseIDs.insert(pending.release.id)
            if pending.isRemembered {
                rememberedWatchKey = pending.episode.map {
                    PlexPlayback.episodeWatchKey(showMergeKey: pending.item.mergeKey, season: $0.seasonNumber, number: $0.episodeNumber)
                } ?? pending.item.mergeKey
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let resolved: PlayableMedia
                    if let episode = pending.episode {
                        resolved = try await DiscoverPlayback.playableEpisode(
                            from: pending.release, item: pending.item, episode: episode,
                            startOverrideMs: pending.startOverrideMs
                        )
                    } else {
                        resolved = try await DiscoverPlayback.playable(
                            from: pending.release, item: pending.item,
                            startOverrideMs: pending.startOverrideMs
                        )
                    }
                    guard !Task.isCancelled else { return }
                    self.media = resolved
                    self.beginPlayback(layer: layer)
                } catch {
                    self.handleStartupFailure(detail: error.localizedDescription)
                }
            }
            return
        }

        beginPlayback(layer: layer)
    }

    /// Smart resume: when resuming, rewind 10s so the viewer recovers context.
    /// Previews (trailer fallback) keep their exact offset.
    private func smartResumeMs(_ offsetMs: Int) -> Int {
        guard media.previewDurationMs == nil, offsetMs > 15_000 else { return offsetMs }
        return offsetMs - 10_000
    }

    private func beginPlayback(layer: CAMetalLayer) {
        clientStarted = true
        let startMs = smartResumeMs(media.startOffsetMs)
        // TorrServer streams may not be seekable the instant mpv opens them, which
        // can silently drop the "start" option. Schedule an explicit seek at
        // fileLoaded as a fallback (no-op if mpv already started at the offset).
        if isTorrent, startMs > 1000 {
            pendingStartSeconds = Double(startMs) / 1000
        }
        // Prevents the screensaver: mpv renders to Metal and tvOS doesn't detect the video.
        UIApplication.shared.isIdleTimerDisabled = true
        let settings = SettingsStore.shared
        client.start(
            layer: layer,
            url: media.url,
            startSeconds: Double(startMs) / 1000,
            audioLang: Self.mpvLangCodes(settings.audioLang),
            subtitleLang: Self.mpvLangCodes(settings.subtitleLang),
            passthrough: settings.audioPassthrough,
            networkStream: isTorrent
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        applySubtitleStyle()
        startReporting()
        scheduleHide()
        startStatsPolling()
        startNerdStatsPolling()
    }

    /// Matches the Apple TV output mode to the content frame rate (eliminates the
    /// 24p→60 Hz cadence judder). Skipped for short trailer previews. If the fps
    /// isn't known yet at file load, retries once shortly after.
    private func applyFrameRateMatch(retry: Int = 1) {
        guard media.previewDurationMs == nil else { return }
        if let match = client.frameRateMatch() {
            FrameRateMatcher.match(refreshRate: match.refreshRate, dynamicRange: match.dynamicRange)
        } else if retry > 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.applyFrameRateMatch(retry: retry - 1)
            }
        }
    }

    private func startNerdStatsPolling() {
        nerdStatsTask?.cancel()
        guard SettingsStore.shared.playerShowNerdStats else {
            nerdStats = nil
            return
        }
        nerdStatsTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.nerdStats = self.client.nerdStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Toggle from the player's settings tab; persists like the rest of the prefs.
    func toggleNerdStats() {
        SettingsStore.shared.playerShowNerdStats.toggle()
        startNerdStatsPolling()
    }

    // MARK: Torrent — live stats and source switching

    private func startStatsPolling() {
        guard isTorrent, let hash = TorrServerClient.hash(from: media.url) else { return }
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.torrentStats = await TorrServerClient.stats(hash: hash)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Loads other sources (releases) of the same content to allow switching.
    func loadSourcesIfNeeded() {
        guard isTorrent, !sourceLoaded else { return }
        sourceLoaded = true
        reloadSources()
    }

    /// Searches for sources again (in case there are new ones or seeders changed).
    func refreshSources() {
        guard isTorrent, !sourceLoading else { return }
        reloadSources()
    }

    /// Opens the source picker (loads the list if needed). Also useful from the
    /// error overlay: if the connection was lost, it allows picking another torrent.
    func openSourcePicker() {
        loadSourcesIfNeeded()
        if sourceReleases.isEmpty { refreshSources() }
        showSourcePicker = true
    }

    private func reloadSources() {
        guard media.tmdbID != nil else { return }
        sourceLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceLoading = false }
            self.sourceReleases = await self.fetchReleases()
        }
    }

    /// Searches Prowlarr for all releases of the current content.
    /// Shared by the source picker and the auto-failover engine.
    private func fetchReleases() async -> [TorrentRelease] {
        guard let tmdbID = media.tmdbID else { return [] }
        let key = SettingsStore.shared.tmdbKey
        let imdbID = key != nil ? await TMDBBrowse.imdbID(tmdbID: tmdbID, isShow: media.tmdbIsShow, key: key!) : nil
        // Episode: searches with the "Title SxxEyy" pattern; movie: title (+ year).
        let query: String
        if media.isEpisode, let s = media.seasonNumber, let e = media.episodeNumber {
            query = String(format: "\(media.title) S%02dE%02d", s, e)
        } else if media.year != nil && !media.tmdbIsShow {
            query = "\(media.title) \(media.year!)"
        } else {
            query = media.title
        }
        return (try? await ProwlarrClient.search(query: query, imdbID: imdbID, isShow: media.tmdbIsShow)) ?? []
    }

    // MARK: Auto failover (auto-best source)

    /// A startup failure (resolution error, mpv error or stall before the first
    /// file load) lands here. With auto-best source enabled, it moves on to the
    /// next best untried release and shows a notice in the loading overlay.
    /// Once playback has started, failures NEVER switch the source: the regular
    /// error overlay (with its manual "Change source" option) takes over.
    private func handleStartupFailure(detail: String? = nil) {
        if let detail { playbackErrorDetail = detail }
        // Reputation: the indexer/uploader whose release failed to start loses points.
        if isTorrent, !playbackEverStarted {
            if let provider = media.sourceProvider {
                IndexerReputation.record(.failed, indexer: provider)
            }
            UploaderReputation.record(.failed, uploader: media.sourceGroup)
        }
        // The remembered choice failed to start: forget it so the next session
        // resolves fresh instead of retrying a dead torrent forever. (If the
        // failover finds a working source, that one becomes the new memory.)
        if !playbackEverStarted, let key = rememberedWatchKey {
            TorrentChoiceStore.clear(watchKey: key)
            rememberedWatchKey = nil
        }
        guard SettingsStore.shared.autoBestSource, isTorrent,
              !playbackEverStarted, !failoverBusy else {
            failoverNotice = nil
            playbackFailed = true
            buffering = false
            transportVisible = false
            hideTask?.cancel()
            return
        }
        failoverBusy = true
        playbackFailed = false
        buffering = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.failoverBusy = false }
            // Warm list (also feeds the source picker), ranked like the picker shows it.
            if self.sourceReleases.isEmpty {
                self.sourceReleases = await self.fetchReleases()
            }
            // Try candidates in order until one resolves to a playable stream.
            // mpv-level failures after loadFile re-enter handleStartupFailure.
            while let next = self.sourceReleases.first(where: { !self.triedReleaseIDs.contains($0.id) }) {
                self.triedReleaseIDs.insert(next.id)
                let label = next.qualityLabel.isEmpty ? next.indexer : "\(next.qualityLabel) · \(next.indexer)"
                self.failoverNotice = trf(L.sourceFailedTrying, label)
                // Keep the resume decision of the failed attempt: the pending
                // placeholder carries the prompt's choice; once resolved, the
                // media's own start offset reflects it.
                let override = self.media.pendingTorrent?.startOverrideMs
                    ?? (self.clientStarted ? self.media.startOffsetMs : nil)
                if let playable = await self.resolvePlayable(from: next, startOverrideMs: override) {
                    if self.clientStarted {
                        self.switchTo(playable)
                    } else if let layer = self.pendingLayer {
                        self.media = playable
                        self.beginPlayback(layer: layer)
                    }
                    self.startStatsPolling()
                    return
                }
                // This candidate didn't even resolve a stream: penalize and move on.
                IndexerReputation.record(.failed, indexer: next.indexer)
            }
            // Nothing left to try: give up with the regular error overlay.
            self.failoverNotice = nil
            self.playbackFailed = true
            self.buffering = false
        }
    }

    /// Builds the playable stream for a release of the current content
    /// (episode-aware: packs resolve to the exact episode file).
    /// `startOverrideMs` carries the resume decision across the failover chain.
    private func resolvePlayable(from release: TorrentRelease, startOverrideMs: Int? = nil) async -> PlayableMedia? {
        guard let tmdbID = media.tmdbID else { return nil }
        let item = DiscoverItem(
            tmdbID: tmdbID,
            isShow: media.tmdbIsShow,
            title: media.title,
            overview: media.summary,
            posterPath: nil,
            backdropPath: nil,
            year: media.year,
            rating: media.rating
        )
        if media.isEpisode, let s = media.seasonNumber, let e = media.episodeNumber {
            let episode = TMDBBrowse.DiscoverEpisode(
                seasonNumber: s, episodeNumber: e,
                name: media.subtitle ?? "", overview: media.summary,
                stillPath: nil, airDate: nil, runtime: nil
            )
            return try? await DiscoverPlayback.playableEpisode(from: release, item: item, episode: episode, startOverrideMs: startOverrideMs)
        }
        return try? await DiscoverPlayback.playable(from: release, item: item, startOverrideMs: startOverrideMs)
    }

    /// Switches to another release (another source) of the same content, in the same player.
    func switchToRelease(_ release: TorrentRelease) {
        guard let tmdbID = media.tmdbID else { return }
        // Mid-watch switch away from a WORKING stream: the user gave up on this
        // release (bad encode/audio/subs) — negative signal for its uploader.
        // A switch from the error overlay doesn't count: the release died on its own.
        if playbackEverStarted, !playbackFailed {
            UploaderReputation.record(.abandoned, uploader: media.sourceGroup)
        }
        showSourcePicker = false
        playbackFailed = false
        triedReleaseIDs.insert(release.id)
        let item = DiscoverItem(
            tmdbID: tmdbID,
            isShow: media.tmdbIsShow,
            title: media.title,
            overview: media.summary,
            posterPath: nil,
            backdropPath: nil,
            year: media.year,
            rating: media.rating
        )
        closePanel()
        Task { [weak self] in
            guard let self else { return }
            let next: PlayableMedia?
            if self.media.isEpisode, let s = self.media.seasonNumber, let e = self.media.episodeNumber {
                let episode = TMDBBrowse.DiscoverEpisode(
                    seasonNumber: s, episodeNumber: e,
                    name: self.media.subtitle ?? "", overview: self.media.summary,
                    stillPath: nil, airDate: nil, runtime: nil
                )
                next = try? await DiscoverPlayback.playableEpisode(from: release, item: item, episode: episode)
            } else {
                next = try? await DiscoverPlayback.playable(from: release, item: item)
            }
            if let next {
                self.switchTo(next)
                self.startStatsPolling()
            }
        }
    }

    /// Applies the saved picture mode to the running player (live, from the panel).
    func applyColorMode() {
        client.applyColorMode(SettingsStore.shared.videoColorMode)
    }

    // MARK: Social (Trakt community panel)

    /// Whether the community panel can be offered (Trakt configured + we know the title).
    var commentsAvailable: Bool {
        SettingsStore.shared.traktReady && media.tmdbID != nil
    }

    /// Opens the floating community panel (closes the top panel; playback continues).
    func openComments() {
        panelVisible = false
        showComments = true
        loadCommentsIfNeeded()
    }

    func closeComments() {
        showComments = false
    }

    func revealSpoiler(_ id: Int) {
        revealedSpoilers.insert(id)
    }

    /// Scrobbles the current content to Trakt (real-time "watching now"); a stop
    /// at ≥80% auto-marks it watched. Deduped so the same action isn't repeated.
    /// No-op when Trakt isn't linked.
    private func scrobble(_ action: TraktScrobbleAction) {
        guard media.reportsProgress, media.tmdbID != nil else { return }
        if action != .stop, lastScrobble == action { return }
        lastScrobble = action
        // Duration may not be reported by mpv yet at file-load → fall back to the
        // known media duration. Position at start may still be ~0 before the
        // resume seek lands → fall back to the resume offset, so Trakt extrapolates
        // the "watching now" position correctly instead of from 0.
        let dur = duration > 0 ? duration : Double(media.durationMs ?? 0) / 1000
        var pos = timePos
        if action == .start, pos < 1 { pos = Double(media.startOffsetMs) / 1000 }
        var progress = dur > 0 ? min(100, max(0, pos / dur * 100)) : 0
        // Scrobble is presence only; "watched" is handled by the 95% mark. Cap the
        // stop below Trakt's 80% completion threshold so it never adds a duplicate
        // play to the history.
        if action == .stop { progress = min(progress, 79) }
        TraktSync.scrobble(action, userID: UserContext.currentUserID,
                           watchKey: media.watchKey, progress: progress)
    }

    // Compose a comment (phase 2 — requires the current user's linked Trakt account).
    @Published var showCommentCompose = false
    @Published var commentDraft = ""
    @Published var commentSpoiler = false
    @Published var commentPosting = false

    var canComment: Bool {
        SettingsStore.shared.traktReady && media.tmdbID != nil
            && TraktAuth.isAuthorized(userID: UserContext.currentUserID)
    }

    func openCompose() {
        commentDraft = ""
        commentSpoiler = false
        showCommentCompose = true
    }

    func submitComment() {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split { $0.isWhitespace }.count
        guard !commentPosting, words >= 5,
              let tmdbID = media.tmdbID,
              let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty else { return }
        commentPosting = true
        let ref = TraktRef(
            tmdbID: tmdbID,
            isShow: media.isEpisode || media.tmdbIsShow,
            season: media.isEpisode ? media.seasonNumber : nil,
            episode: media.isEpisode ? media.episodeNumber : nil
        )
        let spoiler = commentSpoiler
        let userID = UserContext.currentUserID
        Task { [weak self] in
            guard let token = await TraktAuth.accessToken(userID: userID) else {
                self?.commentPosting = false
                return
            }
            let ok = await TraktClient.postComment(ref, text: text, spoiler: spoiler,
                                                   clientID: clientID, token: token)
            guard let self else { return }
            self.commentPosting = false
            if ok {
                self.showCommentCompose = false
                self.commentDraft = ""
                self.commentsLoaded = false   // reload to show the new comment
                self.loadCommentsIfNeeded()
            }
        }
    }

    private func loadCommentsIfNeeded() {
        guard !commentsLoaded, !commentsLoading,
              let tmdbID = media.tmdbID,
              let clientID = SettingsStore.shared.traktClientID, !clientID.isEmpty else { return }
        commentsLoading = true
        let isEpisode = media.isEpisode
        let isShow = isEpisode || media.tmdbIsShow
        let season = isEpisode ? media.seasonNumber : nil
        let episode = isEpisode ? media.episodeNumber : nil
        // Preferred language for surfacing: subtitle preference, else app language.
        let subPref = SettingsStore.shared.subtitleLang
        let preferredLang = subPref != "off" ? subPref : L10n.effectiveLanguage()
        Task { [weak self] in
            let content = await TraktClient.load(
                tmdbID: tmdbID, isShow: isShow,
                season: season,
                episode: episode,
                clientID: clientID, preferredLang: preferredLang
            )
            guard let self, self.media.tmdbID == tmdbID else { return }
            self.comments = content.comments
            self.communityRating = content.rating
            self.communityVotes = content.votes
            self.commentsLoaded = true
            self.commentsLoading = false
        }
    }

    // MARK: Learning mode

    /// Turns learning mode on/off to match the setting (called at load and from
    /// the panel toggle). Off restores mpv's normal subtitle rendering.
    func applyLearningMode() {
        if SettingsStore.shared.learningModeEnabled {
            startLearning()
        } else {
            stopLearning()
        }
    }

    private func startLearning() {
        let subs = client.tracks().filter { $0.type == "sub" }
        // Target = the subtitle you're watching with (the language you're learning).
        guard let target = subs.first(where: { $0.selected }) ?? subs.first else {
            learningActive = false
            return
        }
        learningTargetLang = Self.normalizeLang(target.lang) ?? "en"
        if !target.selected { client.setSubtitleTrack(target.id) }
        // Native = a different track in your language (for meaning), if present.
        let nativePref = SettingsStore.shared.subtitleLang
        if nativePref != "off",
           let native = subs.first(where: { $0.id != target.id && Self.langMatches($0.lang, nativePref) }) {
            client.setSecondarySubtitleTrack(native.id)
        } else {
            client.setSecondarySubtitleTrack(nil)
            nativeSubLine = ""
        }
        client.setSubtitleVisibility(false)   // we draw the styled subtitle ourselves
        learningActive = true
    }

    private func stopLearning() {
        guard learningActive else { return }
        learningActive = false
        targetSegments = []
        nativeSubLine = ""
        currentTargetRaw = ""
        showLearningRecall = false
        client.setSecondarySubtitleTrack(nil)
        client.setSubtitleVisibility(true)
    }

    private func handleTargetSubText(_ raw: String) {
        guard learningActive else { return }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line != currentTargetRaw else { return }
        currentTargetRaw = line
        guard !line.isEmpty else { targetSegments = []; return }

        let userID = UserContext.currentUserID
        let lang = learningTargetLang
        let result = SubtitleAnalyzer.segments(line: line, language: SubtitleAnalyzer.nlLanguage(lang)) { lemma in
            !VocabularyStore.shared.isKnown(lemma, userID: userID, lang: lang)
        }
        targetSegments = result.segments

        // Comprehension: how many content words you already knew (before recording).
        for lemma in result.lemmas {
            episodeContentTotal += 1
            if VocabularyStore.shared.isKnown(lemma, userID: userID, lang: lang) { episodeKnownTotal += 1 }
        }
        // Record one encounter per word (the movie is the spaced-repetition system).
        let fresh = VocabularyStore.shared.record(result.lemmas, userID: userID, lang: lang)
        sessionNewWords += fresh.count

        // Rolling buffer for the recall panel.
        recallLines.append(RecallLine(target: line, native: nativeSubLine, timeSec: timePos))
        if recallLines.count > 30 { recallLines.removeFirst() }
    }

    func closeLearningRecall() {
        showLearningRecall = false
        recallDetail = nil
        recallExplanation = nil
        if paused { client.setPause(false) }
    }

    /// Replays a recent line from its start (and resumes).
    func replayRecall(_ line: RecallLine) {
        showLearningRecall = false
        recallDetail = nil
        recallExplanation = nil
        client.seek(to: max(0, line.timeSec - 0.3))
        if paused { client.setPause(false) }
    }

    /// Speaks a line/word with on-device TTS (used while paused, so it's clear).
    func speakLearning(_ text: String) {
        LearningSpeaker.shared.speak(text, lang: learningTargetLang)
    }

    // MARK: Recall navigation + AI word explanation

    /// A recent line opened for its full explanation.
    @Published var recallDetail: RecallLine?
    /// The AI tutor explanation of the whole selected line.
    @Published var recallExplanation: Explanation?
    struct Explanation: Equatable {
        var text: String?
        var loading: Bool
        var failed: Bool
    }

    func openRecallDetail(_ line: RecallLine) {
        recallDetail = line
        explainLine(line)
    }
    func closeRecallDetail() {
        recallDetail = nil
        recallExplanation = nil
    }

    /// The language the AI answers in = the user's preferred subtitle language
    /// (falling back to the device language when it's "auto"/"off").
    private static func nativeLearningLang() -> String {
        let pref = SettingsStore.shared.subtitleLang
        if pref != "off", pref != "auto", !pref.isEmpty { return pref }
        return String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
    }

    /// Explains the whole line (meaning + word breakdown) with the configured AI
    /// provider, using ~5 lines before and after as conversation context. Cached.
    private func explainLine(_ line: RecallLine) {
        let settings = SettingsStore.shared
        guard settings.aiReady else {
            recallExplanation = Explanation(text: nil, loading: false, failed: true)
            return
        }
        recallExplanation = Explanation(text: nil, loading: true, failed: false)

        let target = learningTargetLang
        let native = Self.nativeLearningLang()
        // Context: up to 5 lines before + 5 after the selected one (from the buffer).
        var context: [String] = []
        if let idx = recallLines.firstIndex(of: line) {
            context += recallLines[max(0, idx - 5)..<idx].map(\.target)
            context += recallLines[(idx + 1)..<min(recallLines.count, idx + 6)].map(\.target)
        }
        let sentence = line.target
        let cacheKey = "line:\(sentence.lowercased().prefix(140))|\(target)|\(native)"
        let config = AIService.Config(
            baseURL: AIService.providerBaseURL(settings.aiProvider, custom: settings.aiBaseURL),
            apiKey: settings.aiKey,
            model: settings.aiModel
        )
        Task { [weak self] in
            if let cached = await AIWordCache.shared.get(cacheKey) {
                guard let self, self.recallDetail == line else { return }
                self.recallExplanation = Explanation(text: cached, loading: false, failed: false)
                return
            }
            let result = await AIService.explainLine(sentence, context: context, target: target, native: native, config: config)
            if let result { await AIWordCache.shared.set(cacheKey, result) }
            guard let self, self.recallDetail == line else { return }
            self.recallExplanation = Explanation(text: result, loading: false, failed: result == nil)
        }
    }

    func applySubtitleStyle() {
        let s = SettingsStore.shared
        let size = switch s.subSize {
        case "small": "32"
        case "large": "56"
        case "xlarge": "74"
        default: "42"
        }
        let font: String? = switch s.subFont {
        case "rounded": "Avenir Next"
        case "serif": "Georgia"
        case "mono": "Menlo"
        default: nil
        }
        let color = switch s.subColor {
        case "yellow": "#FFD75E"
        case "cyan": "#7FE7FF"
        default: "#FFFFFF"
        }
        client.applySubtitleStyle(fontSize: size, font: font, colorHex: color)
    }

    func stopPlayback() {
        guard started, !stopped else { return }
        stopped = true
        scrobble(.stop)   // Trakt: stop watching (≥80% auto-marks watched)
        UIApplication.shared.isIdleTimerDisabled = false   // restores the screensaver on exit
        FrameRateMatcher.reset()                           // restores the default HDMI output mode
        reportTask?.cancel()
        hideTask?.cancel()
        seekPreviewTask?.cancel()

        let media = self.media
        let timeMs = Int(client.timePos * 1000)
        let durationMs = Int(duration * 1000)
        statsTask?.cancel()
        stallTask?.cancel()
        nerdStatsTask?.cancel()
        subReassertTask?.cancel()
        scrobbleTimer?.cancel()
        // Tell TorrServer we're done so it releases the torrent's resources
        // (drop keeps it in its DB — resuming later is instant).
        if isTorrent, let hash = TorrServerClient.hash(from: media.url) {
            Task.detached { await TorrServerClient.drop(hash: hash) }
        }
        client.shutdown()
        Task { await VideoThumbnailer.shared.clear() }

        guard media.reportsProgress else { return }
        Task.detached {
            await PlexPlayback.reportTimeline(
                media: media,
                state: .stopped,
                timeMs: max(timeMs, 0),
                durationMs: durationMs
            )
            await MainActor.run { SyncStatus.shared.generation += 1 }
        }
    }

    // MARK: mpv events

    /// Stall watchdog: if a torrent stays buffering too long (no seeds,
    /// TorrServer down, network timeout), we treat it as a failure and offer a retry.
    private func scheduleStallTimeout() {
        guard isTorrent, !playbackFailed else { return }
        stallTask?.cancel()
        // The user's remembered choice gets extra patience: after a TorrServer
        // 'drop' it re-buffers from scratch, and a slow-but-alive torrent must
        // not be abandoned by auto-failover.
        let patience: Double = (rememberedWatchKey != nil && !playbackEverStarted) ? 90 : 45
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(patience))
            guard let self, !Task.isCancelled, self.buffering, !self.paused, !self.playbackFailed else { return }
            self.handleStartupFailure(detail: tr(L.playbackTimeout))
        }
    }

    private func handle(_ event: MPVClient.Event) {
        switch event {
        case .timePos(let value):
            if abs(value - timePos) >= 0.4 { timePos = value }
            // Trakt: send the FIRST scrobble start only once we have a real
            // position + duration (mpv reports duration after load and the resume
            // seek has landed), so the reported start point is exact.
            if !scrobbleStarted, value > 0.5, duration > 0, playbackEverStarted, !paused {
                scrobbleStarted = true
                scrobble(.start)
                startScrobbleHeartbeat()
            }
            // Trakt: mark watched proactively at 95% (once), while still playing —
            // more reliable than waiting for stop/exit, which can race teardown.
            if !markedWatched, media.reportsProgress, media.tmdbID != nil,
               duration > 0, value / duration >= 0.95 {
                markedWatched = true
                TraktSync.setWatched(userID: UserContext.currentUserID,
                                     watchKey: media.watchKey, watched: true)
            }
            updateActiveMarker(at: value)
            updateNextUp(at: value)
            // Preview (trailer fallback): closes when the duration is reached.
            if let preview = media.previewDurationMs {
                let endSec = Double(media.startOffsetMs) / 1000 + Double(preview) / 1000
                if value >= endSec { finished = true }
            }
        case .duration(let value):
            if value > 0 { duration = value }
        case .paused(let value):
            paused = value
            // Trakt: reflect pause/resume only after the initial start was sent.
            if scrobbleStarted { scrobble(value ? .pause : .start) }
            // Paused allows the screensaver; playing blocks it.
            UIApplication.shared.isIdleTimerDisabled = !value
            if value {
                transportVisible = true
                hideTask?.cancel()
            } else {
                scheduleHide()
            }
            // Learning mode: pausing reveals the "what was said?" recall (at the list).
            if learningActive {
                showLearningRecall = value && !recallLines.isEmpty
                recallDetail = nil
                recallExplanation = nil
            }
        case .buffering(let value):
            let wasBuffering = buffering
            buffering = value
            if value { scheduleStallTimeout() } else { stallTask?.cancel() }
            // Embedded subs over a torrent stream can silently stop rendering
            // after a cache underrun until the track is re-selected (mpv demuxer
            // quirk). When the buffer recovers, re-assert the active subtitle so
            // it keeps showing — invisible to the user (the spinner was up).
            if wasBuffering, !value, playbackEverStarted, !learningActive {
                scheduleSubtitleReassert()
            }
        case .fileLoaded:
            buffering = false
            stallTask?.cancel()
            // Reputation: the stream actually loaded — the indexer/uploader earn points.
            if isTorrent, !playbackEverStarted {
                if let provider = media.sourceProvider {
                    IndexerReputation.record(.loaded, indexer: provider)
                }
                UploaderReputation.record(.loaded, uploader: media.sourceGroup)
            }
            // From here on the user is watching: failures never auto-switch source.
            playbackEverStarted = true
            rememberedWatchKey = nil
            failoverNotice = nil
            playbackErrorDetail = nil
            // Plex external subtitles as selectable tracks.
            for sub in media.externalSubs {
                client.addSubtitle(url: sub.url, title: sub.title, lang: sub.lang)
            }
            if pendingStartSeconds > 1 {
                client.seek(to: pendingStartSeconds)
                pendingStartSeconds = 0
            }
            // Embedded chapters: detect a "credits" chapter so the next-episode
            // card can appear exactly when credits start (cheap, accurate).
            chapters = client.chapters()
            chapterCreditsStart = Self.creditsStart(in: chapters)
            // Picture mode (saturation/brightness…) per the user's preference.
            client.applyColorMode(SettingsStore.shared.videoColorMode)
            // Series progress + adjacent episodes line.
            loadSeriesContext()
            // Subtitles start where the controls aren't.
            client.setSubtitlePosition(raised: transportVisible)
            refreshTracksSoon()
            // Restore the remembered audio/subtitle once tracks (incl. external) are ready.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.restoreTrackChoices()
                self?.refreshTracks()
                self?.applyLearningMode()   // after tracks are known
            }
            applyFrameRateMatch()
            // Trakt scrobble start is sent from the time observer (once position +
            // duration are valid), not here, so the reported start point is exact.
        case .endOfFile:
            handleEndOfFile()
        case .playbackError(let detail):
            handleStartupFailure(detail: detail)
        case .sigPeak(let value):
            isHDR = value > 1.0
        case .videoParams:
            break
        case .subText(let s):
            handleTargetSubText(s)
        case .secondarySubText(let s):
            if learningActive { nativeSubLine = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    private func refreshTracks() {
        let all = client.tracks()
        audioTracks = all.filter { $0.type == "audio" }
        subTracks = all.filter { $0.type == "sub" }
    }

    // MARK: Interaction — video surface

    /// Touchpad click: shows the transport; if already visible, pauses/resumes.
    func surfaceTapped() {
        if panelVisible { return }
        if transportVisible {
            togglePause()
        } else {
            transportVisible = true
            scheduleHide()
        }
    }

    func togglePause() {
        client.setPause(!paused)
    }

    func hideTransport() {
        hideTask?.cancel()
        transportVisible = false
        seekTarget = nil
    }

    /// Cumulative seek: quick presses add up, the thumbnail follows the target.
    func seek(by delta: Double) {
        guard !panelVisible else { return }
        // Rewinding within the episode hides the next-episode card and stops its
        // countdown (the user clearly wants to keep watching this one).
        if delta < 0 { dismissNextUpForRewind() }
        let base = seekTarget ?? timePos
        let target = min(max(base + delta, 0), max(duration - 2, 0))
        seekTarget = target
        timePos = target
        client.seek(to: target)
        transportVisible = true
        scheduleHide()

        seekPreviewTask?.cancel()
        seekPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.seekTarget = nil
            self?.scrobbleResync()   // re-anchor Trakt's position after the seek
        }
    }

    /// Re-sends the current position to Trakt (after a seek, or on the heartbeat).
    /// Bypasses the dedup. No-op when not linked.
    private func scrobbleResync() {
        guard scrobbleStarted else { return }
        lastScrobble = nil
        scrobble(paused ? .pause : .start)
    }

    /// Periodically re-anchors Trakt's "now watching" position while playing, so it
    /// stays accurate (Trakt doesn't reliably extrapolate between events). ~2 min
    /// cadence — negligible against the API rate limit.
    private func startScrobbleHeartbeat() {
        scrobbleTimer?.cancel()
        scrobbleTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self, !Task.isCancelled, self.started, !self.stopped,
                      !self.paused, !self.buffering else { continue }
                self.scrobbleResync()
            }
        }
    }

    // MARK: Progressive seek (chained taps increase the jump)

    /// Step for each chained tap: 10s, 30s, 1m, 3m, 5m.
    private static let seekSteps: [Double] = [10, 30, 60, 180, 300]
    private static let chainWindow: TimeInterval = 1.6

    private var lastTapAt: Date?
    private var lastTapDirection = 0
    private var chainIndex = 0

    func tapForward() {
        handleTap(direction: 1)
    }

    func tapBackward() {
        handleTap(direction: -1)
    }

    private func handleTap(direction: Int) {
        guard !panelVisible else { return }
        let now = Date()
        let chained = lastTapDirection == direction
            && (lastTapAt.map { now.timeIntervalSince($0) < Self.chainWindow } ?? false)
        chainIndex = chained ? min(chainIndex + 1, Self.seekSteps.count - 1) : 0
        lastTapAt = now
        lastTapDirection = direction
        seek(by: Double(direction) * Self.seekSteps[chainIndex])
    }

    // MARK: Markers (skip intro / credits)

    private func updateActiveMarker(at seconds: Double) {
        let ms = Int(seconds * 1000)
        let current = media.markers.first {
            ms >= $0.startMs && ms < $0.endMs - 1500
        }
        if current != activeMarker {
            activeMarker = current
        }
    }

    /// Drives the next-episode card. It appears when the credits start (Plex
    /// marker → embedded chapter → otherwise the last 15s) as a manual prompt.
    /// The auto-advance countdown runs ONLY in the final 15s, tracking the real
    /// time left so it reaches 0 exactly at the episode's end (and freezes if
    /// playback is paused, since it's driven by position, not a wall clock).
    private func updateNextUp(at seconds: Double) {
        guard SettingsStore.shared.autoNextEpisode, media.isEpisode, media.reportsProgress,
              !nextUpDismissed, postPlay == nil, duration > 0 else { return }
        let remaining = duration - seconds
        guard remaining > 0 else { return }

        // Show the card from the credits.
        if nextUp == nil, !fetchingNext, let creditsAt = creditsStartSeconds(), seconds >= creditsAt {
            prepareNextUpEarly()
        }
        guard nextUp != nil else { return }

        // Activate the countdown only in the final stretch, tracking time-to-end.
        let window = Double(nextUpCountdownSeconds)
        if remaining <= window {
            nextCountingDown = true
            nextCountdown = max(1, Int(remaining.rounded(.up)))
            if remaining <= 0.5 { playNext() }
        } else {
            nextCountingDown = false
        }
    }

    /// Computes the current episode's position within the whole series (by TMDB
    /// season counts) plus the previous/next episode names. Everything before the
    /// current episode is treated as already watched, so progress reflects "how
    /// far into the series you are".
    private func loadSeriesContext() {
        seriesTotal = 0
        seriesIndex = 0
        prevEpisodeRef = nil
        nextEpisodeRef = nil
        guard media.isEpisode, let s = media.seasonNumber, let e = media.episodeNumber,
              let tmdbID = media.tmdbID, let key = SettingsStore.shared.tmdbKey else { return }
        Task { [weak self] in
            let seasons = await TMDBBrowse.seasons(showID: tmdbID, key: key)
            let aired = seasons.filter { $0.seasonNumber > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }
            let total = aired.reduce(0) { $0 + $1.episodeCount }
            let before = aired.filter { $0.seasonNumber < s }.reduce(0) { $0 + $1.episodeCount }
            guard total > 0 else { return }

            func ref(_ season: Int, _ eps: [TMDBBrowse.DiscoverEpisode], _ number: Int) -> SeriesEpisodeRef? {
                guard let ep = eps.first(where: { $0.episodeNumber == number }) else { return nil }
                return SeriesEpisodeRef(season: season, number: number, name: ep.name)
            }

            let cur = await TMDBBrowse.episodes(showID: tmdbID, season: s, key: key)
            var prev: SeriesEpisodeRef?
            var next: SeriesEpisodeRef?
            if e > 1 {
                prev = ref(s, cur, e - 1)
            } else if let ps = aired.last(where: { $0.seasonNumber < s }) {
                let peps = await TMDBBrowse.episodes(showID: tmdbID, season: ps.seasonNumber, key: key)
                if let last = peps.map(\.episodeNumber).max() { prev = ref(ps.seasonNumber, peps, last) }
            }
            if cur.contains(where: { $0.episodeNumber == e + 1 }) {
                next = ref(s, cur, e + 1)
            } else if let ns = aired.first(where: { $0.seasonNumber > s }) {
                let neps = await TMDBBrowse.episodes(showID: tmdbID, season: ns.seasonNumber, key: key)
                if let first = neps.map(\.episodeNumber).min() { next = ref(ns.seasonNumber, neps, first) }
            }

            guard let self else { return }
            self.seriesTotal = total
            self.seriesIndex = min(before + e, total)
            self.prevEpisodeRef = prev
            self.nextEpisodeRef = next
        }
    }

    /// Where the credits begin: Plex marker → embedded chapter → the last 15s
    /// (so the counter never starts with fewer than 15s of episode left).
    private func creditsStartSeconds() -> Double? {
        if let m = media.markers.first(where: { $0.type == "credits" }) {
            return Double(m.startMs) / 1000
        }
        if let c = chapterCreditsStart { return c }
        guard duration > 0 else { return nil }
        return max(0, duration - Double(nextUpCountdownSeconds))
    }

    /// Start time (s) of an embedded "credits/outro" chapter, if the release has one.
    private static func creditsStart(in chapters: [MPVClient.MPVChapter]) -> Double? {
        let keywords = ["credit", "outro", "ending", "créd", "end title", "endcard"]
        guard let c = chapters.first(where: { ch in
            let t = (ch.title ?? "").lowercased()
            return keywords.contains { t.contains($0) }
        }), c.time > 1 else { return nil }
        return c.time
    }

    private func prepareNextUpEarly() {
        guard SettingsStore.shared.autoNextEpisode else { return }
        guard media.isEpisode, media.reportsProgress,
              nextUp == nil, !nextUpDismissed, !fetchingNext, postPlay == nil else { return }
        fetchingNext = true
        let target = media   // the episode this lookup is for
        Task { [weak self] in
            guard let self else { return }
            defer { self.fetchingNext = false }
            // Torrent episode: reuses the pack or searches for the next one individually.
            if target.serverID == "torrent" {
                guard let next = await DiscoverPlayback.nextTorrentEpisode(after: target),
                      self.media.watchKey == target.watchKey,   // still on the same episode?
                      self.nextUp == nil, !self.nextUpDismissed else { return }
                self.presentNextUp(next)
                return
            }
            guard case .available(let next)? = await PlexPlayback.nextEpisodeOutcome(after: target),
                  self.media.watchKey == target.watchKey,
                  self.nextUp == nil, !self.nextUpDismissed else { return }
            self.presentNextUp(next)
        }
    }

    func skipActiveMarker() {
        guard let marker = activeMarker else { return }
        activeMarker = nil
        seek(by: Double(marker.endMs) / 1000 - timePos)
        seekTarget = nil
    }

    // MARK: Next episode

    private func handleEndOfFile() {
        reachedEnd = true
        // Reputation: watched to the end — the strongest positive signal.
        if isTorrent, media.previewDurationMs == nil {
            if let provider = media.sourceProvider {
                IndexerReputation.record(.completed, indexer: provider)
            }
            UploaderReputation.record(.completed, uploader: media.sourceGroup)
            // Finished watching WITH an embedded subtitle active: ground truth
            // that this group ships complete, usable subs (the user kept them
            // on for the whole runtime — no detection heuristics involved).
            if client.tracks().contains(where: { $0.type == "sub" && $0.selected && !$0.external }) {
                UploaderReputation.record(.subsUsed, uploader: media.sourceGroup)
            }
        }
        guard media.reportsProgress else {
            finished = true
            return
        }
        // Movie: post-play with similar titles and rating.
        if !media.isEpisode {
            Task { await buildPostPlay(.movieFinished) }
            return
        }
        // Next-episode suggestion disabled: exit without recommending.
        guard SettingsStore.shared.autoNextEpisode else {
            finished = true
            return
        }
        // The card is already visible: we're at the end, jump now.
        if nextUp != nil { playNext(); return }
        // The user dismissed it during the credits: exit when finished.
        if nextUpDismissed {
            finished = true
            return
        }
        let target = media   // resolve the next for THIS episode
        Task { [weak self] in
            guard let self else { return }
            // Torrent episode: next from the same pack or an individual search.
            if target.serverID == "torrent" {
                let next = await DiscoverPlayback.nextTorrentEpisode(after: target)
                guard self.media.watchKey == target.watchKey, self.nextUp == nil else { return }
                if let next { self.presentNextUp(next) } else { self.finished = true }
                return
            }
            let outcome = await PlexPlayback.nextEpisodeOutcome(after: target)
            guard self.media.watchKey == target.watchKey, self.nextUp == nil else { return }
            switch outcome {
            case .available(let next):
                self.presentNextUp(next)
            case .missing(let season, let episode):
                await self.buildPostPlay(.missingNext(season: season, episode: episode))
            case .seriesEnd:
                await self.buildPostPlay(.seriesFinished)
            case nil:
                self.finished = true
            }
        }
    }

    private func buildPostPlay(_ kind: PostPlayState.Kind) async {
        transportVisible = false
        hideTask?.cancel()
        let item = await PlexPlayback.libraryItem(for: media)
        var similar: [MediaItem] = []
        if let item {
            similar = await Recommend.similar(to: item, limit: 8)
            postPlayLiked = await RatingStore.get(userID: UserContext.currentUserID, mergeKey: item.mergeKey)
        }
        // Fallback: no content-similar titles (e.g. virtual/torrent content not in
        // the library) -> personal "For You" recommendations, excluding what just played.
        var personal = false
        if similar.isEmpty {
            let playedKey = item?.mergeKey
            similar = await Recommend.forUser(userID: UserContext.currentUserID, limit: 9)
                .filter { $0.mergeKey != playedKey }
            personal = !similar.isEmpty
        }
        postPlay = PostPlayState(kind: kind, item: item, similar: similar, similarIsPersonal: personal)
    }

    /// Retries after a network error: reloads the file at the current position.
    func retryPlayback() {
        playbackFailed = false
        playbackErrorDetail = nil
        buffering = true
        // If the torrent hasn't resolved yet (failed before having a URL), retry the resolution.
        if let pending = media.pendingTorrent, let layer = pendingLayer {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let resolved: PlayableMedia
                    if let episode = pending.episode {
                        resolved = try await DiscoverPlayback.playableEpisode(
                            from: pending.release, item: pending.item, episode: episode,
                            startOverrideMs: pending.startOverrideMs
                        )
                    } else {
                        resolved = try await DiscoverPlayback.playable(
                            from: pending.release, item: pending.item,
                            startOverrideMs: pending.startOverrideMs
                        )
                    }
                    self.media = resolved
                    self.beginPlayback(layer: layer)
                } catch {
                    self.handleStartupFailure(detail: error.localizedDescription)
                }
            }
            return
        }
        pendingStartSeconds = max(timePos - 3, 0)
        client.loadFile(url: media.url)
    }

    /// 👍/👎 from the post-play screen (repeating the vote clears it).
    func ratePostPlay(_ value: Bool) {
        guard let item = postPlay?.item else { return }
        let newValue: Bool? = (postPlayLiked == value) ? nil : value
        postPlayLiked = newValue
        Task {
            await RatingStore.set(userID: UserContext.currentUserID, mergeKey: item.mergeKey, liked: newValue)
        }
    }

    private func presentNextUp(_ next: PlayableMedia) {
        nextUp = next
        nextCountdown = nextUpCountdownSeconds
        nextCountingDown = false
    }

    /// The user rewound: drop the next-episode card and stop its countdown for
    /// the rest of this episode.
    private func dismissNextUpForRewind() {
        guard nextUp != nil else { return }
        nextUp = nil
        nextCountingDown = false
        nextUpDismissed = true
    }

    func playNext() {
        guard let next = nextUp else { return }
        nextUp = nil
        nextCountingDown = false
        switchTo(next)
    }

    /// Loads other content in the same player, resetting all state.
    private func switchTo(_ next: PlayableMedia) {
        scrobble(.stop)   // Trakt: stop the outgoing episode (≥80% auto-marks watched)
        // Persist the outgoing item's progress before leaving it, so advancing
        // from the credits (before EOF) still marks the finished episode watched.
        if media.reportsProgress {
            let outgoing = media
            let timeMs = Int(client.timePos * 1000)
            let durationMs = Int(duration * 1000)
            Task.detached {
                await PlexPlayback.reportTimeline(media: outgoing, state: .stopped, timeMs: max(timeMs, 0), durationMs: durationMs)
                await MainActor.run { SyncStatus.shared.generation += 1 }
            }
        }
        // Release the torrent we're leaving (different hash only: same-pack
        // episode chaining keeps the torrent alive).
        if isTorrent,
           let oldHash = TorrServerClient.hash(from: media.url),
           oldHash != TorrServerClient.hash(from: next.url) {
            Task.detached { await TorrServerClient.drop(hash: oldHash) }
        }
        nextUpDismissed = false
        reachedEnd = false
        playbackFailed = false
        postPlay = nil
        media = next
        timePos = Double(next.startOffsetMs) / 1000
        duration = Double(next.durationMs) / 1000
        buffering = true
        activeMarker = nil
        audioTracks = []
        subTracks = []
        cast = []
        castLoaded = false
        chapters = []
        chapterCreditsStart = nil
        nextUp = nil
        nextCountingDown = false
        // Social: reload community comments for the new episode/title.
        showComments = false
        comments = []
        communityRating = nil
        communityVotes = 0
        revealedSpoilers = []
        commentsLoaded = false
        lastScrobble = nil
        scrobbleStarted = false
        markedWatched = false
        scrobbleTimer?.cancel()
        seriesTotal = 0
        seriesIndex = 0
        prevEpisodeRef = nil
        nextEpisodeRef = nil
        // Learning: reset per-episode context (the session word count carries on).
        targetSegments = []
        nativeSubLine = ""
        currentTargetRaw = ""
        recallLines = []
        recallDetail = nil
        recallExplanation = nil
        episodeContentTotal = 0
        episodeKnownTotal = 0
        seekTarget = nil
        pendingStartSeconds = Double(smartResumeMs(next.startOffsetMs)) / 1000
        client.loadFile(url: next.url)
        // The previous file may have ended (keep-open pauses at EOF); make sure
        // the new one plays automatically.
        paused = false
        client.setPause(false)
        transportVisible = true
        scheduleHide()
    }

    func cancelNextUp() {
        nextUp = nil
        nextCountingDown = false
        if reachedEnd {
            // Nothing left to watch: exit.
            finished = true
        } else {
            // During the credits: dismiss the card and let them watch in peace.
            nextUpDismissed = true
        }
    }

    // MARK: Panel

    func openPanel() {
        guard !panelVisible else { return }
        panelVisible = true
        panelTab = .info
        transportVisible = false
        hideTask?.cancel()
        refreshTracks()
        loadCastIfNeeded()
        loadEpisodesIfNeeded()
        loadSourcesIfNeeded()
        chapters = client.chapters()
    }

    private func loadEpisodesIfNeeded() {
        guard media.isEpisode, panelSeasons.isEmpty, !episodesLoading else { return }
        episodesLoading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.episodesLoading = false }
            if self.isTorrent {
                await self.loadTorrentSeasons()
            } else {
                await self.loadLibrarySeasons()
            }
        }
    }

    /// Torrent series: seasons/episodes from TMDB (loads the current season,
    /// the rest on demand when switching season tabs).
    private func loadTorrentSeasons() async {
        guard let tmdbID = media.tmdbID, let key = SettingsStore.shared.tmdbKey else { return }
        let seasons = await TMDBBrowse.seasons(showID: tmdbID, key: key)
        guard !seasons.isEmpty else { return }
        panelSeasons = seasons.map { PanelSeason(number: $0.seasonNumber, episodes: []) }
        panelSeason = media.seasonNumber ?? seasons.first?.seasonNumber ?? 1
        await loadTorrentEpisodes(season: panelSeason)
    }

    private func loadTorrentEpisodes(season: Int) async {
        guard let tmdbID = media.tmdbID, let key = SettingsStore.shared.tmdbKey,
              let idx = panelSeasons.firstIndex(where: { $0.number == season }),
              panelSeasons[idx].episodes.isEmpty else { return }
        let eps = await TMDBBrowse.episodes(showID: tmdbID, season: season, key: key)
        guard let i = panelSeasons.firstIndex(where: { $0.number == season }) else { return }
        panelSeasons[i].episodes = eps.filter { $0.aired }.map { e in
            PanelEpisode(
                seasonNumber: e.seasonNumber, episodeNumber: e.episodeNumber, title: e.name,
                thumbURL: e.stillURL,
                refID: VirtualLibrary.episodeID(tmdbID: tmdbID, season: e.seasonNumber, number: e.episodeNumber)
            )
        }
    }

    private func loadLibrarySeasons() async {
        guard let show = await PlexPlayback.libraryItem(for: media) else { return }
        panelShowItem = show
        let mergeKey = show.mergeKey
        let copies: [MediaItem] = ((try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(GRDB.Column("type") == "show").fetchAll(db)
        }) ?? []).filter { $0.mergeKey == mergeKey }
        let showKeys = copies.map(\.id)
        let episodes: [Episode] = (try? await AppDatabase.shared.dbQueue.read { db in
            try Episode
                .filter(showKeys.contains(GRDB.Column("showKey")))
                .order(GRDB.Column("seasonNumber").asc, GRDB.Column("episodeNumber").asc)
                .fetchAll(db)
        }) ?? []

        var seen = Set<String>()
        let unique = episodes.filter { seen.insert("s\($0.seasonNumber)e\($0.episodeNumber)").inserted }
        let grouped = Dictionary(grouping: unique, by: \.seasonNumber)
        panelSeasons = grouped.keys.sorted().map { season in
            PanelSeason(number: season, episodes: (grouped[season] ?? []).map { ep in
                PanelEpisode(seasonNumber: ep.seasonNumber, episodeNumber: ep.episodeNumber,
                             title: ep.title, thumbURL: Self.plexThumb(ep), refID: ep.id)
            })
        }
        let currentRefID = media.refID
        if let current = try? await AppDatabase.shared.dbQueue.read({ db in
            try Episode.filter(GRDB.Column("id") == currentRefID).fetchOne(db)
        }) {
            panelSeason = current.seasonNumber
        }
    }

    private static func plexThumb(_ episode: Episode) -> URL? {
        guard let server = SettingsStore.shared.server(id: episode.serverID),
              let token = SettingsStore.shared.token(forServer: episode.serverID) else { return nil }
        return PlexClient.imageURL(baseURL: server.url, token: token, path: episode.thumbPath, width: 540, height: 304)
    }

    /// Changes the season visible in the panel (loads episodes if it's a torrent and they're missing).
    func selectPanelSeason(_ season: Int) {
        panelSeason = season
        guard isTorrent else { return }
        Task { [weak self] in await self?.loadTorrentEpisodes(season: season) }
    }

    /// Jumps to a chapter from the panel.
    func seekToChapter(_ chapter: MPVClient.MPVChapter) {
        closePanel()
        seek(by: chapter.time - timePos)
        seekTarget = nil
    }

    /// Chapter currently playing (to highlight it).
    func isCurrentChapter(_ chapter: MPVClient.MPVChapter) -> Bool {
        guard let index = chapters.firstIndex(of: chapter) else { return false }
        let next = index + 1 < chapters.count ? chapters[index + 1].time : .greatestFiniteMagnitude
        return timePos >= chapter.time && timePos < next
    }

    /// Switches to another episode in the same player. `fromStart` ignores any
    /// saved resume offset (used by the prev/next line, which starts the episode
    /// from the beginning).
    func switchToEpisode(season: Int, number: Int, fromStart: Bool = false) {
        if isTorrent {
            guard let tmdbID = media.tmdbID, let key = SettingsStore.shared.tmdbKey else { return }
            closePanel()
            buffering = true
            Task { [weak self] in
                guard let self else { return }
                let item = DiscoverItem(
                    tmdbID: tmdbID, isShow: true, title: self.media.title, overview: self.media.summary,
                    posterPath: nil, backdropPath: nil, year: self.media.year, rating: self.media.rating
                )
                let eps = await TMDBBrowse.episodes(showID: tmdbID, season: season, key: key)
                let episode = eps.first { $0.episodeNumber == number }
                    ?? TMDBBrowse.DiscoverEpisode(seasonNumber: season, episodeNumber: number, name: "", overview: "", stillPath: nil, airDate: nil, runtime: nil)
                let sources = await DiscoverPlayback.resolveEpisode(item: item, episode: episode)
                guard let best = sources.torrentReleases.first,
                      let next = try? await DiscoverPlayback.playableEpisode(from: best, item: item, episode: episode, startOverrideMs: fromStart ? 0 : nil) else {
                    self.playbackFailed = true
                    self.buffering = false
                    return
                }
                self.switchTo(next)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let show: MediaItem?
            if let s = self.panelShowItem { show = s } else { show = await PlexPlayback.libraryItem(for: self.media) }
            guard let show,
                  let best = (try? await PlexPlayback.resolveVersions(item: show, season: season, episodeNumber: number))?.first else { return }
            var media = best.media
            if fromStart { media.startOffsetMs = 0 }
            self.closePanel()
            self.switchTo(media)
        }
    }

    private func loadCastIfNeeded() {
        guard !castLoaded, let tmdbID = media.tmdbID,
              let key = SettingsStore.shared.tmdbKey else { return }
        castLoaded = true
        let isShow = media.tmdbIsShow
        Task { [weak self] in
            let members = await TMDBClient.credits(tmdbID: tmdbID, isShow: isShow, key: key)
            self?.cast = members
        }
    }

    func closePanel() {
        panelVisible = false
        transportVisible = true
        scheduleHide()
    }

    func selectAudio(_ track: MPVTrack) {
        client.setAudioTrack(track.id)
        TrackChoiceStore.saveAudio(Self.normalizeLang(track.lang), userID: UserContext.currentUserID, keys: trackChoiceKeys)
        refreshTracksSoon()
    }

    func selectSubtitle(_ track: MPVTrack?) {
        client.setSubtitleTrack(track?.id)
        let value: String?
        if let track {
            if let lang = Self.normalizeLang(track.lang) {
                value = lang
            } else {
                // Unlabeled embedded track (common in torrents): persist its
                // position among the subtitle tracks — stable for the same file —
                // so resuming the episode restores it even without a language tag.
                let subs = client.tracks().filter { $0.type == "sub" }
                value = "idx:\(subs.firstIndex(where: { $0.id == track.id }) ?? 0)"
            }
        } else {
            value = "off"
        }
        TrackChoiceStore.saveSubtitle(value, userID: UserContext.currentUserID, keys: trackChoiceKeys)
        refreshTracksSoon()
    }

    /// Keys under which this content's audio/subtitle choice is stored: the exact
    /// content plus, for episodes, a per-show key so the choice carries across the season.
    private var trackChoiceKeys: [String] {
        var keys = [media.watchKey]
        if media.isEpisode, let tmdbID = media.tmdbID { keys.append("show:\(tmdbID)") }
        return keys
    }

    /// Restores the remembered audio/subtitle for this content (called shortly
    /// after load, once tracks — including external subs — are available).
    private func restoreTrackChoices() {
        let userID = UserContext.currentUserID
        let keys = trackChoiceKeys
        let all = client.tracks()
        if let savedAudio = TrackChoiceStore.audio(userID: userID, keys: keys),
           let track = all.first(where: { $0.type == "audio" && Self.langMatches($0.lang, savedAudio) }) {
            client.setAudioTrack(track.id)
        }
        if let savedSub = TrackChoiceStore.subtitle(userID: userID, keys: keys) {
            if savedSub == "off" {
                client.setSubtitleTrack(nil)
            } else if savedSub.hasPrefix("idx:"), let idx = Int(savedSub.dropFirst(4)) {
                // Unlabeled track remembered by position.
                let subs = all.filter { $0.type == "sub" }
                if idx < subs.count { client.setSubtitleTrack(subs[idx].id) }
            } else if let track = all.first(where: { $0.type == "sub" && Self.langMatches($0.lang, savedSub) }) {
                client.setSubtitleTrack(track.id)
            } else if let ref = SubtitleRefStore.get(userID: userID, watchKey: media.watchKey, lang: savedSub) {
                // The chosen language isn't among the local tracks, but we have a
                // remembered OpenSubtitles file for this content (e.g. continuing
                // on another TV) — re-download and select it.
                downloadRememberedSubtitle(ref)
            }
        }
    }

    /// Re-downloads a previously used OpenSubtitles file (by reference) and selects
    /// it, so a downloaded subtitle "follows" the user to another device.
    private func downloadRememberedSubtitle(_ ref: SubtitleRefStore.Ref) {
        Task { [weak self] in
            guard let self,
                  let url = try? await OpenSubtitlesClient.download(fileID: ref.fileID) else { return }
            self.client.addAndSelectSubtitle(
                url: url,
                title: "OpenSubtitles · \(ref.lang.uppercased())",
                lang: ref.lang
            )
            self.applySubtitleStyle()
            self.refreshTracksSoon()
        }
    }

    /// Normalizes an mpv language tag to a 2-letter-ish code for storage.
    private static func normalizeLang(_ lang: String?) -> String? {
        guard let l = lang?.lowercased(), !l.isEmpty else { return nil }
        let map = ["spa": "es", "eng": "en", "por": "pt", "fre": "fr", "fra": "fr",
                   "ger": "de", "deu": "de", "ita": "it"]
        return map[l] ?? String(l.prefix(2))
    }

    // MARK: Subtitle download (OpenSubtitles)

    @Published var showSubtitleSearch = false
    @Published var osResults: [SubtitleResult] = []
    @Published var osSearching = false
    @Published var osError: String?
    @Published var osDownloadingID: Int?
    /// Search language chosen in the modal ("es", "en", …).
    @Published var osLanguage: String = "es"

    var openSubtitlesAvailable: Bool { SettingsStore.shared.openSubtitlesReady }

    func openSubtitleSearch() {
        // Initial language: the user's preference unless it's "off", otherwise Spanish.
        let pref = SettingsStore.shared.subtitleLang
        osLanguage = pref != "off" ? pref : "es"
        osResults = []
        osError = nil
        showSubtitleSearch = true
        guard openSubtitlesAvailable else {
            osError = tr(L.openSubtitlesNotConfigured)
            return
        }
        searchOpenSubtitles()
    }

    func searchOpenSubtitles() {
        guard !osSearching else { return }
        osSearching = true
        osError = nil
        osResults = []
        let language = osLanguage
        Task {
            do {
                osResults = try await OpenSubtitlesClient.search(media: media, languages: [language])
                if osResults.isEmpty { osError = tr(L.noSubtitlesFound) }
            } catch {
                osError = error.localizedDescription
            }
            osSearching = false
        }
    }

    func downloadOpenSubtitle(_ result: SubtitleResult) {
        guard osDownloadingID == nil else { return }
        osDownloadingID = result.fileID
        Task {
            do {
                let url = try await OpenSubtitlesClient.download(fileID: result.fileID)
                // The file DID carry embedded subs in this language, yet the user
                // had to rescue the session with external ones: the embedded subs
                // were unusable (out of sync, incomplete, machine-translated).
                if isTorrent, subTracks.contains(where: { !$0.external && Self.langMatches($0.lang, result.language) }) {
                    UploaderReputation.record(.subsRescued, uploader: media.sourceGroup)
                }
                client.addAndSelectSubtitle(url: url, title: "OpenSubtitles · \(result.language.uppercased())", lang: result.language)
                applySubtitleStyle()
                let normLang = Self.normalizeLang(result.language) ?? result.language
                TrackChoiceStore.saveSubtitle(normLang, userID: UserContext.currentUserID, keys: trackChoiceKeys)
                // Remember the OpenSubtitles file so the SAME subtitle re-downloads
                // automatically on another device (we store only the reference).
                SubtitleRefStore.save(userID: UserContext.currentUserID, watchKey: media.watchKey, lang: normLang, fileID: result.fileID)
                refreshTracksSoon()
                showSubtitleSearch = false   // closes the modal; the subtitle is already active
            } catch {
                osError = error.localizedDescription
            }
            osDownloadingID = nil
        }
    }

    // MARK: Preview thumbnails

    func previewThumbnailURL(at seconds: Double) -> URL? {
        guard media.hasPreviewThumbnails, let partID = media.partID else { return nil }
        // Quantized to 10s to reuse the image cache while scrubbing.
        let bucketMs = (Int(seconds) / 10) * 10 * 1000
        return PlexPlayback.previewThumbnailURL(partID: partID, timeMs: bucketMs, serverID: media.serverID)
    }

    // MARK: Helpers

    private func refreshTracksSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refreshTracks()
        }
    }

    /// Re-asserts the active subtitle shortly after the buffer recovers, so
    /// embedded subs don't stay blank after a torrent cache underrun. Debounced
    /// (rapid buffering bursts collapse into one re-assert).
    private func scheduleSubtitleReassert() {
        subReassertTask?.cancel()
        subReassertTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, !self.learningActive else { return }
            self.client.reselectSubtitle()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, !self.paused, !self.panelVisible, !self.navHold else { return }
            self.transportVisible = false
        }
    }

    /// Keeps the controls on screen while the user is on the prev/next episode
    /// line (so it doesn't auto-hide mid-decision); resumes the timer on exit.
    private var navHold = false
    func setNavHold(_ hold: Bool) {
        navHold = hold
        if hold {
            transportVisible = true
            hideTask?.cancel()
        } else {
            scheduleHide()
        }
    }

    /// Whether a track's language tag ("spa", "es-419", "eng") matches a
    /// 2-letter-ish preference code ("es", "en", "pt-br").
    private static func langMatches(_ trackLang: String?, _ code: String) -> Bool {
        guard let trackLang = trackLang?.lowercased(), !trackLang.isEmpty else { return false }
        let base = String(code.lowercased().prefix(2))
        let aliases: [String: [String]] = [
            "es": ["es", "spa"], "en": ["en", "eng"], "pt": ["pt", "por"],
            "fr": ["fr", "fre", "fra"], "de": ["de", "ger", "deu"], "it": ["it", "ita"],
        ]
        return (aliases[base] ?? [base]).contains { trackLang.hasPrefix($0) }
    }

    private static func mpvLangCodes(_ code: String) -> String? {
        // "auto" (original audio) / "off" (no subtitles) → let mpv decide.
        guard code != "auto", code != "off", !code.isEmpty else { return nil }
        return Languages.mpvCodes(code)
    }

    // MARK: Reporting to Plex

    private func startReporting() {
        guard media.reportsProgress else { return }
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !self.stopped else { return }
                let state: PlexPlayback.TimelineState = self.paused ? .paused : .playing
                let timeMs = Int(self.timePos * 1000)
                let durationMs = Int(self.duration * 1000)
                let media = self.media
                await PlexPlayback.reportTimeline(media: media, state: state, timeMs: timeMs, durationMs: durationMs)
            }
        }
    }
}
