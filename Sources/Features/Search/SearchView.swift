import SwiftUI
import GRDB

struct SearchView: View {
    @State private var query = ""
    @State private var results: [CatalogItem] = []
    @State private var selection: CatalogItem?
    @State private var recents: [String] = []
    @FocusState private var fieldFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 36), count: 6)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        ZStack {
            Theme.background

            VStack(spacing: 30) {
                HStack(spacing: 18) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(fieldFocused ? Theme.accent : .white.opacity(0.55))
                    TextField(tr(L.searchPlaceholder), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($fieldFocused)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(fieldFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(fieldFocused ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.15)),
                                      lineWidth: fieldFocused ? 2.5 : 1)
                )
                .frame(maxWidth: 1000)
                .padding(.top, 140)
                .animation(.smooth(duration: 0.2), value: fieldFocused)
                .focusSection()

                content
            }
        }
        .task { recents = RecentSearches.load() }
        .onChange(of: query) { _, newValue in
            Task { await search(newValue) }
        }
        .fullScreenCover(item: $selection) { item in
            CatalogDetailRouter(item: item)
        }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.count < 2 {
            if recents.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: tr(L.searchPlaceholder),
                    subtitle: tr(L.searchHint)
                )
            } else {
                recentsSection
            }
        } else if results.isEmpty {
            emptyState(
                icon: "film.stack",
                title: "\(tr(L.noResults)) “\(trimmedQuery)”",
                subtitle: tr(L.noResultsHint)
            )
        } else {
            // A single grid — local and TMDB mixed, with no visible distinction.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(results) { item in
                        Button {
                            RecentSearches.add(trimmedQuery)
                            recents = RecentSearches.load()
                            selection = item
                        } label: {
                            Color.clear
                                .aspectRatio(2 / 3, contentMode: .fit)
                                .overlay(CachedAsyncImage(url: item.posterURL))
                                .clipped()
                        }
                        .buttonStyle(MediaCardStyle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 50)
            }
            .clipped()
            .focusSection()
        }
    }

    // MARK: Recent searches

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 24) {
                Text(tr(L.recentSearches))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button(tr(L.clearRecents)) {
                    RecentSearches.clear()
                    recents = []
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(recents, id: \.self) { term in
                        Button {
                            query = term
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .font(.callout)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()

            Spacer()
        }
        .padding(.horizontal, 90)
        .padding(.top, 20)
        .focusSection()
    }

    // MARK: Empty state

    private func emptyState(icon: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.55))
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Search

    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            return
        }
        let raw = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem
                .filter(Column("title").like("%\(trimmed)%") || Column("tmdbTitle").like("%\(trimmed)%"))
                .order(Column("sortTitle").asc)
                .limit(120)
                .fetchAll(db)
        }) ?? []
        let local = ParentalStore.shared.filter(HomeViewModel.merged(raw)).sorted { $0.sortTitle < $1.sortTitle }
        var merged = local.map { CatalogItem(local: $0) }

        // TMDB: if the source is ready, add what you don't already have — all in a single list.
        if SettingsStore.shared.fullCatalogEnabled {
            let localTmdbIDs = Set(local.compactMap(\.tmdbID))
            let found = await TMDBBrowse.search(trimmed)
            guard query.trimmingCharacters(in: .whitespaces) == trimmed else { return } // discard stale results
            // Parental first shield by age certification (TMDB results carry none).
            let safe = await ParentalStore.shared.filterDiscover(found)
            merged += safe
                .filter { !localTmdbIDs.contains($0.tmdbID) }
                .map { CatalogItem(discover: $0) }
        }
        results = merged
    }
}

// MARK: - Recent searches persistence (per user)

@MainActor
enum RecentSearches {
    private static var key: String { "recentSearches-\(UserContext.currentUserID)" }

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespaces)
        guard clean.count >= 2 else { return }
        var list = load().filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        list.insert(clean, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
