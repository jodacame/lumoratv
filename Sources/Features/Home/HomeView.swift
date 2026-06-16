import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var syncStatus = SyncStatus.shared
    @FocusState private var focusedID: String?
    @State private var selectedItem: MediaItem?
    @State private var discoverSelection: DiscoverItem?
    @State private var categorySelection: DiscoverCategory?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HeroBackground(item: vm.heroItem, showsBackdrop: vm.heroBackdropVisible)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    // The hero info is part of the scroll, with a FIXED reserved height.
                    HeroInfo(item: vm.heroItem)
                        .frame(height: 440, alignment: .bottomLeading)

                    // Below the carousel we relocate "For you". ("My list" now
                    // renders as the very last row.)
                    let relocate = !vm.categories.isEmpty && vm.discoverRows.contains { $0.id == "pshows" }
                    let relocatedIDs: Set<String> = relocate ? ["foryou"] : []
                    // Insert the TMDB board AFTER the top personal rows (New Episodes +
                    // Continue Watching) so they stay near the top and aren't buried by
                    // the board. Falls back to the first row when none are present.
                    let boardAnchor = vm.shelves.lastIndex { ["newepisodes", "continue"].contains($0.id) } ?? 0
                    ForEach(Array(vm.shelves.enumerated()), id: \.element.id) { index, shelf in
                        if !relocatedIDs.contains(shelf.id) {
                            ShelfView(shelf: shelf, focusedID: $focusedID) { item in
                                guard !CardMenuController.shared.selectSuppressed else { return }
                                selectedItem = item
                            }
                        }
                        // TMDB catalog board after the top personal rows, prominently visible.
                        if index == boardAnchor {
                            ForEach(vm.discoverRows) { row in
                                // Category carousel + "For you" + "My list" before "Popular shows".
                                if row.id == "pshows", !vm.categories.isEmpty {
                                    CategoryCarousel(categories: vm.categories) { categorySelection = $0 }
                                    if let forYou = vm.shelves.first(where: { $0.id == "foryou" }) {
                                        ShelfView(shelf: forYou, focusedID: $focusedID) { item in
                                            guard !CardMenuController.shared.selectSuppressed else { return }
                                            selectedItem = item
                                        }
                                    }
                                }
                                DiscoverShelfView(row: row, localIDs: vm.localTmdbIDs, localByTmdb: vm.localByTmdb) { item in
                                    guard !CardMenuController.shared.selectSuppressed else { return }
                                    discoverSelection = item
                                }
                            }
                        }
                    }

                    // If there are no personal rows, the TMDB board is shown anyway.
                    if vm.shelves.isEmpty {
                        ForEach(vm.discoverRows) { row in
                            DiscoverShelfView(row: row, localIDs: vm.localTmdbIDs) { item in
                                guard !CardMenuController.shared.selectSuppressed else { return }
                                discoverSelection = item
                            }
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()

            // Loading indicator while there's nothing to show yet (parental cert
            // lookups can make the first load take a moment).
            if vm.loadingDiscovery && vm.shelves.isEmpty && vm.discoverRows.isEmpty {
                VStack(spacing: 18) {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text(tr(L.homeLoading))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .onChange(of: focusedID) { _, newValue in
            vm.focusChanged(to: newValue)
        }
        .task { await vm.load() }
        .onChange(of: syncStatus.generation) { _, _ in
            Task { await vm.load() }
        }
        // Enabling/disabling Streaming Mode refreshes the Home (shows or hides remote content).
        .onChange(of: settings.streamingModeEnabled) { _, _ in
            Task { await vm.load() }
        }
        .fullScreenCover(item: $selectedItem) { item in
            DetailView(item: item)
        }
        .fullScreenCover(item: $discoverSelection) { item in
            DiscoverRouter(item: item)
        }
        .fullScreenCover(item: $categorySelection) { category in
            CatalogBrowseView(kind: .movie, title: category.name, genre: category.id, asCover: true)
        }
    }
}

// MARK: - Category carousel

/// Premium category carousel: name centered over a related image with a
/// gradient. Each card opens the catalog view filtered by that genre.
private struct CategoryCarousel: View {
    let categories: [DiscoverCategory]
    let onSelect: (DiscoverCategory) -> Void

    @FocusState private var focusedID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(L.categoriesTitle))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 80)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 28) {
                        ForEach(categories) { category in
                            Button { onSelect(category) } label: {
                                CategoryCard(category: category)
                            }
                            .buttonStyle(MediaCardStyle(cornerRadius: 18))
                            .id(category.id)
                            .focused($focusedID, equals: category.id)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
                .onChange(of: focusedID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
        .focusSection()
    }
}

private struct CategoryCard: View {
    let category: DiscoverCategory

    var body: some View {
        ZStack {
            CachedAsyncImage(url: category.backdropURL)
                .frame(width: 360, height: 200)
            // Gradient for legibility + brand tint.
            LinearGradient(
                colors: [.black.opacity(0.25), .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            LinearGradient(
                colors: [Theme.accent.opacity(0.35), .clear],
                startPoint: .bottomLeading, endPoint: .topTrailing
            )
            Text(category.name)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(width: 360, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Routes a TMDB item to the SAME detail as the library: uses the local copy if there
/// is one; otherwise, materializes a virtual MediaItem. The source is resolved on playback.
struct DiscoverRouter: View {
    let item: DiscoverItem
    @State private var resolved: MediaItem?
    @State private var checked = false

    var body: some View {
        Group {
            if let resolved {
                DetailView(item: resolved)
            } else if checked {
                DetailView(item: MediaItem.virtualStub(from: item))
            } else {
                ZStack { Theme.background; ProgressView() }
            }
        }
        .task {
            resolved = await DiscoverPlayback.libraryItem(tmdbID: item.tmdbID, isShow: item.isShow)
            checked = true
        }
    }
}

// MARK: - TMDB catalog row

private struct DiscoverShelfView: View {
    let row: DiscoverRow
    var localIDs: Set<Int> = []
    var localByTmdb: [Int: MediaItem] = [:]
    let onSelect: (DiscoverItem) -> Void

    @FocusState private var focusedKey: String?

    private enum RowStyle { case top10, hero, theater, upcoming, poster, posterLarge }
    private var style: RowStyle {
        switch row.id {
        case "top10": return .top10            // Top 10 → giant numerals
        case "tmovies": return .hero           // trending movies → striking
        case "intheaters": return .theater     // in theaters → custom design
        case "upcoming": return .upcoming       // coming soon → custom design
        default: return row.id.utf8.reduce(0) { $0 &+ Int($1) } % 2 == 0 ? .posterLarge : .poster
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 80)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: style == .top10 ? 56 : (style == .hero ? 28 : 32)) {
                        ForEach(Array(row.items.enumerated()), id: \.element.id) { index, item in
                            let key = "\(row.id)|\(item.id)"
                            Button { onSelect(item) } label: { card(item, rank: index + 1) }
                                .buttonStyle(MediaCardStyle(cornerRadius: style == .hero ? 18 : 14,
                                                            focusedOverride: focusedKey == key))
                                .id(key)
                                .focused($focusedKey, equals: key)
                                .cardLongPressMenu(item: localByTmdb[item.tmdbID] ?? MediaItem.virtualStub(from: item))
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
                // Auto-scroll: keeps the focused card centered.
                .onChange(of: focusedKey) { _, newValue in
                    guard let newValue, newValue.hasPrefix("\(row.id)|") else { return }
                    withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private func card(_ item: DiscoverItem, rank: Int) -> some View {
        let isLocal = localIDs.contains(item.tmdbID)
        switch style {
        case .top10:
            Top10Card(item: item, rank: rank, isLocal: isLocal)
        case .hero:
            HeroBackdropCard(item: item, isLocal: isLocal)
        case .theater:
            BadgePosterCard(item: item, badge: tr(L.inTheatersNow), icon: "popcorn.fill", tint: .orange, dateText: nil, isLocal: isLocal)
        case .upcoming:
            BadgePosterCard(item: item, badge: tr(L.upcoming), icon: "calendar", tint: Theme.accent, dateText: shortDate(item.releaseDate), isLocal: isLocal)
        case .poster:
            ExpandingPosterLabel(media: MediaItem.virtualStub(from: item), baseWidth: 200, height: 300, isLocal: isLocal)
        case .posterLarge:
            ExpandingPosterLabel(media: MediaItem.virtualStub(from: item), baseWidth: 250, height: 375, isLocal: isLocal)
        }
    }

    private func shortDate(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let inF = DateFormatter()
        inF.calendar = Calendar(identifier: .gregorian)
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        guard let date = inF.date(from: iso) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: L10nStore.shared.effective == "es" ? "es" : "en")
        out.dateFormat = "d MMM yyyy"
        return out.string(from: date)
    }
}

/// Netflix-style Top 10 card: poster with a giant overlapping numeral.
private struct Top10Card: View {
    @Environment(\.isFocused) private var focused
    let item: DiscoverItem
    let rank: Int
    var isLocal: Bool = false

    var body: some View {
        HStack(alignment: .bottom, spacing: -34) {
            Text("\(rank)")
                .font(.system(size: rank == 10 ? 150 : 190, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(focused ? 0.95 : 0.35))
                .shadow(color: .black.opacity(0.8), radius: 6, x: 4, y: 4)
                .frame(width: rank == 10 ? 170 : 120, alignment: .trailing)
                .zIndex(1)
                .animation(.smooth(duration: 0.2), value: focused)
            CachedAsyncImage(url: item.posterURL, fallbackTitle: item.title)
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Large widescreen card with backdrop + title/logo and info — trending row.
/// On focus, shows the short synopsis.
private struct HeroBackdropCard: View {
    @Environment(\.isFocused) private var focused
    let item: DiscoverItem
    var isLocal: Bool = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: item.backdropURL ?? item.posterURL)
                .frame(width: 560, height: 315)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.55), location: 0.5),
                    .init(color: .black.opacity(0.95), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.title3.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    if let rating = item.rating, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .foregroundStyle(.yellow.opacity(0.95))
                    }
                    if let year = item.year { Text(String(year)) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

                // Short synopsis on focus.
                if focused, !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                        .transition(.opacity)
                }
            }
            .padding(20)
            .frame(width: 560, alignment: .leading)
        }
        .frame(width: 560, height: 315)
        .animation(.smooth(duration: 0.25), value: focused)
    }
}

/// Poster with a top badge (In theaters / Coming soon) and, optionally, the date.
private struct BadgePosterCard: View {
    let item: DiscoverItem
    let badge: String
    let icon: String
    let tint: Color
    let dateText: String?
    var isLocal: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 230, height: 345)
                .overlay(CachedAsyncImage(url: item.posterURL, fallbackTitle: item.title))
                .clipped()

            // Top badge.
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(badge.uppercased()).lineLimit(1)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint, in: Capsule())
            .padding(.top, 12)

            // Date (coming soon) at the bottom.
            if let dateText {
                VStack {
                    Spacer()
                    Text(dateText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.7))
                }
            }
        }
        .frame(width: 230, height: 345)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Hero

/// Fullscreen backdrop ONLY while browsing "Continue Watching"; elsewhere, a solid
/// background so rows are always legible. Soft dissolve between images:
/// the previous one stays until the new one has downloaded.
private struct HeroBackground: View {
    let item: MediaItem?
    let showsBackdrop: Bool

    @State private var displayed: UIImage?
    @State private var displayedKey: String?

    var body: some View {
        ZStack {
            Theme.background
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .scaledToFill()
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                    .clipped()
                    .ignoresSafeArea()
                    .overlay(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.05), location: 0),
                                .init(color: .black.opacity(0.6), location: 0.55),
                                .init(color: Theme.bgBottom.opacity(0.98), location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        LinearGradient(
                            colors: [.black.opacity(0.75), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .transition(.opacity)
                    .id(displayedKey)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: displayedKey)
        .task(id: taskKey) { await updateBackdrop() }
    }

    private var taskKey: String {
        showsBackdrop ? (item?.id ?? "none") : "off"
    }

    private func updateBackdrop() async {
        guard showsBackdrop, let item else {
            displayed = nil
            displayedKey = nil
            return
        }
        guard displayedKey != item.id else { return }
        guard let url = item.artURL(width: 1920, height: 1080) else { return }

        if let cached = ImageMemoryCache.image(for: url) {
            displayed = cached
            displayedKey = item.id
            return
        }
        guard let data = await ImageCache.shared.data(for: url),
              let image = UIImage(data: data),
              !Task.isCancelled else { return }
        ImageMemoryCache.store(image, for: url)
        displayed = image
        displayedKey = item.id
    }
}

private struct HeroInfo: View {
    let item: MediaItem?
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        // FIXED-height slots: no jumps when switching between short and long synopses.
        VStack(alignment: .leading, spacing: 18) {
            Group {
                if let item {
                    logoOrTitle(item)
                } else {
                    Color.clear
                }
            }
            .frame(height: 150, alignment: .bottomLeading)

            Group {
                if let item {
                    HStack(spacing: 16) {
                        if let year = item.year {
                            Text(String(year))
                        }
                        if let rating = item.audienceRating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        if let duration = item.durationMs, item.type == "movie" {
                            Text("\(duration / 60000) min")
                        }
                        if let resolution = item.videoResolution {
                            Text(resolution.uppercased())
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                } else {
                    Color.clear
                }
            }
            .frame(height: 32, alignment: .leading)

            Group {
                if let item, !item.displaySummary.isEmpty {
                    Text(item.displaySummary)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(3)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(height: 92, alignment: .topLeading)
        }
        .padding(.leading, 80)
        .padding(.top, 130)
        .animation(.smooth(duration: 0.35), value: item?.id)
    }

    @ViewBuilder
    private func logoOrTitle(_ item: MediaItem) -> some View {
        if let logo = item.logoURL, let url = URL(string: logo) {
            CachedAsyncImage(url: url, contentMode: .fit, showsPlaceholder: false)
                .frame(maxWidth: 480, maxHeight: 150, alignment: .leading)
                .id("logo-\(item.id)")
        } else {
            Text(item.displayTitle)
                .font(.system(size: 64, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: 800, alignment: .leading)
                .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
        }
    }
}

// MARK: - Shelf

struct ShelfView: View {
    let shelf: Shelf
    var focusedID: FocusState<String?>.Binding
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shelf.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.leading, 80)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: 32) {
                        ForEach(Array(shelf.items.enumerated()), id: \.element.id) { index, shelfItem in
                            let key = "\(shelf.id)|\(shelfItem.id)"
                            MediaCard(
                                shelfItem: shelfItem,
                                style: shelf.style,
                                rank: index + 1,
                                onSelect: onSelect
                            )
                            .id(key)
                            .focused(focusedID, equals: key)
                            .cardLongPressMenu(item: shelfItem.media, inContinue: shelf.id == "continue")
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 32)
                }
                .scrollClipDisabled()
                // Keeps the focused card centered (smooth auto-scroll).
                .onChange(of: focusedID.wrappedValue) { _, newValue in
                    guard let newValue, newValue.hasPrefix("\(shelf.id)|") else { return }
                    withAnimation(.smooth(duration: 0.35)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        // Cada fila es su propia sección de foco: subir/bajar entre filas y el menú
        // cae en el ítem más cercano aunque la fila tenga un solo ítem desalineado.
        .focusSection()
    }
}

// MARK: - Cards

private struct MediaCard: View {
    let shelfItem: ShelfItem
    let style: ShelfStyle
    let rank: Int
    let onSelect: (MediaItem) -> Void

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        switch style {
        case .poster:
            posterButton(width: 200, height: 300)
        case .posterLarge:
            posterButton(width: 250, height: 375)
        case .landscapeProgress:
            landscapeButton
        case .wide:
            wideButton
        case .numbered:
            numberedButton
        }
    }

    private var media: MediaItem { shelfItem.media }

    private func posterURL(width: Int, height: Int) -> URL? {
        media.posterURL(width: width, height: height)
    }

    private func artURL(width: Int, height: Int) -> URL? {
        media.artURL(width: width, height: height)
    }

    private func posterButton(width: CGFloat, height: CGFloat) -> some View {
        Button { onSelect(media) } label: {
            ExpandingPosterLabel(media: media, baseWidth: width, height: height)
        }
        .buttonStyle(MediaCardStyle(cornerRadius: 14))
    }

    private var landscapeButton: some View {
        Button { onSelect(media) } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: artURL(width: 780, height: 440))
                    .frame(width: 390, height: 220)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle = shelfItem.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .opacity(0.7)
                    }
                    if let progress = shelfItem.progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.25))
                                Capsule().fill(Theme.accent)
                                    .frame(width: geo.size.width * min(max(progress, 0.02), 1.0))
                            }
                        }
                        .frame(height: 5)
                    }
                    // Subtle runtime + time left of the in-progress item. Total and
                    // remaining use the SAME rounding, and remaining is clamped to the
                    // total, so it can never read more than the runtime.
                    if let total = shelfItem.totalMs, total > 0 {
                        let totalMin = max(1, Int((Double(total) / 60_000).rounded()))
                        let remMin = shelfItem.remainingMs.map {
                            min(totalMin, max(0, Int((Double($0) / 60_000).rounded())))
                        }
                        HStack(spacing: 6) {
                            Text(Self.hm(totalMin))
                            if let remMin, remMin >= 1, remMin < totalMin {
                                Spacer(minLength: 6)
                                Text(trf(L.continueLeft, Self.hm(remMin)))
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 1)
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(width: 390, alignment: .leading)
            }
            .frame(width: 390, height: 220)
        }
        .buttonStyle(MediaCardStyle(cornerRadius: 16))
    }

    /// "1h 23m" / "45m" from whole minutes.
    private static func hm(_ minutes: Int) -> String {
        let m = max(0, minutes)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    private var wideButton: some View {
        Button { onSelect(media) } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: artURL(width: 880, height: 500))
                    .frame(width: 440, height: 250)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    if let logo = media.logoURL, let url = URL(string: logo) {
                        CachedAsyncImage(url: url, contentMode: .fit, showsPlaceholder: false)
                            .frame(maxWidth: 240, maxHeight: 70, alignment: .leading)
                    } else {
                        Text(media.displayTitle)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                    }
                    if let rating = media.audienceRating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                .foregroundStyle(.white)
                .padding(20)
                .frame(width: 440, alignment: .leading)
            }
            .frame(width: 440, height: 250)
        }
        .buttonStyle(MediaCardStyle(cornerRadius: 18))
    }

    private var numberedButton: some View {
        HStack(alignment: .bottom, spacing: -34) {
            Text("\(rank)")
                .font(.system(size: 190, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(height: 200, alignment: .bottom)
                .zIndex(0)
            Button { onSelect(media) } label: {
                CachedAsyncImage(url: posterURL(width: 400, height: 600))
                    .frame(width: 200, height: 300)
            }
            .buttonStyle(MediaCardStyle(cornerRadius: 14))
            .zIndex(1)
        }
    }
}

/// Poster that, on focus, expands into a widescreen card with the info inside
/// (backdrop + title + PG + rating + synopsis). Prime Video style.
private struct ExpandingPosterLabel: View {
    @Environment(\.isFocused) private var focused
    let media: MediaItem
    let baseWidth: CGFloat
    let height: CGFloat
    /// Available on a local server (override; by default inferred from the item).
    var isLocal: Bool? = nil
    private var localResolved: Bool { isLocal ?? !media.isVirtual }

    private var expandedWidth: CGFloat { height * 16 / 9 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Poster (normal state).
            CachedAsyncImage(url: media.posterURL(width: Int(baseWidth * 2), height: Int(height * 2)), fallbackTitle: media.displayTitle)
                .frame(width: focused ? expandedWidth : baseWidth, height: height)
                .opacity(focused ? 0 : 1)

            // Widescreen with info (focused state).
            if focused {
                ZStack(alignment: .bottomLeading) {
                    CachedAsyncImage(url: media.artURL(width: Int(expandedWidth * 2), height: Int(height * 2)))
                        .frame(width: expandedWidth, height: height)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.55),
                            .init(color: .black.opacity(0.92), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text(media.displayTitle)
                            .font(.callout.weight(.bold))
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            if let contentRating = media.contentRating {
                                Text(contentRating)
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                                    )
                            }
                            if let rating = media.audienceRating {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow.opacity(0.9))
                            }
                            if let year = media.year {
                                Text(String(year))
                                    .font(.caption2)
                                    .opacity(0.8)
                            }
                            if media.type == "show", let count = media.leafCount, count > 0 {
                                Label("\(count) \(tr(L.episodesCount))", systemImage: "tv")
                                    .font(.caption2)
                                    .opacity(0.8)
                            }
                        }
                        if !media.displaySummary.isEmpty {
                            Text(media.displaySummary)
                                .font(.caption2)
                                .opacity(0.75)
                                .lineLimit(2)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .frame(width: expandedWidth, alignment: .leading)
                }
                .frame(width: expandedWidth, height: height)
                .transition(.opacity)
            }
        }
        .frame(width: focused ? expandedWidth : baseWidth, height: height)
        .animation(.smooth(duration: 0.32), value: focused)
    }
}

struct MediaCardStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14
    /// When set, the focus effect is driven by this (the row's real @FocusState)
    /// instead of @Environment(\.isFocused), which can get stuck expanded after a
    /// context menu dismisses on tvOS.
    var focusedOverride: Bool? = nil

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, cornerRadius: cornerRadius, focusedOverride: focusedOverride)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var envFocused
        let configuration: Configuration
        let cornerRadius: CGFloat
        let focusedOverride: Bool?
        private var focused: Bool { focusedOverride ?? envFocused }

        var body: some View {
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 3)
                )
                .shadow(
                    color: .black.opacity(focused ? 0.7 : 0.35),
                    radius: focused ? 28 : 12,
                    y: focused ? 16 : 8
                )
                .scaleEffect(focused ? 1.1 : 1.0)
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .animation(.smooth(duration: 0.25), value: focused)
                .animation(.smooth(duration: 0.12), value: configuration.isPressed)
        }
    }
}
