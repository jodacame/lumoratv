import SwiftUI
import GRDB

struct MediaGridView: View {
    let kind: CatalogKind
    let title: String

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var syncStatus = SyncStatus.shared
    @State private var items: [MediaItem] = []
    @State private var selectedItem: MediaItem?
    @State private var focusedItem: MediaItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 36), count: 6)

    var body: some View {
        ZStack {
            Theme.background
            if items.isEmpty {
                Text(tr(L.emptyLibrary))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                // Fixed header with the focused item's info; the grid scrolls BELOW it.
                VStack(spacing: 0) {
                    FocusedInfoHeader(item: focusedItem, fallbackTitle: title)

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 48) {
                            ForEach(items) { item in
                                GridPosterCard(
                                    item: item,
                                    onFocus: { focusedItem = $0 },
                                    onSelect: {
                                        selectedItem = $0
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.top, 36)
                        .padding(.bottom, 60)
                    }
                    .clipped()
                }
            }
        }
        .task { await load() }
        .onChange(of: syncStatus.generation) { _, _ in
            Task { await load() }
        }
        .fullScreenCover(item: $selectedItem) { item in
            DetailView(item: item)
        }
    }

    private func load() async {
        // Base by type: anime and documentaries can be a movie or a show; the rest by their Plex type.
        let baseTypes: [String] = (kind == .anime || kind == .documentary)
            ? ["movie", "show"]
            : [kind == .movie ? "movie" : "show"]
        let raw = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(baseTypes.contains(Column("type"))).fetchAll(db)
        }) ?? []
        let target = kind
        items = ParentalStore.shared.filter(HomeViewModel.merged(raw))
            .filter { $0.classification == target }
            .sorted { $0.sortTitle < $1.sortTitle }
    }
}

/// Fixed-height header with the focused item's info (title · PG · meta · synopsis).
struct FocusedInfoHeader: View {
    let item: MediaItem?
    let fallbackTitle: String
    var topPadding: CGFloat = 128
    var horizontalPadding: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title (fixed slot).
            Group {
                if let item {
                    Text(item.displayTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                } else {
                    Text(fallbackTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 42, alignment: .bottomLeading)

            // Metadata (fixed slot).
            Group {
                if let item {
                    HStack(spacing: 14) {
                        if let contentRating = item.contentRating {
                            Text(contentRating)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                                )
                        }
                        if let rating = item.audienceRating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(.yellow.opacity(0.9))
                        }
                        if let year = item.year {
                            Text(String(year))
                        }
                        if let duration = item.durationMs, item.type == "movie" {
                            let total = duration / 1000
                            let h = total / 3600, mins = (total % 3600) / 60
                            Text(h > 0 ? "\(h)h \(mins)m" : "\(mins)m")
                        }
                        if let resolution = item.videoResolution {
                            Text(resolution.lowercased() == "4k" ? "4K" : resolution.uppercased())
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                } else {
                    Color.clear
                }
            }
            .frame(height: 28, alignment: .leading)

            // Synopsis (fixed slot, 2 lines).
            Group {
                if let item, !item.displaySummary.isEmpty {
                    Text(item.displaySummary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: 1100, alignment: .topLeading)
            .frame(height: 58, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .animation(.smooth(duration: 0.25), value: item?.id)
    }
}

struct GridPosterCard: View {
    let item: MediaItem
    var onFocus: ((MediaItem) -> Void)? = nil
    let onSelect: (MediaItem) -> Void

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Button {
            guard !CardMenuController.shared.selectSuppressed else { return }
            onSelect(item)
        } label: {
            // Strict 2:3 cell: the image fills and gets cropped — all posters identical.
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(
                    CachedAsyncImage(url: posterURL, fallbackTitle: item.displayTitle)
                )
                .clipped()
                .modifier(FocusReporter { isFocused in
                    if isFocused { onFocus?(item) }
                })
        }
        .buttonStyle(MediaCardStyle(cornerRadius: 14))
        .cardLongPressMenu(item: item)
    }

    private var posterURL: URL? {
        item.posterURL(width: 400, height: 600)
    }
}

/// Reports focus changes from inside a button's label.
private struct FocusReporter: ViewModifier {
    @Environment(\.isFocused) private var focused
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: focused) { _, newValue in
            action(newValue)
        }
    }
}
