import SwiftUI
import GRDB

/// Browsing of the FULL TMDB catalog for a tab, with filters and pagination.
/// Optimized: pages of 20, incremental loading on scroll, response caching
/// in TMDBClient and mapping to the local copy when the title is already in the library.
@MainActor
final class CatalogBrowseViewModel: ObservableObject {
    let kind: CatalogKind

    @Published var items: [MediaItem] = []
    @Published var filters = TMDBBrowse.CatalogFilters()
    @Published var loading = false
    @Published var loadingMore = false

    private var page = 0
    private var totalPages = 1
    private var seen = Set<String>()
    private var task: Task<Void, Never>?

    init(kind: CatalogKind, genre: Int? = nil) {
        self.kind = kind
        self.filters.genreID = genre
    }

    func reload() {
        task?.cancel()
        task = Task { await load(reset: true) }
    }

    func loadMoreIfNeeded(current: MediaItem) {
        guard !loading, !loadingMore, page < totalPages else { return }
        guard let idx = items.firstIndex(where: { $0.id == current.id }), idx >= items.count - 8 else { return }
        task = Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        if reset { page = 0; totalPages = 1; seen.removeAll(); loading = true }
        else { loadingMore = true }
        defer { loading = false; loadingMore = false }

        let next = page + 1
        let (discoverItems, pages) = await TMDBBrowse.discover(kind: kind, filters: filters, page: next)
        guard !Task.isCancelled else { return }
        page = next
        totalPages = pages

        let mapped = await Self.mapToCatalog(discoverItems)
        guard !Task.isCancelled else { return }
        var result = reset ? [] : items
        for m in mapped where seen.insert(m.mergeKey).inserted { result.append(m) }
        items = result
    }

    /// Maps TMDB items to MediaItem: local copy if it exists, otherwise a virtual stub.
    private static func mapToCatalog(_ discoverItems: [DiscoverItem]) async -> [MediaItem] {
        // Parental first shield by age certification (handles virtual items, which
        // carry no contentRating). Replaces the old MediaItem filter that hid ALL
        // virtual content under any restriction.
        let safe = await ParentalStore.shared.filterDiscover(discoverItems)
        let ids = safe.map(\.tmdbID)
        let locals = (try? await AppDatabase.shared.dbQueue.read { db in
            try MediaItem.filter(ids.contains(Column("tmdbID"))).fetchAll(db)
        }) ?? []
        let localByKey = HomeViewModel.merged(locals).reduce(into: [String: MediaItem]()) { $0[$1.mergeKey] = $1 }
        return safe.map { d in localByKey[d.mergeKey] ?? MediaItem.virtualStub(from: d) }
    }
}

struct CatalogBrowseView: View {
    let kind: CatalogKind
    let title: String

    /// Presented as a cover (from a category) → no navigation bar at the top,
    /// so we reduce the top margin and allow closing with "back".
    let asCover: Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: CatalogBrowseViewModel
    @State private var selectedItem: MediaItem?
    @State private var focusedItem: MediaItem?
    @State private var activeFilter: CatalogFilterDimension?
    /// Ancla de foco en el panel de filtros: tras cambiar un filtro, el foco vuelve a
    /// su píldora (el panel es estable entre recargas) en vez de escaparse a la barra
    /// de tabs de arriba — que, al activarse por foco, sacaba al usuario al Home.
    @FocusState private var panelFocus: CatalogFilterDimension?

