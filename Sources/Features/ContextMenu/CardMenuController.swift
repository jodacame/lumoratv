import SwiftUI

/// Card context menu (long press). Presented at the root level (see `MainView`)
/// as a blurred fullscreen modal — poster on the left, full title + metadata on
/// top, contextual actions on the right. Replaces the native `.contextMenu`,
/// which left focused cards stuck in their expanded state on tvOS.
@MainActor
final class CardMenuController: ObservableObject {
    static let shared = CardMenuController()

    struct Target {
        let item: MediaItem
        let inContinue: Bool
        let inMyList: Bool
        let hasProgress: Bool
        let isWatched: Bool
        var isStoppableShow: Bool { item.type == "show" && (inContinue || isWatched) }
    }

    @Published var target: Target?
    @Published var playable: PlayableMedia?
    @Published var detailItem: MediaItem?
    @Published var resolving = false

    /// After a long press, suppresses the "select" (release click) that would open the detail.
    private(set) var suppressSelectUntil: Date = .distantPast
    func markLongPress() { suppressSelectUntil = Date().addingTimeInterval(1.0) }
    var selectSuppressed: Bool { Date() < suppressSelectUntil }

    private init() {}

    func present(item: MediaItem, inContinue: Bool) {
        Task {
            let userID = UserContext.currentUserID
            let states = await WatchStore.states(userID: userID)
            let inList = await MyListStore.contains(userID: userID, mergeKey: item.mergeKey)

            let hasProgress: Bool
            if item.type == "movie" {
                hasProgress = (states[item.watchKey]?.viewOffsetMs ?? 0) > 0
            } else {
                let prefix = "ep:\(item.mergeKey):"
                hasProgress = states.values.contains { $0.itemID.hasPrefix(prefix) && $0.viewOffsetMs > 0 }
            }

            let isWatched: Bool
            if item.type == "movie" {
                isWatched = (states[item.watchKey]?.viewCount ?? 0) > 0
            } else {
                let prefix = "ep:\(item.mergeKey):"
                isWatched = states.values.contains { $0.itemID.hasPrefix(prefix) && $0.viewCount > 0 }
            }

            target = Target(
                item: item,
                inContinue: inContinue || hasProgress,
                inMyList: inList,
                hasProgress: hasProgress,
                isWatched: isWatched
            )
        }
    }

    func close() {
        target = nil
        resolving = false
    }

    // MARK: Actions

    func play() {
        guard let item = target?.item, !resolving else { return }
        resolving = true
        Task {
            defer { resolving = false }
            // Parental second shield: never play content above the configured rating.
            guard await ParentalStore.shared.allowsPlayback(item) else {
                ToastCenter.shared.show(tr(L.parentalBlocked), icon: "lock.shield")
                close()
                return
            }
            if let versions = try? await PlexPlayback.resolveVersions(item: item),
               let best = versions.first {
                close()
                playable = best.media
            } else {
                // No direct playback possible: open the detail.
                openInfo()
            }
        }
    }

    func openInfo() {
        let item = target?.item
        close()
        detailItem = item
    }

    func toggleMyList() {
        guard let item = target?.item else { return }
        Task {
            await MyListStore.toggle(userID: UserContext.currentUserID, mergeKey: item.mergeKey)
            close()
        }
    }

    func removeFromContinue() {
        guard let item = target?.item else { return }
        Task {
            await WatchStore.clearProgress(userID: UserContext.currentUserID, item: item)
            close()
        }
    }

    func toggleWatched() {
        guard let target else { return }
        Task {
            await WatchStore.setWatched(!target.isWatched, userID: UserContext.currentUserID, item: target.item)
            close()
        }
    }

    /// Stops watching a show: removes it from Continue Watching and stops recommending it.
    func stopWatchingShow() {
        guard let item = target?.item else { return }
        Task {
            let userID = UserContext.currentUserID
            StoppedStore.stop(userID: userID, mergeKey: item.mergeKey)
            await WatchStore.clearProgress(userID: userID, item: item)
            close()
        }
    }
}

// MARK: - Overlay

