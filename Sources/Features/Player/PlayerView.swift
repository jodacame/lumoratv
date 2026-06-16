import SwiftUI
import UIKit

/// Apple TV-style player: minimalist, no floating buttons.
///
/// Interaction (panel closed):
///   click → scrubber / pause · play-pause → pause · ◀▶ → seek ±10s with thumbnail · ▼ → panel
/// Interaction (panel open):
///   focus navigates tabs and tracks · Menu → closes panel
struct PlayerView: View {
    @StateObject private var vm: PlayerViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var surfaceFocused: Bool
    @FocusState private var skipFocused: Bool
    @FocusState private var nextUpFocused: Bool
    @FocusState private var navFocus: NavSide?
    @FocusState private var recallFocus: UUID?
    @FocusState private var recallActionFocus: Bool
    @FocusState private var commentFocus: Int?
    @FocusState private var commentComposeFocus: Bool
    @FocusState private var communityFocus: Bool
    @FocusState private var writeButtonFocus: Bool
    @State private var similarSelection: MediaItem?

    enum NavSide: Hashable { case prev, next }

    init(media: PlayableMedia) {
        _vm = StateObject(wrappedValue: PlayerViewModel(media: media))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            MPVVideoSurface(vm: vm)
                .ignoresSafeArea()

            // Focus catcher: the only focusable area while the panel is closed.
            if !vm.panelVisible && vm.postPlay == nil && !vm.showLearningRecall && !vm.showComments {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($surfaceFocused)
                    .onTapGesture { vm.surfaceTapped() }
                    .onMoveCommand { direction in
                        switch direction {
                        case .left: vm.tapBackward()
                        case .right: vm.tapForward()
                        case .down: vm.openPanel()
                        case .up:
                            // Up reveals the controls; if they're already up, it
                            // focuses the community button (when integrated), then the
                            // prev/next line for series (never pauses).
                            if !vm.transportVisible {
                                vm.surfaceTapped()
                            } else if vm.commentsAvailable {
                                communityFocus = true
                            } else if vm.media.isEpisode, vm.prevEpisodeRef != nil || vm.nextEpisodeRef != nil {
                                navFocus = vm.nextEpisodeRef != nil ? .next : .prev
                            }
                        @unknown default: break
                        }
                    }
            }

            // "Stats for nerds": discreet technical overlay (toggle in the settings tab).
            if let stats = vm.nerdStats, vm.postPlay == nil {
                NerdStatsOverlay(stats: stats, torrent: vm.torrentStats)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 60)
                    .padding(.leading, 60)
                    .allowsHitTesting(false)
            }

            if vm.buffering {
                if vm.isTorrent {
                    TorrentLoadingOverlay(stats: vm.torrentStats, title: vm.media.title, failoverNotice: vm.failoverNotice)
                } else {
                    ProgressView()
                        .scaleEffect(1.6)
                        .tint(.white.opacity(0.9))
                }
            }