    // Filter panel on the left → less width for the grid (5 columns).
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 32), count: 5)

    init(kind: CatalogKind, title: String, genre: Int? = nil, asCover: Bool = false) {
        self.kind = kind
        self.title = title
        self.asCover = asCover
        _vm = StateObject(wrappedValue: CatalogBrowseViewModel(kind: kind, genre: genre))
    }

    var body: some View {
        ZStack {
            Theme.background

            HStack(alignment: .top, spacing: 0) {
                // Left filter panel.
                CatalogFilterPanel(kind: kind, title: title, filters: vm.filters, focus: $panelFocus) { activeFilter = $0 }
                    .frame(width: 320)
                    .padding(.leading, 60)
                    .padding(.top, asCover ? 56 : 150)

                // Right: focused item header + grid.
                VStack(alignment: .leading, spacing: 0) {
                    FocusedInfoHeader(item: focusedItem, fallbackTitle: title, topPadding: asCover ? 44 : 150, horizontalPadding: 24)

                    if vm.loading && vm.items.isEmpty {
                        Spacer()
                        HStack { Spacer(); ProgressView().scaleEffect(1.4); Spacer() }
                        Spacer()
                    } else if vm.items.isEmpty {
                        Spacer()
                        Text(tr(L.noResults))
                            .font(.title3).foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: columns, spacing: 44) {
                                ForEach(vm.items) { item in
                                    GridPosterCard(item: item, onFocus: { focusedItem = $0 }) {
                                        selectedItem = $0
                                    }
                                    .onAppear { vm.loadMoreIfNeeded(current: item) }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .padding(.bottom, 40)

                            if vm.loadingMore {
                                ProgressView().padding(.bottom, 40)
                            }
                        }
                        .clipped()
                        .focusSection()
                    }
                }
                .padding(.trailing, 60)
            }
            .disabled(activeFilter != nil)   // traps focus in the filter modal
        }
        .overlay {
            if let dimension = activeFilter {
                CatalogFilterPicker(kind: kind, dimension: dimension, filters: $vm.filters) {
                    activeFilter = nil
                    // Devuelve el foco a la píldora del filtro (queda dentro del catálogo,
                    // no se escapa a la barra de tabs → ya no salta al Home al recargar).
                    panelFocus = dimension
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: activeFilter)
        .task { if vm.items.isEmpty { vm.reload() } }
        .onChange(of: vm.filters) { _, _ in vm.reload() }
        .onExitCommand {
            // The filter modal closes itself (its own handler); otherwise, "back" closes the cover.
            if activeFilter != nil { activeFilter = nil }
            else if asCover { dismiss() }
        }
        .fullScreenCover(item: $selectedItem) { item in
            DetailView(item: item)
        }
    }
}

/// Filter dimension open in the modal picker.
enum CatalogFilterDimension: Identifiable {
    case sort, genre, year, rating
    var id: Int { hashValue }
}

// MARK: - Filter panel (left sidebar)

/// Vertical panel: one "Label: value" row per dimension. On tap, opens the
/// modal picker with all options (scrollable).
private struct CatalogFilterPanel: View {
    let kind: CatalogKind
    let title: String
    let filters: TMDBBrowse.CatalogFilters
    var focus: FocusState<CatalogFilterDimension?>.Binding
    let onOpen: (CatalogFilterDimension) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.bottom, 8)

            Text(tr(L.filtersTitle).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.4))
                .kerning(1.2)

            pill(.sort, icon: "arrow.up.arrow.down", title: tr(L.filterSort), value: sortLabel)
            pill(.genre, icon: "theatermasks", title: tr(L.filterGenre), value: genreLabel)
            pill(.year, icon: "calendar", title: tr(L.filterYear), value: filters.year.map(String.init) ?? tr(L.filterAnyShort))
            pill(.rating, icon: "star", title: tr(L.filterRatingShort), value: filters.minRating.map { "\(Int($0))+" } ?? tr(L.filterAnyShort))
            Spacer()
        }
        .focusSection()
    }

    private var sortLabel: String {
        switch filters.sort {
        case .recent: tr(L.filterSortRecent)
        case .popular: tr(L.filterSortPopular)
        case .rating: tr(L.filterSortRating)
        case .oldest: tr(L.filterSortOldest)
        }
    }

    private var genreLabel: String {
        guard let id = filters.genreID,
              let name = TMDBBrowse.genreOptions(kind: kind).first(where: { $0.id == id })?.name
        else { return tr(L.filterAllShort) }
        return name
    }

    private func pill(_ dimension: CatalogFilterDimension, icon: String, title: String, value: String) -> some View {
        Button { onOpen(dimension) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.callout)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .opacity(0.5)
                    Text(value)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FilterPillStyle())
        .focused(focus, equals: dimension)
    }
}

