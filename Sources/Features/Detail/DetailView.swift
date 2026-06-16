import SwiftUI

struct DetailView: View {
    let item: MediaItem

    @StateObject private var vm = DetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var playable: PlayableMedia?
    @State private var sourceOptions: [PlaybackResolver.Option] = []
    @State private var pendingEpisode: TMDBBrowse.DiscoverEpisode?
    @State private var showSourcePicker = false
    @State private var resolving = false
    @State private var playbackError = false
    @State private var errorText: String?
    @State private var similarSelection: MediaItem?
    @State private var personSelection: CastMember?
    @State private var pendingResume: PlayableMedia?
    /// Virtual/torrent flow: saved progress found before resolving — ask first.
    @State private var torrentResumeOffsetMs: Int?
    /// Choice made in the torrent resume prompt (nil = none, 0 = from start, >0 = resume).
    @State private var resumeOverrideMs: Int?

    /// Effective item to display (enriched if it was virtual).
    private var m: MediaItem { vm.content ?? item }

    private var modalShown: Bool { showSourcePicker || pendingResume != nil || torrentResumeOffsetMs != nil || resolving }

    var body: some View {
        ZStack {
            backdrop

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 52) {
                    heroSection
                        .frame(minHeight: 740, alignment: .bottomLeading)

                    if m.type == "show", !vm.seasons.isEmpty {
                        seasonsSection
                    }

                    if !vm.cast.isEmpty {
                        castSection
                    }

                    if !vm.saga.isEmpty {
                        sagaSection
                    }

                    if !vm.similar.isEmpty {
                        similarSection
                    }

                    techSection
                        .padding(.bottom, 70)
                }
            }
            .scrollClipDisabled()
            // The background content stops being focusable when a modal is shown:
            // this traps focus in the modal and keeps the background from moving.
            .disabled(modalShown)
        }
        .ignoresSafeArea()
        .task { await vm.load(item: item) }
        .fullScreenCover(item: $playable) { media in
            PlayerView(media: media)
        }
        .fullScreenCover(item: $similarSelection) { selected in
            DetailView(item: selected)
        }
        .fullScreenCover(item: $personSelection) { person in
            PersonView(person: person)
        }
        .overlay {
            // Searching sources / preparing stream: blocks with a blurred background.
            if resolving {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark).ignoresSafeArea()
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 22) {
                        ProgressView().scaleEffect(1.6).tint(.white)
                        Text(tr(L.searchingSources))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .transition(.opacity)
                .focusSection()
                .onExitCommand { }   // blocks: ignores "back" while searching
            }
            if showSourcePicker {
                SourcePicker(options: sourceOptions) { option in
                    showSourcePicker = false
                    if let option { selectSource(option) }
                }
                .transition(.opacity)
            }
            if let pending = pendingResume {
                ResumePromptOverlay(offsetMs: pending.startOffsetMs) { choice in
                    pendingResume = nil
                    switch choice {
                    case .resume:
                        playable = pending
                    case .fromStart:
                        var fresh = pending
                        fresh.startOffsetMs = 0
                        playable = fresh
                    case .cancel:
                        break
                    }
                }
                .transition(.opacity)
            }
            // Virtual/torrent flow: same resume prompt, asked BEFORE resolving the
            // source (the offset lives in the local per-user state, not on a server).
            if let offset = torrentResumeOffsetMs {
                ResumePromptOverlay(offsetMs: offset) { choice in
                    torrentResumeOffsetMs = nil
                    switch choice {
                    case .resume:
                        resumeOverrideMs = offset
                        continueVirtualResolve(episode: pendingEpisode)
                    case .fromStart:
                        resumeOverrideMs = 0
                        continueVirtualResolve(episode: pendingEpisode)
                    case .cancel:
                        break
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: showSourcePicker)
        .animation(.smooth(duration: 0.25), value: pendingResume != nil)
        .animation(.smooth(duration: 0.2), value: resolving)
    }

    // MARK: Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            logoOrTitle

            HStack(spacing: 16) {
                if let year = m.year { Text(String(year)) }
                if let rating = m.audienceRating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
                if let duration = m.durationMs, m.type == "movie" {
                    let total = duration / 1000
                    let h = total / 3600, mins = (total % 3600) / 60
                    Text(h > 0 ? "\(h)h \(mins)m" : "\(mins)m")
                }
                if m.type == "show" {
                    if !vm.seasons.isEmpty {
                        Text("\(vm.seasons.count) \(tr(L.seasonsCount))")
                    }
                    if let count = episodeCount, count > 0 {
                        Text("\(count) \(tr(L.episodesCount))")
                    }
                }
                if let resolution = m.videoResolution {
                    heroBadge(resolution.lowercased() == "4k" ? "4K" : resolution.uppercased())
                }
                if let contentRating = m.contentRating {
                    heroBadge(contentRating)
                }
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.8))

            if !m.genres.isEmpty {
                Text(m.genres.split(separator: "|").joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(Theme.accentSoft)
            }

            if !m.displaySummary.isEmpty {
                Text(m.displaySummary)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(4)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            // In theaters / coming soon: no Play, show release dates.
            if vm.notYetReleased {
                releaseDatesPanel
            }

            HStack(spacing: 20) {
                if !vm.notYetReleased {
                    Button {
                        play()
                    } label: {
                        if resolving {
                            HStack(spacing: 12) { ProgressView(); Text(tr(L.play)) }
                        } else {
                            Label(playLabel, systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(resolving)
                }

                // Secondary actions: icon-only, round, with their own space.
                Button {
                    Task { await vm.toggleMyList() }
                } label: {
                    Image(systemName: vm.inMyList ? "checkmark" : "plus")
                }
                .buttonStyle(IconCircleButtonStyle(active: vm.inMyList))

                Button {
                    Task { await vm.rate(true) }
                } label: {
                    Image(systemName: vm.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .buttonStyle(IconCircleButtonStyle(active: vm.liked == true))

                Button {
                    Task { await vm.rate(false) }
                } label: {
                    Image(systemName: vm.liked == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .buttonStyle(IconCircleButtonStyle(active: vm.liked == false))

                // Trailer from TMDB (YouTube) — opened in the YouTube tvOS app.
                if vm.trailerYouTubeKey != nil {
                    Button { openTrailer() } label: {
                        Image(systemName: "film")
                    }
                    .buttonStyle(IconCircleButtonStyle(active: false))
                }
            }
            .padding(.top, 8)

            if let watchedAt = vm.watchedAt {
                Label("\(tr(L.watchedOn)) \(watchedAt.formatted(date: .long, time: .omitted))", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green.opacity(0.85))
            }

            if vm.nextIsMissing, let label = vm.nextEpisodeLabel {
                Label("\(label) — Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if playbackError {
                Text(tr(L.playbackError))
                    .font(.callout)
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .padding(.leading, 90)
        .padding(.trailing, 90)
        .padding(.top, 100)
    }

    /// Total episodes: from the library (leafCount) or summed from TMDB seasons.
    private var episodeCount: Int? {
        if let count = m.leafCount, count > 0 { return count }
        let total = vm.seasons.reduce(0) { $0 + $1.slots.count }
        return total > 0 ? total : nil
    }

    private var playLabel: String {
        if m.type == "show", let next = vm.nextEpisodeLabel, !vm.nextIsMissing {
            return "\(tr(L.play)) \(next)"
        }
        return tr(L.play)
    }

    /// True only if the theatrical release date has already passed; otherwise the
    /// movie is still upcoming ("Coming soon"), not "Now in theaters".
    private var isInTheatersNow: Bool {
        guard let theatrical = vm.theatricalDate else { return false }
        return theatrical <= TMDBBrowse.todayString
    }

    /// Dates panel for movies in theaters / coming soon (no playback).
    private var releaseDatesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isInTheatersNow ? tr(L.inTheatersNow) : tr(L.comingSoon),
                  systemImage: isInTheatersNow ? "popcorn.fill" : "calendar.badge.clock")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.accentSoft)
            if let theatrical = vm.theatricalDate {
                Label("\(tr(L.theatricalRelease)): \(formatReleaseDate(theatrical))", systemImage: "calendar")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
            }
            Label(vm.digitalDate != nil ? "\(tr(L.digitalRelease)): \(formatReleaseDate(vm.digitalDate!))" : tr(L.digitalTBD),
                  systemImage: "play.tv")
                .font(.callout).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.top, 4)
    }

    private func formatReleaseDate(_ iso: String) -> String {
        let inF = DateFormatter()
        inF.calendar = Calendar(identifier: .gregorian)
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        guard let date = inF.date(from: iso) else { return iso }
        let outF = DateFormatter()
        outF.locale = Locale(identifier: L10nStore.shared.effective == "es" ? "es" : "en")
        outF.dateStyle = .long
        return outF.string(from: date)
    }

    private func heroBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func play() {
        // Shows: starts at the first unwatched episode (or resumes the one in progress).
        if m.type == "show", let next = vm.firstUnwatchedEpisode() {
            playEpisode(next.slot, season: next.season)
            return
        }
        resolve(episode: nil)
    }

    /// Opens the TMDB trailer (YouTube) in the YouTube tvOS app.
    private func openTrailer() {
        guard let videoKey = vm.trailerYouTubeKey else { return }
        YouTubeLauncher.open(videoKey: videoKey)
    }

    private func playEpisode(_ slot: DetailViewModel.EpisodeSlot, season: Int, fromStart: Bool = false) {
        // Builds the episode (for torrent search/assembly on virtual content).
        let ep = TMDBBrowse.DiscoverEpisode(
            seasonNumber: season, episodeNumber: slot.number,
            name: slot.title ?? "Episodio \(slot.number)", overview: slot.overview,
            stillPath: nil, airDate: slot.airDate, runtime: nil
        )
        resolve(episode: ep, fromStart: fromStart)
    }

    /// Resolves sources (server + torrent) agnostically and decides how to play.
    private func resolve(episode: TMDBBrowse.DiscoverEpisode?, fromStart: Bool = false) {
        guard !resolving, torrentResumeOffsetMs == nil else { return }
        // Parental SECOND shield: block playback above the configured rating, even
        // if something slipped past the row filters. Authoritative (fetches cert).
        Task {
            guard await ParentalStore.shared.allowsPlayback(m) else {
                errorText = tr(L.parentalBlocked)
                return
            }
            pendingEpisode = episode
            resumeOverrideMs = fromStart ? 0 : nil

            // Virtual items with saved progress: ask resume/from-start FIRST.
            if m.isVirtual {
                if fromStart { continueVirtualResolve(episode: episode); return }
                let watchKey = virtualWatchKey(episode: episode)
                let offset = await VirtualLibrary.resumeOffset(watchKey: watchKey)
                if offset > 5000 { torrentResumeOffsetMs = offset }
                else { continueVirtualResolve(episode: episode) }
                return
            }
            resolveSources(episode: episode)
        }
    }

    private func virtualWatchKey(episode: TMDBBrowse.DiscoverEpisode?) -> String {
        episode.map {
            PlexPlayback.episodeWatchKey(showMergeKey: m.mergeKey, season: $0.seasonNumber, number: $0.episodeNumber)
        } ?? m.watchKey
    }

    /// Virtual flow after the resume decision (or with no progress):
    /// remembered torrent goes straight to the player; otherwise resolve sources.
    private func continueVirtualResolve(episode: TMDBBrowse.DiscoverEpisode?) {
        if let remembered = TorrentChoiceStore.get(watchKey: virtualWatchKey(episode: episode)) {
            openTorrent(remembered, episode: episode, isRemembered: true)
            return
        }
        resolveSources(episode: episode)
    }

    private func resolveSources(episode: TMDBBrowse.DiscoverEpisode?) {
        resolving = true
        playbackError = false
        errorText = nil
        Task {
            let resolved = await PlaybackResolver.resolve(item: m, episode: episode)
            resolving = false
            // A single server version → direct playback (same as Plex).
            if let sole = resolved.soleServer {
                startPlayback(sole.media)
                return
            }
            guard resolved.hasAny else {
                errorText = resolved.diagnostic
                playbackError = (resolved.diagnostic == nil)
                return
            }
            // Auto-best-source: plays the first option (server or the best torrent)
            // without asking. The manual picker remains in the player panel.
            if SettingsStore.shared.autoBestSource, let best = resolved.options.first {
                selectSource(best)
                return
            }
            sourceOptions = resolved.options
            showSourcePicker = true
        }
    }

    /// The user chose a source. Server → direct; torrent → opens the player and
    /// resolves the stream INSIDE (without blocking the detail on "searching sources").
    private func selectSource(_ option: PlaybackResolver.Option) {
        switch option.origin {
        case .server(let v):
            startPlayback(v.media)
        case .torrent(let release):
            openTorrent(release, episode: pendingEpisode)
        }
    }

    /// Opens the player immediately with a torrent yet to resolve (placeholder + PendingTorrent).
    private func openTorrent(_ release: TorrentRelease, episode: TMDBBrowse.DiscoverEpisode?, isRemembered: Bool = false) {
        guard let discover = DiscoverItem(media: m) else { return }
        let subtitle = episode.map { "\($0.code) · \($0.name)" } ?? release.title
        playable = PlayableMedia(
            ratingKey: "torrent-pending-\(m.tmdbID ?? 0)",
            serverID: "torrent",
            watchKey: m.mergeKey,
            refID: m.mergeKey,
            isEpisode: episode != nil,
            title: m.displayTitle,
            subtitle: subtitle,
            url: URL(string: "about:blank")!,
            durationMs: 0,
            startOffsetMs: 0,
            artPath: nil, thumbPath: nil, logoURL: nil, partID: nil, hasPreviewThumbnails: false,
            year: m.year, rating: m.audienceRating, contentRating: nil,
            resolution: release.quality, videoCodec: release.codec, fileSizeGB: release.sizeGB, hdrLabel: release.hdr,
            tmdbID: m.tmdbID, tmdbIsShow: m.type == "show",
            summary: m.displaySummary, genres: "",
            pendingTorrent: PendingTorrent(release: release, item: discover, episode: episode, startOverrideMs: resumeOverrideMs, isRemembered: isRemembered)
        )
    }

    /// With prior progress, asks how to play; without progress, plays directly.
    /// If the resume decision was already made (virtual flow), it is honored here.
    private func startPlayback(_ media: PlayableMedia) {
        if let override = resumeOverrideMs {
            var chosen = media
            chosen.startOffsetMs = override == 0 ? 0 : max(media.startOffsetMs, override)
            playable = chosen
            return
        }
        if media.startOffsetMs > 5000 {
            pendingResume = media
        } else {
            playable = media
        }
    }

    // MARK: Seasons and episodes (shows)

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Season picker.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(vm.seasons) { season in
                        Button {
                            vm.selectedSeason = season.number
                            Task { await vm.fillEpisodeNames(season: season.number) }
                        } label: {
                            HStack(spacing: 8) {
                                Text("T\(season.number)")
                                if season.missingCount > 0 {
                                    Text("\(season.missingCount)")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(.orange.opacity(0.85), in: Capsule())
                                        .foregroundStyle(.black)
                                }
                            }
                            .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(SeasonChipStyle(selected: vm.selectedSeason == season.number))
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 10)
            }
            .scrollClipDisabled()

            // Episodes of the selected season.
            if let season = vm.seasons.first(where: { $0.number == vm.selectedSeason }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 30) {
                        ForEach(season.slots) { slot in
                            EpisodeCard(
                                slot: slot,
                                seasonNumber: season.number,
                                isResolving: resolving
                                    && pendingEpisode?.seasonNumber == season.number
                                    && pendingEpisode?.episodeNumber == slot.number,
                                onPlay: { playEpisode(slot, season: season.number) },
                                onToggleWatched: {
                                    Task { await vm.toggleEpisodeWatched(season: season.number, slot: slot) }
                                },
                                onPlayFromStart: { playEpisode(slot, season: season.number, fromStart: true) }
                            )
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 28)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: Cast

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr(L.castTitle))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 90)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 36) {
                    ForEach(vm.cast) { member in
                        Button {
                            personSelection = member
                        } label: {
                            VStack(spacing: 12) {
                                CachedAsyncImage(url: member.profileURL)
                                    .frame(width: 140, height: 140)
                                    .clipShape(Circle())
                                Text(member.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                                if let character = member.character {
                                    Text(character)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 160)
                        }
                        .buttonStyle(CastCardStyle())
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: Collection / saga

    private var sagaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.sagaName.isEmpty ? tr(L.sagaTitle) : vm.sagaName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 90)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(vm.saga) { part in
                        Button {
                            // The current movie doesn't navigate to itself.
                            if part.mergeKey != m.mergeKey { similarSelection = part }
                        } label: {
                            VStack(spacing: 8) {
                                CachedAsyncImage(url: part.posterURL(width: 400, height: 600))
                                    .frame(width: 200, height: 300)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .strokeBorder(Theme.accent.opacity(part.mergeKey == m.mergeKey ? 0.9 : 0), lineWidth: 3)
                                    )
                                if let year = part.year {
                                    Text(String(year))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                        }
                        .buttonStyle(MediaCardStyle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 32)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: More like this

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr(L.similarTitle))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 90)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(vm.similar) { similarItem in
                        Button {
                            similarSelection = similarItem
                        } label: {
                            CachedAsyncImage(url: similarItem.posterURL(width: 400, height: 600))
                                .frame(width: 200, height: 300)
                        }
                        .buttonStyle(MediaCardStyle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 32)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: Technical details

    private var techSection: some View {
        HStack(spacing: 14) {
            if let resolution = m.videoResolution {
                techChip(resolution.lowercased() == "4k" ? "4K" : resolution.uppercased())
            }
            if let codec = m.audioCodec {
                techChip(codec.uppercased())
            }
            if let channels = m.audioChannels {
                techChip(channels == 8 ? "7.1" : channels == 6 ? "5.1" : "\(channels)ch")
            }
            if let server = m.server {
                techChip(server.name)
            }
            Spacer()
        }
        .padding(.leading, 90)
    }

    private func techChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.white.opacity(0.08), in: Capsule())
            .foregroundStyle(.white.opacity(0.6))
    }

    // MARK: Background

    private var backdrop: some View {
        ZStack {
            Theme.background
            CachedAsyncImage(url: m.artURL(width: 1920, height: 1080))
                .ignoresSafeArea()
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.15), location: 0),
                            .init(color: .black.opacity(0.75), location: 0.55),
                            .init(color: Theme.bgBottom.opacity(0.98), location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
    }

    @ViewBuilder
    private var logoOrTitle: some View {
        if let logo = m.logoURL, let url = URL(string: logo) {
            CachedAsyncImage(url: url, contentMode: .fit, showsPlaceholder: false)
                .frame(maxWidth: 520, maxHeight: 150, alignment: .leading)
        } else {
            Text(m.displayTitle)
                .font(.system(size: 64, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
    }

    private func formatTime(ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? String(format: "%d:%02d h", h, m) : "\(m) min"
    }
}

// MARK: - Episode card

private struct EpisodeCard: View {
    let slot: DetailViewModel.EpisodeSlot
    let seasonNumber: Int
    var isResolving: Bool = false
    let onPlay: () -> Void
    var onToggleWatched: () -> Void = {}
    var onPlayFromStart: () -> Void = {}

    var body: some View {
        Button {
            if slot.playable { onPlay() }
        } label: {
            ZStack(alignment: .bottomLeading) {
                // Episode image (or placeholder), clipped to the card.
                Group {
                    if let episode = slot.episode {
                        EpisodeThumb(episode: episode)
                    } else if let still = slot.stillURL {
                        // Virtual episode (TMDB): episode image, playable via a source.
                        CachedAsyncImage(url: still)
                    } else if slot.notYetAired, let air = slot.airDate {
                        // Not missing: it just hasn't aired yet. Show the date.
                        RoundedRectangle(cornerRadius: 0)
                            .fill(.white.opacity(0.04))
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "calendar.badge.clock").font(.title2)
                                    Text(formatEpisodeDate(air)).font(.caption.weight(.bold))
                                }
                                .foregroundStyle(Theme.accentSoft)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(.white.opacity(0.04))
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "questionmark.video").font(.title2)
                                    Text("Missing").font(.caption.weight(.bold))
                                }
                                .foregroundStyle(.orange.opacity(0.8))
                            )
                    }
                }
                .frame(width: 340, height: 192)
                .clipped()

                // Legibility gradient for the info now overlaid at the bottom.
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                    .frame(width: 340, height: 192)

                // Episode info ON the image (bottom), with the progress bar at the very edge.
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("E\(slot.number)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(slot.notYetAired ? Theme.accentSoft : (slot.isMissing ? .orange : Theme.accentSoft))
                        Text(slot.title ?? "")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(slot.isMissing && !slot.notYetAired ? 0.5 : 0.95))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if slot.watched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    if let progress = slot.progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(Theme.accent)
                                    .frame(width: geo.size.width * min(max(progress, 0.02), 1.0))
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(width: 340, alignment: .leading)
            }
            .frame(width: 340, height: 192)
            // Episode runtime, subtle, top-right.
            .overlay(alignment: .topTrailing) {
                if let mins = slot.durationMinutes, mins > 0 {
                    Text(Self.durationText(mins))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(8)
                }
            }
            // Spinner centered over the image while the source is being resolved.
            .overlay {
                if isResolving {
                    ZStack {
                        Color.black.opacity(0.55)
                        ProgressView().scaleEffect(1.3)
                    }
                    .frame(width: 340, height: 192)
                }
            }
        }
        .buttonStyle(MediaCardStyle(cornerRadius: 12))
        .opacity(slot.isMissing && !slot.notYetAired ? 0.75 : 1)
        // Long-press menu (like movie cards): mark/unmark this episode as watched.
        .contextMenu {
            if !slot.notYetAired {
                // Play from the beginning — only when there's saved progress.
                if slot.playable, slot.progress != nil || slot.inProgress {
                    Button {
                        onPlayFromStart()
                    } label: {
                        Label(tr(L.playFromStart), systemImage: "arrow.counterclockwise")
                    }
                }
                Button {
                    onToggleWatched()
                } label: {
                    Label(slot.watched ? tr(L.markUnwatched) : tr(L.markWatched),
                          systemImage: slot.watched ? "eye.slash" : "checkmark.circle")
                }
            }
        }
    }

    /// "45m" / "1h 5m" — episode runtime, compact.
    private static func durationText(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func formatEpisodeDate(_ iso: String) -> String {
        let inF = DateFormatter()
        inF.calendar = Calendar(identifier: .gregorian)
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        guard let date = inF.date(from: iso) else { return iso }
        let outF = DateFormatter()
        outF.locale = Locale(identifier: L10nStore.shared.effective == "es" ? "es" : "en")
        outF.dateFormat = "d MMM yyyy"
        return outF.string(from: date)
    }
}

private struct EpisodeThumb: View {
    let episode: Episode

    var body: some View {
        CachedAsyncImage(url: thumbURL)
    }

    @MainActor
    private var thumbURL: URL? {
        guard let server = SettingsStore.shared.server(id: episode.serverID),
              let token = SettingsStore.shared.token(forServer: episode.serverID) else { return nil }
        return PlexClient.imageURL(baseURL: server.url, token: token, path: episode.thumbPath, width: 680, height: 384)
    }
}

// MARK: - Version picker

struct VersionPickerOverlay: View {
    let versions: [PlayVersion]
    let onSelect: (PlayVersion?) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 28) {
                Text(tr(L.chooseVersion))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                VStack(spacing: 14) {
                    ForEach(versions) { version in
                        Button {
                            onSelect(version)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(Theme.accent)
                                    Text(version.serverName)
                                        .font(.callout.weight(.bold))
                                    Spacer()
                                    Text(version.qualityLabel)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(Theme.accentSoft)
                                }
                                HStack(spacing: 22) {
                                    if !version.audioLangs.isEmpty {
                                        Label(version.audioLangs.prefix(4).joined(separator: ", "), systemImage: "speaker.wave.2.fill")
                                    }
                                    if !version.subtitleLangs.isEmpty {
                                        Label(version.subtitleLangs.prefix(5).joined(separator: ", "), systemImage: "captions.bubble.fill")
                                    }
                                    Spacer()
                                }
                                .font(.caption)
                                .opacity(0.65)
                            }
                            .frame(width: 760, alignment: .leading)
                            .padding(22)
                        }
                        .buttonStyle(PremiumCardStyle())
                    }
                }

                Button(tr(L.cancel)) { onSelect(nil) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(60)
        }
        .onExitCommand { onSelect(nil) }
    }
}

// MARK: - Round icon button (detail secondary actions)

struct IconCircleButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, active: active)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let active: Bool

        private var iconColor: Color {
            if focused { return .black }
            return active ? Theme.accent : .white.opacity(0.85)
        }

        var body: some View {
            configuration.label
                // Small icon with breathing room around it; no box except on focus.
                .font(.system(size: 22, weight: .medium))
                .frame(width: 62, height: 62)
                .background(
                    Circle()
                        .fill(focused ? Color.white : .clear)
                )
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(focused ? 0 : 0.18), lineWidth: 1)
                )
                .foregroundColor(iconColor)
                .scaleEffect(focused ? 1.12 : 1.0)
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}