            // Learning mode: our own styled subtitle (mpv's rendering is hidden).
            if vm.learningActive, !vm.panelVisible, vm.postPlay == nil, !vm.showLearningRecall,
               !vm.targetSegments.isEmpty || !vm.nativeSubLine.isEmpty {
                learningSubtitle
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            transport
                .opacity(vm.transportVisible && !vm.panelVisible && !vm.showLearningRecall && !vm.showComments ? 1 : 0)

            // "Skip intro/credits" button.
            if let marker = vm.activeMarker, !vm.panelVisible, vm.nextUp == nil, !vm.showLearningRecall {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            vm.skipActiveMarker()
                            surfaceFocused = true
                        } label: {
                            Label(
                                marker.type == "intro" ? tr(L.skipIntro) : tr(L.skipCredits),
                                systemImage: "forward.end.fill"
                            )
                            .font(.callout.weight(.bold))
                        }
                        .buttonStyle(SkipButtonStyle())
                        .focused($skipFocused)
                        .onMoveCommand { _ in surfaceFocused = true }
                    }
                    .padding(.trailing, 90)
                    .padding(.bottom, vm.transportVisible ? 260 : 80)
                }
                .transition(.opacity)
            }

            // "Next episode" card with countdown.
            if let next = vm.nextUp {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            vm.playNext()
                            surfaceFocused = true
                        } label: {
                            HStack(spacing: 20) {
                                ZStack {
                                    Circle()
                                        .stroke(.white.opacity(0.25), lineWidth: 4)
                                    if vm.nextCountingDown {
                                        Circle()
                                            .trim(from: 0, to: CGFloat(vm.nextCountdown) / 15)
                                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                        Text("\(vm.nextCountdown)")
                                            .font(.title3.weight(.bold))
                                            .monospacedDigit()
                                    } else {
                                        // Shown during the credits, before the final countdown.
                                        Image(systemName: "play.fill")
                                            .font(.title3.weight(.bold))
                                    }
                                }
                                .frame(width: 54, height: 54)
                                .animation(.linear(duration: 1), value: vm.nextCountdown)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(tr(L.nextEpisode))
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Theme.accentSoft)
                                    Text(next.subtitle ?? next.title)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                }
                                Image(systemName: "play.fill")
                                    .font(.callout)
                            }
                        }
                        .buttonStyle(SkipButtonStyle())
                        .focused($nextUpFocused)
                        .onMoveCommand { _ in surfaceFocused = true }
                    }
                    .padding(.trailing, 90)
                    .padding(.bottom, 80)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if vm.panelVisible {
                PlayerPanel(vm: vm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Learning mode: "what was said?" recall (shown while paused).
            if vm.showLearningRecall {
                learningRecall
                    .transition(.opacity)
            }

            // Social: floating community comments panel (right side, playback continues).
            if vm.showComments {
                commentsPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .disabled(vm.showCommentCompose)
            }

            // Social: compose a comment (over the panel).
            if vm.showCommentCompose {
                commentCompose
                    .transition(.opacity)
            }

            if vm.postPlay != nil {
                PostPlayOverlay(vm: vm, onExit: { dismiss() }, onSelectSimilar: { similarSelection = $0 })
                    .transition(.opacity)
            }

            if vm.playbackFailed {
                PlaybackErrorOverlay(
                    canChangeSource: vm.isTorrent,
                    detail: vm.playbackErrorDetail,
                    onRetry: { vm.retryPlayback() },
                    onChangeSource: { vm.openSourcePicker() },
                    onExit: { dismiss() }
                )
                .transition(.opacity)
            }

            if vm.showSubtitleSearch {
                SubtitleSearchOverlay(vm: vm)
                    .transition(.opacity)
            }

            // Player-level source picker (from the panel or from the error overlay).
            if vm.showSourcePicker {
                SourcePicker(options: vm.sourceReleases.map { PlaybackResolver.Option(origin: .torrent($0)) }) { option in
                    vm.showSourcePicker = false
                    if case .torrent(let release)? = option?.origin {
                        vm.switchToRelease(release)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: vm.transportVisible)
        .animation(.smooth(duration: 0.35), value: vm.panelVisible)
        .animation(.smooth(duration: 0.25), value: vm.showSubtitleSearch)
        .animation(.smooth(duration: 0.3), value: vm.activeMarker)
        .animation(.smooth(duration: 0.35), value: vm.nextUp?.id)
        .animation(.smooth(duration: 0.4), value: vm.postPlay != nil)
        .animation(.smooth(duration: 0.3), value: vm.playbackFailed)
        .animation(.smooth(duration: 0.2), value: vm.showSourcePicker)
        .fullScreenCover(item: $similarSelection) { item in
            DetailView(item: item)
        }
        .onPlayPauseCommand { vm.togglePause() }
        .onExitCommand {
            if vm.showCommentCompose {
                vm.showCommentCompose = false
            } else if vm.showComments {
                vm.closeComments()
            } else if vm.recallDetail != nil {
                vm.closeRecallDetail()
            } else if vm.showLearningRecall {
                vm.closeLearningRecall()
            } else if navFocus != nil {
                navFocus = nil
                surfaceFocused = true
            } else if vm.showSourcePicker {
                vm.showSourcePicker = false
            } else if vm.showSubtitleSearch {
                vm.showSubtitleSearch = false
            } else if vm.playbackFailed {
                dismiss()
            } else if vm.postPlay != nil {
                dismiss()
            } else if vm.nextUp != nil {
                vm.cancelNextUp()
            } else if vm.panelVisible {
                vm.closePanel()
            } else if vm.transportVisible {
                vm.hideTransport()
            } else {
                dismiss()
            }
        }
        .onChange(of: vm.activeMarker) { _, marker in
            if marker != nil, vm.nextUp == nil { skipFocused = true } else if vm.nextUp == nil { surfaceFocused = true }
        }
        .onChange(of: vm.nextUp?.id) { _, id in
            if id != nil { nextUpFocused = true } else { surfaceFocused = true }
        }
        .onChange(of: navFocus) { _, side in
            // Keep the controls up while the user is on the prev/next line.
            vm.setNavHold(side != nil || communityFocus)
        }
        .onChange(of: communityFocus) { _, f in
            // Keep the controls up while the community button is focused.
            if f { vm.setNavHold(true) } else if navFocus == nil { vm.setNavHold(false) }
        }
        .onChange(of: vm.showLearningRecall) { _, shown in
            if shown { recallFocus = vm.recallLines.last?.id } else { surfaceFocused = true }
        }
        .onChange(of: vm.recallDetail) { _, detail in
            if detail != nil { recallActionFocus = true }
            else if vm.showLearningRecall { recallFocus = vm.recallLines.last?.id }
        }
        .animation(.smooth(duration: 0.2), value: vm.showLearningRecall)
        .animation(.smooth(duration: 0.25), value: vm.showComments)
        .onChange(of: vm.showComments) { _, shown in
            if shown {
                // Focus the write button first (easy to reach); else the first comment.
                if vm.canComment { writeButtonFocus = true } else { commentFocus = vm.comments.first?.id }
            } else {
                surfaceFocused = true
            }
        }
        .onChange(of: vm.comments.first?.id) { _, id in
            // Only auto-focus a comment if nothing else is focused yet.
            if vm.showComments, !vm.canComment, commentFocus == nil { commentFocus = id }
        }
        .onChange(of: vm.showCommentCompose) { _, shown in
            if shown { commentComposeFocus = true } else if vm.showComments { commentFocus = vm.comments.first?.id }
        }
        .animation(.smooth(duration: 0.2), value: vm.showCommentCompose)
        .onChange(of: vm.finished) { _, finished in
            if finished { dismiss() }
        }
        .onChange(of: vm.panelVisible) { _, visible in
            if !visible { surfaceFocused = true }
        }
        .onAppear { surfaceFocused = true }
        .onDisappear { vm.stopPlayback() }
    }

    // MARK: Transport (Apple style: scrubber only, no buttons)

    /// Series line (pure white, small): previous episode ← progress · episodes
    /// left → next episode (or "Finish"). The prev/next names are focusable
    /// (reach with ↑); pressing one jumps to that episode from the start.
    private var seriesProgressIndicator: some View {
        let total = vm.seriesTotal
        let epFrac = vm.duration > 0 ? min(1, max(0, vm.timePos / vm.duration)) : 0
        let pct = total > 0 ? Int((min(1, (Double(vm.seriesIndex - 1) + epFrac) / Double(total)) * 100).rounded()) : 0
        let left = max(0, total - vm.seriesIndex)
        return HStack(spacing: 12) {
            if let prev = vm.prevEpisodeRef {
                episodeNavButton(prev, side: .prev)
            }
            Text(left > 0 ? "\(pct)% · " + trf(L.episodesLeftLong, left) : "\(pct)%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize()
                .layoutPriority(1)
            if let next = vm.nextEpisodeRef {
                episodeNavButton(next, side: .next)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                    Text(tr(L.seriesFinish))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
            }
        }
    }

    private func episodeNavButton(_ ref: PlayerViewModel.SeriesEpisodeRef, side: NavSide) -> some View {
        Button {
            vm.switchToEpisode(season: ref.season, number: ref.number, fromStart: true)
        } label: {
            HStack(spacing: 6) {
                if side == .next { Image(systemName: "arrow.right") }
                Text(ref.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: side == .prev ? .trailing : .leading)
                if side == .prev { Image(systemName: "arrow.left") }
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(EpisodeNavButtonStyle())
        .focused($navFocus, equals: side)
        .onMoveCommand { direction in
            switch direction {
            case .left:  if vm.prevEpisodeRef != nil { navFocus = .prev }
            case .right: if vm.nextEpisodeRef != nil { navFocus = .next }
            case .up, .down: surfaceFocused = true
            @unknown default: break
            }
        }
    }

    // Learning mode: our styled subtitle. Target = yellow with a black outline
    // for legibility; new words are bold + underlined. Native = white, smaller.
    private static let subtitleYellow = Color(red: 1.0, green: 0.84, blue: 0.37)

    private var learningSubtitle: some View {
        VStack(spacing: 6) {
            if !vm.nativeSubLine.isEmpty {
                Text(vm.nativeSubLine)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
            }
            if !vm.targetSegments.isEmpty {
                styledTargetText
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, vm.transportVisible ? 300 : 110)
        // Black outline (4 hard offsets) + soft halo so it reads on any scene.
        .shadow(color: .black, radius: 0.5, x: 1.8, y: 0)
        .shadow(color: .black, radius: 0.5, x: -1.8, y: 0)
        .shadow(color: .black, radius: 0.5, x: 0, y: 1.8)
        .shadow(color: .black, radius: 0.5, x: 0, y: -1.8)
        .shadow(color: .black.opacity(0.85), radius: 4)
    }

    private var styledTargetText: Text {
        let yellow = Self.subtitleYellow
        return vm.targetSegments.reduce(Text("")) { acc, seg in
            acc + Text(seg.text)
                .foregroundColor(yellow)
                .fontWeight(seg.highlight ? .heavy : .semibold)
                .underline(seg.highlight, color: yellow)
        }
    }

    // Learning mode: "what was said?" recall (shown while paused). Three levels:
    // list of lines → a line's detail (replay + word chips) → AI word explanation.
    // MARK: Social — community comments panel (floating, right side)

    private var commentsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title and rating on separate lines so the title never truncates.
            VStack(alignment: .leading, spacing: 4) {
                Label(tr(L.communityComments), systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = vm.communityRating {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(String(format: "%.1f", r))
                        if vm.communityVotes > 0 {
                            Text("· \(vm.communityVotes)").foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .font(.callout.weight(.semibold))
                }
            }

            // Write a comment — at the top so it's the first focusable element.
            if vm.canComment {
                Button { vm.openCompose() } label: {
                    Label(tr(L.traktWriteComment), systemImage: "square.and.pencil")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .focused($writeButtonFocus)
            }

            if vm.commentsLoading {
                VStack(spacing: 12) { ProgressView(); Text(tr(L.communityLoading)) }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.comments.isEmpty {
                Text(tr(L.communityNoComments))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.comments) { commentRow($0) }
                    }
                    .padding(.vertical, 2)
                }
            }

            Text(tr(L.communityHint))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(28)
        .frame(width: 660)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.93))
        .ignoresSafeArea()
    }

    // Compose a comment — compact modal (TV + iPhone continuity keyboard).
    private var commentCompose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr(L.traktWriteComment))
                .font(.headline)
            // Simple single-line field; focusing it triggers tvOS continuity so
            // you can type from a nearby iPhone.
            TextField(tr(L.traktCommentPlaceholder), text: $vm.commentDraft)
                .focused($commentComposeFocus)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            Label(tr(L.traktTypeFromPhone), systemImage: "iphone")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Button { vm.commentSpoiler.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: vm.commentSpoiler ? "checkmark.square.fill" : "square")
                    Text(tr(L.traktMarkSpoiler))
                }
                .font(.callout)
            }
            .buttonStyle(SecondaryButtonStyle())
            HStack(spacing: 12) {
                Button(tr(L.cancel)) { vm.showCommentCompose = false }
                    .buttonStyle(SecondaryButtonStyle())
                Button {
                    vm.submitComment()
                } label: {
                    if vm.commentPosting { ProgressView() } else { Text(tr(L.post)) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(vm.commentPosting)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 560)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commentRow(_ c: TraktComment) -> some View {
        let hidden = c.spoiler && !vm.revealedSpoilers.contains(c.id)
        return Button {
            if hidden { vm.revealSpoiler(c.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(c.userName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentSoft)
                    if let r = c.userRating {
                        HStack(spacing: 2) { Image(systemName: "star.fill"); Text("\(r)") }
                            .font(.caption2)
                            .foregroundStyle(.yellow.opacity(0.85))
                    }
                    Spacer()
                    Text(c.lang.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white.opacity(0.6))
                    if c.likes > 0 {
                        HStack(spacing: 3) { Image(systemName: "hand.thumbsup.fill"); Text("\(c.likes)") }
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                if hidden {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                        Text(tr(L.spoilerReveal))
                    }
                    .font(.callout)
                    .foregroundStyle(.orange.opacity(0.9))
                } else {
                    Text(c.text)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(RecallRowStyle())
        .focused($commentFocus, equals: c.id)
    }

    private var learningRecall: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detail = vm.recallDetail {
                recallDetailView(detail)
            } else {
                recallListView
            }
        }
        .padding(36)
        .frame(maxWidth: 1000, maxHeight: 700, alignment: .leading)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recallListView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(tr(L.learningTellMeMore), systemImage: "character.book.closed.fill")
                    .font(.title3.weight(.bold))
                Spacer()
                Text(trf(L.learningWordsNew, vm.sessionNewWords) + "  ·  " + trf(L.learningComprehension, vm.sessionComprehension))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.recallLines.reversed()) { line in
                        Button { vm.openRecallDetail(line) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.target)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                if !line.native.isEmpty {
                                    Text(line.native)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(RecallRowStyle())
                        .focused($recallFocus, equals: line.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 440)
            Text(tr(L.learningReplayHint))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func recallDetailView(_ line: PlayerViewModel.RecallLine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(line.target)
                .font(.title3.weight(.bold))
                .foregroundStyle(Self.subtitleYellow)
                .fixedSize(horizontal: false, vertical: true)
            if !line.native.isEmpty {
                Text(line.native)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button { vm.replayRecall(line) } label: {
                    Label(tr(L.learningReplayPhrase), systemImage: "gobackward")
                }
                .buttonStyle(SecondaryButtonStyle())
                .focused($recallActionFocus)
                Button { vm.speakLearning(line.target) } label: {
                    Label(tr(L.learningListenPhrase), systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            // AI explanation of the whole line — scrollable (each paragraph is a
            // focusable row, so the user can scroll through a long answer).
            if let exp = vm.recallExplanation {
                if exp.loading {
                    HStack(spacing: 12) { ProgressView(); Text(tr(L.aiThinking)) }
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 6)
                } else if let text = exp.text {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(explanationParagraphs(text).enumerated()), id: \.offset) { _, para in
                                Button {} label: {
                                    Text(para)
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(RecallRowStyle())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 380)
                } else {
                    Text(SettingsStore.shared.aiReady ? tr(L.aiFailed) : tr(L.aiNotConfigured))
                        .font(.callout)
                        .foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
        }
    }

    /// Splits the AI answer into paragraphs/lines so a long explanation becomes a
    /// list of focusable rows (which is how tvOS scrolls arbitrary content).
    private func explanationParagraphs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func pictureModeIcon(_ mode: String) -> String {
        switch mode {
        case "sleep": "moon.fill"
        case "vivid": "sparkles"
        case "noir": "theatermasks.fill"
        default: "circle"
        }
    }

    private func pictureModeName(_ mode: String) -> String {
        switch mode {
        case "sleep": tr(L.colorModeSleep)
        case "vivid": tr(L.colorModeVivid)
        case "noir": tr(L.colorModeNoir)
        default: tr(L.colorModeNormal)
        }
    }

    private var transport: some View {
        VStack {
            // Header: large content rating + genres (left), scan speed (right).
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    if settings.playerShowPG, let contentRating = vm.media.contentRating {
                        Text(contentRating)
                            .font(.system(size: 42, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.75), lineWidth: 3)
                            )
                            .foregroundStyle(.white)
                    }
                    if settings.playerShowGenres, !vm.media.genres.isEmpty {
                        Text(vm.media.genres.split(separator: "|").prefix(3).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    // Active picture mode (only when it isn't the default).
                    if settings.videoColorMode != "normal" {
                        HStack(spacing: 7) {
                            Image(systemName: pictureModeIcon(settings.videoColorMode))
                            Text(pictureModeName(settings.videoColorMode))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    }
                }
                Spacer()

                if settings.playerShowClock || settings.playerShowDate {
                    // Clock: time on top, subtle full date below.
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .trailing, spacing: 6) {
                            if settings.playerShowClock {
                                Text(context.date, format: .dateTime.hour().minute())
                                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.95))
                            }
                            if settings.playerShowDate {
                                Text(context.date.formatted(
                                    .dateTime.weekday(.wide).day().month(.wide).year()
                                        .locale(Locale(identifier: L10nStore.shared.effective == "es" ? "es" : "en"))
                                ))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 64)
            .background(
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )

            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                // Preview bubble during seek.
                seekPreview

                // Title + metadata.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        if vm.paused {
                            Image(systemName: "pause.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                        }
                        Text(displayTitle)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        // Community (Trakt) — minimalist icon (same style as the detail
                        // like/dislike), pushed fully to the right of the title row.
                        if vm.commentsAvailable, vm.transportVisible {
                            Spacer(minLength: 16)
                            Button { vm.openComments() } label: {
                                Image(systemName: "bubble.left.and.bubble.right")
                            }
                            .buttonStyle(IconCircleButtonStyle(active: false))
                            .focused($communityFocus)
                            .onMoveCommand { dir in
                                switch dir {
                                case .down: surfaceFocused = true
                                case .up:
                                    if vm.media.isEpisode, vm.prevEpisodeRef != nil || vm.nextEpisodeRef != nil {
                                        navFocus = vm.nextEpisodeRef != nil ? .next : .prev
                                    }
                                default: surfaceFocused = true
                                }
                            }
                        }
                    }

                    HStack(spacing: 0) {
                        if settings.playerShowRating, let rating = vm.media.rating {
                            metaItem {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .foregroundStyle(.yellow.opacity(0.9))
                            }
                        }
                        if settings.playerShowYear, let year = vm.media.year {
                            metaItem { Text(String(year)) }
                        }
                        if settings.playerShowQuality, let quality = qualityLabel {
                            metaItem { metaBadge(quality) }
                        }
                        if settings.playerShowAudio, let audio = currentAudioName {
                            metaItem {
                                Label(audio, systemImage: "speaker.wave.2.fill")
                            }
                        }
                        if settings.playerShowSubtitle, let sub = currentSubtitleName {
                            metaItem {
                                Label(sub, systemImage: "captions.bubble.fill")
                            }
                        }
                        // Torrent: live streaming stats, unobtrusive.
                        if vm.isTorrent, let s = vm.torrentStats {
                            metaItem {
                                Label(String(format: "%.0f Mbps", s.downloadMbps), systemImage: "arrow.down.circle")
                            }
                            metaItem {
                                Label("\(s.connectedSeeders)", systemImage: "person.2.fill")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                }

                // Scrubber.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.3))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(geo.size.width * progressFraction, 6))
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .offset(x: max(geo.size.width * progressFraction - 8, 0))
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    }
                }
                .frame(height: 8)

                // Times, with the series prev ← progress → next line centered between them.
                HStack {
                    Text(format(seconds: vm.timePos))
                    Spacer(minLength: 16)
                    if vm.media.isEpisode, vm.seriesTotal > 0 {
                        seriesProgressIndicator
                        Spacer(minLength: 16)
                    }
                    Text("-" + format(seconds: max(vm.duration - vm.timePos, 0)))
                }
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.95))
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 64)
            .padding(.top, 130)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.8)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
    }

    // MARK: Transport metadata

    private func metaItem(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.trailing, 22)
    }

    private func metaBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
            )
            .foregroundStyle(.white.opacity(0.85))
    }

    private var qualityLabel: String? {
        var parts: [String] = []
        if let resolution = vm.media.resolution {
            parts.append(resolution.lowercased() == "4k" ? "4K" : resolution.uppercased())
        }
        if let hdr = vm.media.hdrLabel {
            parts.append(hdr)
        } else if vm.isHDR {
            parts.append("HDR")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var currentAudioName: String? {
        vm.audioTracks.first(where: \.selected)?.displayName
    }

    private var currentSubtitleName: String? {
        vm.subTracks.first(where: \.selected)?.displayName ?? tr(L.subtitlesOff)
    }

    @ViewBuilder
    private var seekPreview: some View {
        if let target = vm.seekTarget {
            GeometryReader { geo in
                let fraction = vm.duration > 0 ? CGFloat(min(max(target / vm.duration, 0), 1)) : 0
                let width: CGFloat = 300
                let x = min(max(geo.size.width * fraction - width / 2, 0), geo.size.width - width)

                VStack(spacing: 10) {
                    if let url = vm.previewThumbnailURL(at: target) {
                        CachedAsyncImage(url: url)
                            .frame(width: width, height: 168)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                            )
                            .shadow(color: .black.opacity(0.6), radius: 18, y: 8)
                    }
                    Text(format(seconds: target))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                }
                .frame(width: width)
                .offset(x: x)
            }
            .frame(height: vm.previewThumbnailURL(at: target) != nil ? 220 : 50)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        }
    }

    private var displayTitle: String {
        if let subtitle = vm.media.subtitle {
            return "\(vm.media.title)  ·  \(subtitle)"
        }
        return vm.media.title
    }

    private var progressFraction: CGFloat {
        guard vm.duration > 0 else { return 0 }
        return CGFloat(min(max(vm.timePos / vm.duration, 0), 1))
    }

    private func format(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Top panel (Info / Audio / Subtitles)

private struct PlayerPanel: View {
    @ObservedObject var vm: PlayerViewModel
    @FocusState private var focusedTab: PlayerViewModel.PanelTab?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 34) {
                // Centered tabs.
                HStack(spacing: 16) {
                    tabButton(.info, label: tr(L.info))
                    if vm.media.isEpisode {
                        tabButton(.episodes, label: tr(L.episodesTab))
                    }
                    tabButton(.cast, label: tr(L.castTitle))
                    tabButton(.audio, label: tr(L.audio))
                    tabButton(.subtitles, label: tr(L.subtitles))
                    if vm.isTorrent {
                        tabButton(.source, label: tr(L.sourceTab))
                    }
                    tabButton(.settings, label: tr(L.playerSettings))
                }

                // Tab content, centered as a block.
                Group {
                    switch vm.panelTab {
                    case .info: infoTab
                    case .episodes: episodesTab
                    case .cast: castTab
                    case .audio: audioTab
                    case .subtitles: subtitlesTab
                    case .source: sourceTab
                    case .settings: settingsTab
                    }
                }
                .frame(maxWidth: 1100)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 90)
            .padding(.top, 60)
            .padding(.bottom, 44)
            .background(.regularMaterial)
            .environment(\.colorScheme, .dark)

            Spacer()
        }
        .ignoresSafeArea()
        // The back button closes the panel (captured here, where focus lives,
        // so it never bubbles up to the player's dismiss).
        .onExitCommand {
            vm.closePanel()
        }
        .onAppear {
            // Ensures focus enters the panel when it opens.
            focusedTab = vm.panelTab
        }
    }

    private func tabButton(_ tab: PlayerViewModel.PanelTab, label: String) -> some View {
        Button {
            vm.panelTab = tab
        } label: {
            Text(label)
                .font(.callout.weight(.semibold))
        }
        .buttonStyle(PanelTabStyle(selected: vm.panelTab == tab))
        .focused($focusedTab, equals: tab)
        .onChange(of: focusedTab) { _, newValue in
            // The tab activates on focus, like in the official player.
            if let newValue { vm.panelTab = newValue }
        }
    }

    // MARK: Tabs

    private var infoTab: some View {
        HStack(alignment: .top, spacing: 36) {
            if let url = vm.media.plexImageURL(path: vm.media.thumbPath, width: 300, height: 450) {
                CachedAsyncImage(url: url)
                    .frame(width: 150, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(vm.media.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                if let subtitle = vm.media.subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 14) {
                    if let year = vm.media.year { Text(String(year)) }
                    if let rating = vm.media.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if !vm.media.genres.isEmpty {
                        Text(vm.media.genres.split(separator: "|").prefix(3).joined(separator: " · "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))

                if !vm.media.summary.isEmpty {
                    Text(vm.media.summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(4)
                        .frame(maxWidth: 800, alignment: .leading)
                }

                // Current playback quality.
                HStack(spacing: 12) {
                    if let quality = playbackQuality {
                        techChip(icon: "film", quality)
                    }
                    if let size = vm.media.fileSizeGB {
                        techChip(icon: "internaldrive", String(format: "%.1f GB", size))
                    }
                    if let audio = vm.audioTracks.first(where: \.selected)?.displayName {
                        techChip(icon: "speaker.wave.3", audio)
                    }
                }
                .padding(.top, 6)

                // Chapters: horizontal picker with a thumbnail of the exact moment.
                if !vm.chapters.isEmpty {
                    Text(tr(L.chaptersLabel).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .kerning(1.1)
                        .padding(.top, 10)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 22) {
                            ForEach(vm.chapters) { chapter in
                                chapterCard(chapter)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 6)
                    }
                    .scrollClipDisabled()
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    private func chapterCard(_ chapter: MPVClient.MPVChapter) -> some View {
        let isCurrent = vm.isCurrentChapter(chapter)
        return Button {
            vm.seekToChapter(chapter)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ChapterThumbnail(
                    videoURL: vm.media.url,
                    seconds: chapter.time,
                    number: chapter.index + 1,
                    bifURL: vm.previewThumbnailURL(at: chapter.time),
                    backdropURL: vm.media.plexImageURL(path: vm.media.artPath ?? vm.media.thumbPath, width: 420, height: 236)
                )
                .frame(width: 210, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 3)
                )
                Text(chapter.title?.isEmpty == false ? chapter.title! : "\(tr(L.chapterWord)) \(chapter.index + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.8))
                    .lineLimit(1)
                Text(formatChapterTime(chapter.time))
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? Theme.accentSoft : .white.opacity(0.45))
            }
            .frame(width: 210)
        }
        .buttonStyle(PanelCastStyle())
    }

    private struct ChapterThumbnail: View {
        let videoURL: URL
        let seconds: Double
        let number: Int
        let bifURL: URL?
        let backdropURL: URL?
        @State private var extracted: UIImage?

        var body: some View {
            ZStack {
                if let extracted {
                    // Real frame extracted from the video at that instant.
                    Image(uiImage: extracted)
                        .resizable()
                        .scaledToFill()
                } else if let bifURL {
                    // Plex preview thumbnail (if the server has it).
                    CachedAsyncImage(url: bifURL)
                } else if let backdropURL {
                    // Dimmed backdrop + chapter number.
                    CachedAsyncImage(url: backdropURL)
                        .overlay(Color.black.opacity(0.35))
                        .overlay(
                            Text("\(number)")
                                .font(.title.weight(.black))
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.6), radius: 6)
                        )
                } else {
                    Rectangle().fill(.white.opacity(0.07))
                    Image(systemName: "bookmark.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .task {
                // Tries to extract the real frame (MP4/MOV; AVFoundation doesn't support MKV).
                extracted = await VideoThumbnailer.shared.frame(url: videoURL, atSeconds: seconds)
            }
        }
    }

    private func formatChapterTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var playbackQuality: String? {
        var parts: [String] = []
        if let resolution = vm.media.resolution {
            parts.append(resolution.lowercased() == "4k" ? "4K" : resolution.uppercased())
        }
        if let codec = vm.media.videoCodec { parts.append(codec.uppercased()) }
        if let hdr = vm.media.hdrLabel {
            parts.append(hdr)
        } else if vm.isHDR {
            parts.append("HDR")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func techChip(icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.white.opacity(0.1), in: Capsule())
        .foregroundStyle(.white.opacity(0.85))
    }

    private var castTab: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 28) {
                ForEach(vm.cast) { member in
                    Button {} label: {
                        VStack(spacing: 10) {
                            CachedAsyncImage(url: member.profileURL)
                                .frame(width: 110, height: 110)
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
                        .frame(width: 150)
                    }
                    .buttonStyle(PanelCastStyle())
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
        }
        .scrollClipDisabled()
        .frame(maxHeight: 260)
    }

    private var audioTab: some View {
        trackList(vm.audioTracks, allowOff: false) { track in
            vm.selectAudio(track!)
        }
    }

    private var subtitlesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            trackList(vm.subTracks, allowOff: true) { track in
                vm.selectSubtitle(track)
            }
            // Search/download subtitles: always available (guides the user if setup is missing).
            Button {
                vm.openSubtitleSearch()
            } label: {
                Label(tr(L.downloadSubtitles), systemImage: "arrow.down.doc")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SubtitleStyleTab(vm: vm)

            // Language-learning mode (highlights new words, "what was said?" recall).
            Button {
                SettingsStore.shared.learningModeEnabled.toggle()
                vm.applyLearningMode()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "character.book.closed.fill")
                    Text(tr(L.learningModeToggle))
                    Spacer()
                    Image(systemName: SettingsStore.shared.learningModeEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(SettingsStore.shared.learningModeEnabled ? Theme.accent : .white.opacity(0.4))
                }
                .font(.callout)
            }
            .buttonStyle(SecondaryButtonStyle())

            // Diagnostics: live technical overlay.
            Button {
                vm.toggleNerdStats()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                    Text(tr(L.nerdStatsLabel))
                    Spacer()
                    Image(systemName: vm.nerdStats != nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(vm.nerdStats != nil ? Theme.accent : .white.opacity(0.4))
                }
                .font(.callout)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: Source tab (torrent: live stats + change release)

    private var currentHash: String? { TorrServerClient.hash(from: vm.media.url)?.lowercased() }

    /// Label for the source in use: quality/codec/HDR/size of the current media.
    private var currentSourceLabel: String {
        var parts: [String] = []
        if let r = vm.media.resolution { parts.append(r.lowercased() == "4k" ? "4K" : r.uppercased()) }
        if let c = vm.media.videoCodec { parts.append(c.uppercased()) }
        if let h = vm.media.hdrLabel { parts.append(h) }
        if let gb = vm.media.fileSizeGB, gb > 0 { parts.append(String(format: "%.1f GB", gb)) }
        return parts.isEmpty ? tr(L.torrentSource) : parts.joined(separator: " · ")
    }

    private var sourceTab: some View {
        VStack(alignment: .center, spacing: 22) {
            // Primary button first (right under the tabs → always focusable).
            Button {
                vm.openSourcePicker()
            } label: {
                Label(tr(L.changeSource), systemImage: "rectangle.2.swap")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(PrimaryButtonStyle())

            // Source currently in use.
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(L.nowPlayingSource).uppercased())
                    .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.45)).kerning(1.2)
                HStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                    Text(currentSourceLabel)
                        .font(.callout.weight(.bold)).foregroundStyle(.white)
                    if let provider = vm.media.sourceProvider, !provider.isEmpty {
                        Label(provider, systemImage: "globe")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accentSoft)
                    }
                    if let sub = vm.media.subtitle, !sub.isEmpty {
                        Text(sub).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: 900, alignment: .leading)
            .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))

            // Live streaming statistics.
            if let s = vm.torrentStats {
                HStack(spacing: 30) {
                    statBlock(icon: "arrow.down.circle.fill", value: String(format: "%.1f Mbps", s.downloadMbps), label: tr(L.dlSpeed))
                    statBlock(icon: "person.2.fill", value: "\(s.connectedSeeders)/\(s.activePeers)", label: tr(L.seedersPeers))
                    statBlock(icon: "internaldrive.fill", value: "\(Int(s.progress * 100))%", label: tr(L.buffered))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }

    private func statBlock(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(value, systemImage: icon)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Episodes tab (switch episodes without leaving)

    private var episodesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Season picker.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(vm.panelSeasons) { season in
                        Button {
                            vm.selectPanelSeason(season.number)
                        } label: {
                            Text("T\(season.number)")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(PanelTabStyle(selected: vm.panelSeason == season.number))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()

            // Episodes of the season.
            if let season = vm.panelSeasons.first(where: { $0.number == vm.panelSeason }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 26) {
                        ForEach(season.episodes) { episode in
                            episodeCard(episode)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
                }
                .scrollClipDisabled()
            }
        }
        .frame(maxHeight: 340)
    }

    private func episodeCard(_ episode: PlayerViewModel.PanelEpisode) -> some View {
        let isCurrent = episode.refID != nil && episode.refID == vm.media.refID
        return Button {
            if !isCurrent {
                vm.switchToEpisode(season: episode.seasonNumber, number: episode.episodeNumber)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CachedAsyncImage(url: episode.thumbURL)
                    .frame(width: 270, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 3)
                    )
                    .overlay(alignment: .bottomLeading) {
                        if isCurrent {
                            Label("", systemImage: "play.fill")
                                .font(.caption2)
                                .padding(6)
                                .background(Theme.accent, in: Circle())
                                .foregroundStyle(.white)
                                .padding(8)
                        }
                    }
                HStack(spacing: 8) {
                    Text("E\(episode.episodeNumber)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isCurrent ? Theme.accentSoft : .white.opacity(0.6))
                    Text(episode.title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .frame(width: 270, alignment: .leading)
            }
        }
        .buttonStyle(PanelCastStyle())
    }

    @MainActor
    private func panelEpisodeThumb(_ episode: Episode) -> URL? {
        guard let server = SettingsStore.shared.server(id: episode.serverID),
              let token = SettingsStore.shared.token(forServer: episode.serverID) else { return nil }
        return PlexClient.imageURL(baseURL: server.url, token: token, path: episode.thumbPath, width: 540, height: 304)
    }

    private func trackList(_ tracks: [MPVTrack], allowOff: Bool, onSelect: @escaping (MPVTrack?) -> Void) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                if allowOff {
                    trackRow(
                        label: tr(L.subtitlesOff),
                        selected: !tracks.contains(where: \.selected)
                    ) { onSelect(nil) }
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(label: trackLabel(track, index: index), selected: track.selected) {
                        onSelect(track)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: 320)
    }

    /// Readable label: language if it exists; otherwise the title; otherwise numbered
    /// ("Subtitles 2") instead of repeating the codec ("SUBRIP") — useful for torrents
    /// with embedded tracks lacking a language. For audio it keeps the codec/channels detail.
    private func trackLabel(_ track: MPVTrack, index: Int) -> String {
        if let lang = track.lang, !lang.isEmpty, lang.lowercased() != "und" {
            return track.displayName   // displayName already prefixes the readable language
        }
        if let title = track.title, !title.isEmpty { return title }
        let base = track.type == "sub" ? tr(L.subtitles) : tr(L.audio)
        var label = "\(base) \(index + 1)"
        if track.type == "audio", let codec = track.codec {
            label += " · \(codec.uppercased())"
        }
        return label
    }

    private func trackRow(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(selected ? 1 : 0)
                Text(label)
                    .lineLimit(1)
                Spacer()
            }
            .font(.callout)
        }
        .buttonStyle(PanelRowStyle())
    }
}

// MARK: - Subtitle settings tab

private struct SubtitleStyleTab: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            styleRow(tr(L.subtitleSize), options: [
                ("small", tr(L.sizeSmall)),
                ("medium", tr(L.sizeMedium)),
                ("large", tr(L.sizeLarge)),
                ("xlarge", tr(L.sizeXLarge)),
            ], current: settings.subSize) { settings.subSize = $0; vm.applySubtitleStyle() }

            styleRow(tr(L.subtitleFont), options: [
                ("default", tr(L.fontDefault)),
                ("rounded", tr(L.fontRounded)),
                ("serif", tr(L.fontSerif)),
                ("mono", tr(L.fontMono)),
            ], current: settings.subFont) { settings.subFont = $0; vm.applySubtitleStyle() }

            styleRow(tr(L.subtitleColor), options: [
                ("white", tr(L.colorWhite)),
                ("yellow", tr(L.colorYellow)),
                ("cyan", tr(L.colorCyan)),
            ], current: settings.subColor) { settings.subColor = $0; vm.applySubtitleStyle() }

            styleRow(tr(L.colorModeGroup), options: [
                ("normal", tr(L.colorModeNormal)),
                ("sleep", tr(L.colorModeSleep)),
                ("vivid", tr(L.colorModeVivid)),
                ("noir", tr(L.colorModeNoir)),
            ], current: settings.videoColorMode) { settings.videoColorMode = $0; vm.applyColorMode() }
        }
    }

    private func styleRow(
        _ title: String,
        options: [(String, String)],
        current: String,
        onPick: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 170, alignment: .leading)
            ForEach(options, id: \.0) { value, label in
                Button {
                    onPick(value)
                } label: {
                    HStack(spacing: 8) {
                        if current == value {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(label)
                    }
                    .font(.callout)
                }
                .buttonStyle(PanelTabStyle(selected: current == value))
            }
            Spacer()
        }
    }
}

// MARK: - Panel styles

private struct PanelTabStyle: ButtonStyle {
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
                .padding(.vertical, 10)
                .background(
                    focused ? AnyShapeStyle(.white) : (selected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.clear)),
                    in: Capsule()
                )
                .foregroundStyle(focused ? .black : .white.opacity(selected ? 1 : 0.6))
                .scaleEffect(focused ? 1.05 : 1.0)
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}

private struct PanelCastStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(focused ? 1.12 : 1.0)
                .opacity(focused ? 1.0 : 0.8)
                .animation(.smooth(duration: 0.2), value: focused)
        }
    }
}

private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 620, alignment: .leading)
                .background(
                    focused ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .foregroundStyle(.white.opacity(focused ? 1 : 0.75))
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}

// MARK: - Video surface (Metal)

private struct MPVVideoSurface: UIViewRepresentable {
    @ObservedObject var vm: PlayerViewModel

    func makeUIView(context: Context) -> VideoContainerView {
        let view = VideoContainerView()
        vm.attach(layer: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: VideoContainerView, context: Context) {}
}

final class VideoContainerView: UIView {
    let metalLayer = FluxMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame.isEmpty ? UIScreen.main.bounds : frame)
        backgroundColor = .black
        metalLayer.frame = bounds.isEmpty ? UIScreen.main.bounds : bounds
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.contentsScale = UIScreen.main.nativeScale
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bounds.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        if let scale = window?.screen.nativeScale {
            metalLayer.contentsScale = scale
        }
        CATransaction.commit()
    }
}

/// MoltenVK workaround: ignores 1x1 drawableSize that causes flickering.
/// https://github.com/mpv-player/mpv/pull/13651
final class FluxMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

// MARK: - Skip / next-up button style

/// Focusable row in the learning recall list: left-aligned, soft highlight when
/// focused (so the list scrolls as focus moves through it).
private struct RecallRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }
    private struct Inner: View {
        @Environment(\.isFocused) private var focused
        let configuration: ButtonStyleConfiguration
        var body: some View {
            configuration.label
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(focused ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(focused ? 0.4 : 0), lineWidth: 1))
                .scaleEffect(focused ? 1.01 : 1.0)
                .animation(.smooth(duration: 0.12), value: focused)
        }
    }
}