/// Modal picker for a filter dimension: scrollable list of options.
private struct CatalogFilterPicker: View {
    let kind: CatalogKind
    let dimension: CatalogFilterDimension
    @Binding var filters: TMDBBrowse.CatalogFilters
    let onClose: () -> Void

    @FocusState private var focused: String?

    private var years: [Int] {
        guard let current = Int(TMDBBrowse.todayString.prefix(4)) else { return [] }
        return (0..<40).map { current - $0 }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark).ignoresSafeArea()
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(options, id: \.key) { option in
                            Button { option.apply(); onClose() } label: {
                                HStack {
                                    Text(option.label).font(.callout.weight(.semibold))
                                    Spacer()
                                    if option.selected {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                                .frame(maxWidth: 620, alignment: .leading)
                            }
                            .buttonStyle(CatalogRowStyle())
                            .focused($focused, equals: option.key)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 520)
            }
            .padding(50)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .focusSection()
        .onExitCommand(perform: onClose)
        .onAppear {
            // Take focus on the selected option so that "back" closes the modal.
            focused = options.first(where: { $0.selected })?.key ?? options.first?.key
        }
    }

    private var title: String {
        switch dimension {
        case .sort: tr(L.filterSort)
        case .genre: tr(L.filterGenre)
        case .year: tr(L.filterYear)
        case .rating: tr(L.filterRatingShort)
        }
    }

    private struct Option {
        let key: String
        let label: String
        let selected: Bool
        let apply: () -> Void
    }

    private var options: [Option] {
        switch dimension {
        case .sort:
            let sorts: [(TMDBBrowse.CatalogSort, String)] = [
                (.recent, tr(L.filterSortRecent)), (.popular, tr(L.filterSortPopular)),
                (.rating, tr(L.filterSortRating)), (.oldest, tr(L.filterSortOldest)),
            ]
            return sorts.map { s in
                Option(key: s.0.rawValue, label: s.1, selected: filters.sort == s.0) { filters.sort = s.0 }
            }
        case .genre:
            var opts = [Option(key: "all", label: tr(L.filterAllGenres), selected: filters.genreID == nil) { filters.genreID = nil }]
            opts += TMDBBrowse.genreOptions(kind: kind).map { g in
                Option(key: "g\(g.id)", label: g.name, selected: filters.genreID == g.id) { filters.genreID = g.id }
            }
            return opts
        case .year:
            var opts = [Option(key: "any", label: tr(L.filterAnyYear), selected: filters.year == nil) { filters.year = nil }]
            opts += years.map { y in
                Option(key: "y\(y)", label: String(y), selected: filters.year == y) { filters.year = y }
            }
            return opts
        case .rating:
            var opts = [Option(key: "any", label: tr(L.filterAll), selected: filters.minRating == nil) { filters.minRating = nil }]
            opts += [9.0, 8.0, 7.0, 6.0, 5.0].map { r in
                Option(key: "r\(Int(r))", label: "\(Int(r))+", selected: filters.minRating == r) { filters.minRating = r }
            }
            return opts
        }
    }
}

/// Filter pill style (subtle box; highlights on focus).
private struct FilterPillStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        @Environment(\.isFocused) private var focused
        let configuration: ButtonStyleConfiguration
        var body: some View {
            configuration.label
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .foregroundStyle(focused ? .black : .white)
                .background(focused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
                .scaleEffect(focused ? 1.05 : 1.0)
                .animation(.smooth(duration: 0.18), value: focused)
        }
    }
}

/// Selectable row inside the modal filter picker.
private struct CatalogRowStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View { Inner(configuration: configuration) }
    private struct Inner: View {
        @Environment(\.isFocused) private var focused
        let configuration: ButtonStyleConfiguration
        var body: some View {
            configuration.label
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .foregroundStyle(focused ? .black : .white)
                .background(focused ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 12))
                .animation(.smooth(duration: 0.16), value: focused)
        }
    }
}