// MARK: - Resume modal

private struct ResumePromptOverlay: View {
    enum Choice { case resume, fromStart, cancel }

    let offsetMs: Int
    let onChoice: (Choice) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 30) {
                Text(tr(L.resumePromptTitle))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                VStack(spacing: 18) {
                    Button {
                        onChoice(.resume)
                    } label: {
                        Label("\(tr(L.resumeFrom)) \(formatOffset(offsetMs))", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .focused($focused)

                    Button {
                        onChoice(.fromStart)
                    } label: {
                        Label(tr(L.playFromStart), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button(tr(L.cancel)) { onChoice(.cancel) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(70)
        }
        .focusSection()
        .onExitCommand { onChoice(.cancel) }
        .onAppear { focused = true }
    }

    private func formatOffset(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Styles

private struct SeasonChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, selected: selected)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool

        var body: some View {
            configuration.label
                .padding(.horizontal, 26)
                .padding(.vertical, 11)
                .background(
                    focused ? AnyShapeStyle(.white) : (selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.white.opacity(0.06))),
                    in: Capsule()
                )
                .foregroundStyle(focused ? .black : .white.opacity(selected ? 1 : 0.65))
                .scaleEffect(focused ? 1.06 : 1.0)
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}

private struct CastCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(focused ? 1.12 : 1.0)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 20, y: 10)
                .animation(.smooth(duration: 0.22), value: focused)
        }
    }
}