/// Subtle inline style for the prev/next episode names: pure white, with a soft
/// capsule highlight when focused.
private struct EpisodeNavButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(focused ? 0.22 : 0)))
                .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.55 : 0), lineWidth: 1))
                .scaleEffect(focused ? 1.06 : 1.0)
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}

private struct SkipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    Capsule().fill(focused ? Color.white : Color.black.opacity(0.6))
                )
                .overlay(
                    Capsule().strokeBorder(.white.opacity(focused ? 0 : 0.35), lineWidth: 1.5)
                )
                .foregroundColor(focused ? .black : .white)
                .scaleEffect(focused ? 1.05 : 1.0)
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}


// MARK: - Post-play

private struct PostPlayOverlay: View {
    @ObservedObject var vm: PlayerViewModel
    let onExit: () -> Void
    let onSelectSimilar: (MediaItem) -> Void

    @FocusState private var focusedThumb: Int?

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.75), location: 0),
                    .init(color: .black.opacity(0.96), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 34) {
                Spacer()

                // Header depending on the case.
                if let state = vm.postPlay {
                    VStack(alignment: .leading, spacing: 12) {
                        switch state.kind {
                        case .movieFinished, .seriesFinished:
                            Label {
                                Text("\(tr(L.youFinished)) \(Text(vm.media.title).bold())")
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .font(.title2)
                            .foregroundStyle(.white)
                        case .missingNext(let season, let episode):
                            Label {
                                Text(tr(L.missingNextTitle)).bold()
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .font(.title2)
                            .foregroundStyle(.white)
                            Text("T\(season) · E\(episode) \(tr(L.notInLibrary))")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    // Did you like it?
                    HStack(spacing: 20) {
                        Text(tr(L.didYouLike))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                        // Same minimalist icon design as the detail screen's secondary actions.
                        Button {
                            vm.ratePostPlay(true)
                        } label: {
                            Image(systemName: vm.postPlayLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }
                        .buttonStyle(IconCircleButtonStyle(active: vm.postPlayLiked == true))
                        .focused($focusedThumb, equals: 0)

                        Button {
                            vm.ratePostPlay(false)
                        } label: {
                            Image(systemName: vm.postPlayLiked == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        }
                        .buttonStyle(IconCircleButtonStyle(active: vm.postPlayLiked == false))

                        Button {
                            onExit()
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(IconCircleButtonStyle(active: false))
                    }

                    // More like this — or personal picks when no similar titles exist.
                    if !state.similar.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr(state.similarIsPersonal ? L.forYou : L.similarTitle))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 30) {
                                    ForEach(state.similar) { similarItem in
                                        Button {
                                            onSelectSimilar(similarItem)
                                        } label: {
                                            CachedAsyncImage(url: similarItem.posterURL(width: 360, height: 540))
                                                .frame(width: 180, height: 270)
                                        }
                                        .buttonStyle(MediaCardStyle(cornerRadius: 12))
                                    }
                                }
                                .padding(.vertical, 28)
                                .padding(.horizontal, 8)
                            }
                            .scrollClipDisabled()
                        }
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
        .onAppear { focusedThumb = 0 }
    }
}

// MARK: - Playback error

private struct PlaybackErrorOverlay: View {
    var canChangeSource: Bool = false
    var detail: String? = nil
    let onRetry: () -> Void
    var onChangeSource: () -> Void = {}
    let onExit: () -> Void
    @FocusState private var retryFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 26) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.orange)
                Text(tr(L.connectionLost))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                // Concrete reason (mpv error / log line / timeout): lets the user
                // diagnose a misconfigured source right on the TV.
                if let detail, !detail.isEmpty {
                    VStack(spacing: 8) {
                        Text(tr(L.errorDetailLabel).uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .kerning(1.4)
                        Text(detail)
                            .font(.callout.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 900)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack(spacing: 24) {
                    Button {
                        onRetry()
                    } label: {
                        Label(tr(L.retry), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .focused($retryFocused)

                    // Torrent: allow choosing another source so the user is never stuck.
                    if canChangeSource {
                        Button {
                            onChangeSource()
                        } label: {
                            Label(tr(L.changeSource), systemImage: "rectangle.2.swap")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    Button(tr(L.exitLabel)) { onExit() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .focusSection()
        .onAppear { retryFocused = true }
    }
}

// MARK: - Subtitle search modal (OpenSubtitles)

private struct SubtitleSearchOverlay: View {
    @ObservedObject var vm: PlayerViewModel
    @FocusState private var focusedLang: String?

    // Languages supported by OpenSubtitles (most common first).
    private let languages: [(code: String, label: String)] = [
        ("es", "Español"), ("en", "English"), ("pt-br", "Português (BR)"), ("pt-pt", "Português"),
        ("fr", "Français"), ("it", "Italiano"), ("de", "Deutsch"), ("ja", "日本語"),
        ("ko", "한국어"), ("zh-cn", "中文 (简)"), ("zh-tw", "中文 (繁)"), ("ru", "Русский"),
        ("ar", "العربية"), ("hi", "हिन्दी"), ("nl", "Nederlands"), ("pl", "Polski"),
        ("tr", "Türkçe"), ("sv", "Svenska"), ("no", "Norsk"), ("da", "Dansk"),
        ("fi", "Suomi"), ("cs", "Čeština"), ("el", "Ελληνικά"), ("he", "עברית"),
        ("hu", "Magyar"), ("ro", "Română"), ("uk", "Українська"), ("th", "ไทย"),
        ("id", "Indonesia"), ("vi", "Tiếng Việt"), ("bg", "Български"), ("hr", "Hrvatski"),
        ("sr", "Српски"), ("sk", "Slovenčina"), ("sl", "Slovenščina"), ("ca", "Català"),
    ]

    private let langColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark).ignoresSafeArea()
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(tr(L.downloadSubtitles))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                // Language picker — scrollable grid with all languages.
                Text(tr(L.subtitleLanguage).uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(1.2)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: langColumns, spacing: 12) {
                        ForEach(languages, id: \.code) { lang in
                            Button {
                                vm.osLanguage = lang.code
                                vm.searchOpenSubtitles()
                            } label: {
                                Text(lang.label)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PanelTabStyle(selected: vm.osLanguage == lang.code))
                            .focused($focusedLang, equals: lang.code)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 200)
                .scrollClipDisabled()

                // Results.
                if vm.osSearching {
                    HStack(spacing: 12) { ProgressView(); Text(tr(L.searchingSubtitles)).foregroundStyle(.white.opacity(0.6)) }
                } else if let err = vm.osError {
                    Text(err).font(.callout).foregroundStyle(.orange)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(vm.osResults) { result in
                                Button {
                                    vm.downloadOpenSubtitle(result)
                                } label: {
                                    HStack(spacing: 14) {
                                        // Match probability.
                                        Text("\(result.matchPercent)%")
                                            .font(.callout.weight(.bold).monospacedDigit())
                                            .foregroundStyle(matchColor(result.matchPercent))
                                            .frame(width: 64, alignment: .leading)
                                        if result.hashMatch {
                                            Label(tr(L.exactMatch), systemImage: "checkmark.seal.fill")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.green)
                                        }
                                        Text(result.release.isEmpty ? result.language.uppercased() : result.release)
                                            .font(.callout)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(result.language.uppercased())
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(.white.opacity(0.12), in: Capsule())
                                        if vm.osDownloadingID == result.fileID {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "arrow.down.circle")
                                        }
                                    }
                                    .frame(maxWidth: 1000, alignment: .leading)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(PanelRowStyle())
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                }

                Button(tr(L.close)) { vm.showSubtitleSearch = false }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(60)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .focusSection()
        .onExitCommand { vm.showSubtitleSearch = false }
    }

    private func matchColor(_ p: Int) -> Color {
        if p >= 90 { return .green }
        if p >= 60 { return Theme.accentSoft }
        return .orange
    }
}

// MARK: - Torrent loading overlay

/// Detailed status while a torrent preloads: current step + speed, peers, and %.
/// "Stats for nerds": compact monospaced diagnostics block.
private struct NerdStatsOverlay: View {
    let stats: MPVClient.NerdStats
    let torrent: TorrServerClient.Stats?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            line(tr(L.nsResolution), resolutionText)
            line(tr(L.nsVideo), videoText)
            if stats.containerFps > 0 || stats.fps > 0 { line(tr(L.nsFps), fpsText) }
            if stats.videoBitrateMbps > 0 {
                line(tr(L.nsQuality), String(format: "%.1f Mbps", stats.videoBitrateMbps))
            }
            line(tr(L.nsDecoding), decodeText)
            if !stats.audioCodec.isEmpty { line(tr(L.nsAudioSource), friendlyAudioCodec(stats.audioCodec)) }
            if stats.audioOutChannels > 0 { line(tr(L.nsAudioOutput), audioOutText) }
            if !stats.ao.isEmpty { line(tr(L.nsAudioEngine), friendlyAO(stats.ao)) }
            line(tr(L.nsDroppedFrames), "\(stats.droppedFrames)")
            line(tr(L.nsBuffer), String(format: "%.0fs · %.1f Mbps", stats.cacheSeconds, stats.cacheSpeedMbps))
            if let torrent {
                line(tr(L.nsTorrent), String(format: "%.1f Mbps · %d/%d peers · %d%%",
                                       torrent.downloadMbps, torrent.connectedSeeders,
                                       torrent.activePeers, Int(torrent.progress * 100)))
            }
        }
        .padding(16)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Friendly value formatting

    private var resolutionText: String {
        let q = qualityLabel(stats.height)
        return q.isEmpty ? stats.resolution : "\(stats.resolution) · \(q)"
    }

    private func qualityLabel(_ h: Int) -> String {
        switch h {
        case 2000...: "4K"
        case 1080..<2000: "1080p"
        case 700..<1080: "720p"
        case 1..<700: "480p"
        default: ""
        }
    }

    private var videoText: String {
        var s = friendlyVideoCodec(stats.videoCodec)
        if stats.isHDR { s += s.isEmpty ? "HDR" : " · HDR" }
        return s.isEmpty ? "—" : s
    }

    /// File frame rate first (the relevant one for judder); the actually-rendered
    /// rate is shown only when it differs noticeably.
    private var fpsText: String {
        let c = stats.containerFps, r = stats.fps
        if c > 0 {
            var s = String(format: "%.2f", c)
            if r > 0, abs(r - c) > 0.3 { s += " (\(tr(L.nsScreenFps)) " + String(format: "%.2f", r) + ")" }
            return s
        }
        return r > 0 ? String(format: "%.2f", r) : "—"
    }

    private var decodeText: String {
        stats.hwdec.isEmpty || stats.hwdec == "no" ? tr(L.nsDecodeSoftware) : tr(L.nsDecodeHardware)
    }

    private var audioOutText: String {
        var parts: [String] = []
        parts.append(stats.audioOutLayout.isEmpty ? "\(stats.audioOutChannels) \(tr(L.nsChannels))" : stats.audioOutLayout)
        if stats.audioOutSampleRate > 0 { parts.append("\(stats.audioOutSampleRate / 1000) kHz") }
        if !stats.audioOutFormat.isEmpty { parts.append(stats.audioOutFormat) }
        return parts.joined(separator: " · ")
    }

    private func friendlyVideoCodec(_ c: String) -> String {
        let v = c.lowercased()
        if v.contains("hevc") || v.contains("h265") || v.contains("265") { return "HEVC (H.265)" }
        if v.contains("av1") { return "AV1" }
        if v.contains("h264") || v.contains("avc") || v.contains("264") { return "H.264" }
        if v.contains("vp9") { return "VP9" }
        if v.contains("mpeg2") { return "MPEG-2" }
        return c.isEmpty ? "" : c.uppercased()
    }

    private func friendlyAudioCodec(_ c: String) -> String {
        switch c.uppercased() {
        case let x where x.contains("EAC3") || x.contains("E-AC-3"): "Dolby Digital+ (E-AC3)"
        case let x where x.contains("AC3") || x.contains("AC-3"): "Dolby Digital (AC-3)"
        case let x where x.contains("TRUEHD"): "Dolby TrueHD"
        case let x where x.contains("DTS"): "DTS"
        case let x where x.contains("AAC"): "AAC"
        case let x where x.contains("FLAC"): "FLAC"
        case let x where x.contains("OPUS"): "Opus"
        case let x where x.contains("MP3"): "MP3"
        default: c
        }
    }

    private func friendlyAO(_ ao: String) -> String {
        switch ao.lowercased() {
        case "avfoundation": "Apple AVFoundation"
        case "audiounit": "Apple AudioUnit"
        default: ao
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(Theme.accentSoft)
                .frame(width: 220, alignment: .leading)
            Text(value)
                .foregroundStyle(.white.opacity(0.9))
        }
        .font(.system(size: 17, design: .monospaced))
    }
}

private struct TorrentLoadingOverlay: View {
    let stats: TorrServerClient.Stats?
    let title: String
    /// Auto-failover feedback: "Source failed — trying X…".
    var failoverNotice: String? = nil

    private var phase: String {
        guard let stats else { return tr(L.torrentConnecting) }
        if stats.activePeers == 0 && stats.connectedSeeders == 0 { return tr(L.torrentFindingPeers) }
        if stats.progress >= 0.99 { return tr(L.torrentReady) }
        return tr(L.torrentBuffering)
    }

    var body: some View {
        VStack(spacing: 22) {
            ProgressView()
                .scaleEffect(1.8)
                .tint(.white)

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(phase)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.accentSoft)

            if let failoverNotice {
                Label(failoverNotice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 560)
                    .multilineTextAlignment(.center)
            }

            if let stats {
                // Preload bar.
                if stats.progress > 0 {
                    ProgressView(value: stats.progress)
                        .tint(Theme.accent)
                        .frame(width: 380)
                }
                HStack(spacing: 28) {
                    statItem(icon: "arrow.down.circle.fill", text: String(format: "%.1f Mbps", stats.downloadMbps))
                    statItem(icon: "person.2.fill", text: "\(stats.connectedSeeders)/\(stats.activePeers) \(tr(L.torrentPeers))")
                    if stats.progress > 0 {
                        statItem(icon: "internaldrive.fill", text: "\(Int(stats.progress * 100))%")
                    }
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(40)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statItem(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
    }
}