struct CardMenuOverlay: View {
    let target: CardMenuController.Target
    @ObservedObject var controller: CardMenuController
    @FocusState private var focusedAction: Int?

    private var item: MediaItem { target.item }

    var body: some View {
        ZStack {
            // Full blurred background so the menu reads well over any content.
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .ignoresSafeArea()
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                // Full title + metadata, across the top.
                header

                // Synopsis across the full width, slightly smaller but TV-legible.
                if !item.displaySummary.isEmpty {
                    Text(item.displaySummary)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(4)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 50) {
                    // Poster — TMDB poster, then TMDB backdrop (titles without a
                    // localized poster), then a text card. Never the local library.
                    CachedAsyncImage(url: item.posterURL(width: 400, height: 600)
                                        ?? item.artURL(width: 600, height: 360),
                                     fallbackTitle: item.displayTitle)
                        .frame(width: 240, height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.6), radius: 26, y: 14)

                    // Contextual actions.
                    actions
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 1160, alignment: .leading)
            .padding(70)
        }
        .focusSection()
        .onExitCommand { controller.close() }
        .onAppear { focusedAction = 0 }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.displayTitle)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                ForEach(metaChips, id: \.self) { chip in
                    Text(chip)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }

    /// Year · ⭐ rating · runtime/type · top genres — only what's available.
    private var metaChips: [String] {
        var chips: [String] = []
        if let year = item.year { chips.append(String(year)) }
        if let r = item.audienceRating, r > 0 {
            chips.append("★ " + String(format: "%.1f", r))
        }
        if item.type == "movie", let ms = item.durationMs, ms > 0 {
            chips.append("\(ms / 60000) min")
        } else if item.type == "show" {
            chips.append(tr(L.tabShows))
        }
        let genres = item.genres.split(separator: "|").prefix(3).map(String.init)
        if !genres.isEmpty { chips.append(genres.joined(separator: " · ")) }
        return chips
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            menuButton(0, icon: "play.fill", label: tr(L.play)) {
                controller.play()
            }
            menuButton(1, icon: "info.circle", label: tr(L.viewInfo)) {
                controller.openInfo()
            }
            menuButton(
                2,
                icon: target.inMyList ? "minus.circle" : "plus.circle",
                label: target.inMyList ? tr(L.removeFromMyList) : tr(L.addToMyList)
            ) {
                controller.toggleMyList()
            }
            if target.hasProgress {
                menuButton(3, icon: "xmark.circle", label: tr(L.removeFromContinue)) {
                    controller.removeFromContinue()
                }
            }
            if item.type == "movie" {
                menuButton(
                    4,
                    icon: target.isWatched ? "eye.slash" : "checkmark.circle",
                    label: target.isWatched ? tr(L.markUnwatched) : tr(L.markWatched)
                ) {
                    controller.toggleWatched()
                }
            }
            if target.isStoppableShow {
                menuButton(6, icon: "stop.circle", label: tr(L.stopWatchingShow)) {
                    controller.stopWatchingShow()
                }
            }
        }
    }

    private func menuButton(_ index: Int, icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.callout)
                    .frame(width: 34)
                Text(label)
                    .font(.callout)
                Spacer()
                if index == 0 && controller.resolving {
                    ProgressView()
                }
            }
        }
        .buttonStyle(MenuRowStyle())
        .focused($focusedAction, equals: index)
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .padding(.horizontal, 26)
                .padding(.vertical, 15)
                .frame(width: 600, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(focused ? Color.white : Color.white.opacity(0.08))
                )
                .foregroundColor(focused ? .black : .white.opacity(0.85))
                .scaleEffect(focused ? 1.02 : 1.0)
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}

// MARK: - Gesture

extension View {
    /// Long press on a card → blurred context menu. Replaces the previous native
    /// `.contextMenu`; kept identical across the whole app (Home, grids, search…).
    func cardLongPressMenu(item: MediaItem, inContinue: Bool = false) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                Task { @MainActor in
                    CardMenuController.shared.markLongPress()
                    CardMenuController.shared.present(item: item, inContinue: inContinue)
                }
            }
        )
    }
}
