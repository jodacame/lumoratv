import SwiftUI

struct MainView: View {
    enum MainTab: Hashable, CaseIterable {
        case home, movies, shows, anime, doramas, documentaries, search, fluxtorrent, settings
    }

    @ObservedObject private var cardMenu = CardMenuController.shared
    @ObservedObject private var deepLink = DeepLinkRouter.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var profiles = ProfileStore.shared
    @State private var tab: MainTab = .home
    @FocusState private var focusedTab: MainTab?
    @State private var showFirstSync = false

    var body: some View {
        ZStack(alignment: .top) {
            // Full-screen content; the bar floats on top.
            Group {
                switch tab {
                case .home: HomeView()
                case .movies: catalogTab(.movie, tr(L.tabMovies))
                case .shows: catalogTab(.series, tr(L.tabShows))
                case .anime: catalogTab(.anime, tr(L.tabAnime))
                case .doramas: catalogTab(.dorama, tr(L.tabDoramas))
                case .documentaries: catalogTab(.documentary, tr(L.tabDocumentaries))
                case .search: SearchView()
                case .fluxtorrent: FluxTorrentView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            topBar

            if showFirstSync {
                FirstSyncOverlay()
            }

            if let target = cardMenu.target {
                CardMenuOverlay(target: target, controller: cardMenu)
                    .transition(.opacity)
                    .zIndex(10)
            }

            ToastOverlay().zIndex(20)
        }
        .ignoresSafeArea()
        // Botón Menu del control: si NO estás en Home, vuelve a Home; en Home,
        // comportamiento por defecto (salir de la app). nil = no interceptar.
        .onExitCommand(perform: tab == .home ? nil : { withAnimation(.smooth(duration: 0.25)) { tab = .home } })
        .animation(.smooth(duration: 0.22), value: cardMenu.target?.item.id)
        .fullScreenCover(item: $cardMenu.playable) { media in
            PlayerView(media: media)
        }
        .fullScreenCover(item: $cardMenu.detailItem) { item in
            DetailView(item: item)
        }
        .fullScreenCover(item: $deepLink.pendingItem) { item in
            DetailView(item: item)
        }
        .task {
            // Detect FluxTorrent so its dashboard tab can appear (no-op otherwise).
            await settings.refreshFluxTorrentDetection()
            if await AppDatabase.shared.isEmpty() {
                showFirstSync = true
            }
            await SyncEngine.shared.sync()
            // First time per user: inherit Plex state as the starting point.
            await WatchStore.seedIfNeeded(userID: UserContext.currentUserID)
            showFirstSync = false
            // LRU purge of the image cache according to the configured limit.
            let limitGB = SettingsStore.shared.cacheLimitGB
            if limitGB > 0 {
                await ImageCache.shared.enforceLimit(maxBytes: Int64(limitGB) * 1_073_741_824)
            }
        }
    }

    /// Tab catalog: full TMDB with filters if the catalog is available;
    /// otherwise, the local library as usual.
    @ViewBuilder
    private func catalogTab(_ kind: CatalogKind, _ title: String) -> some View {
        if settings.fullCatalogEnabled {
            CatalogBrowseView(kind: kind, title: title)
        } else {
            MediaGridView(kind: kind, title: title)
        }
    }

    // MARK: Fixed top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Text("LumoraTV")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(Theme.logoGradient)
                .padding(.trailing, 8)

            // Tabs alineados a la IZQUIERDA (como el contenido) en su propia sección
            // de foco → subir desde el contenido cae en el tab que está justo arriba.
            HStack(spacing: 14) {
                tabButton(.home, icon: "house.fill", label: tr(L.tabHome))
                tabButton(.movies, icon: "film.fill", label: tr(L.tabMovies))
                tabButton(.shows, icon: "tv.fill", label: tr(L.tabShows))
                tabButton(.anime, icon: "bolt.fill", label: tr(L.tabAnime))
                tabButton(.doramas, icon: "heart.fill", label: tr(L.tabDoramas))
                tabButton(.documentaries, icon: "globe.americas.fill", label: tr(L.tabDocumentaries))
                tabButton(.search, icon: "magnifyingglass", label: tr(L.tabSearch))
                // Only when the configured torrent server is FluxTorrent (not plain TorrServer).
                if settings.fluxTorrentAvailable {
                    tabButton(.fluxtorrent, icon: "arrow.up.arrow.down.circle.fill", label: tr(L.tabFluxTorrent))
                }
                tabButton(.settings, icon: "gearshape.fill", label: tr(L.tabSettings))
            }
            .focusSection()

            Spacer()

            // Perfil activo (estilo Netflix): nombre + avatar arriba a la derecha;
            // al seleccionarlo abre "¿Quién está viendo?". Sección propia.
            Button { profiles.requestSelection() } label: {
                HStack(spacing: 12) {
                    Text(profiles.current.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    ProfileAvatar(profile: profiles.current, size: 50, animated: false)
                }
            }
            .buttonStyle(ProfileMenuButtonStyle())
            .focusSection()
        }
        .padding(.horizontal, 80)
        .padding(.top, 46)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.88), .black.opacity(0.55), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
        .onChange(of: focusedTab) { _, newValue in
            // The tab activates on focus, like the native bar.
            if let newValue { tab = newValue }
        }
    }

    private func tabButton(_ target: MainTab, icon: String, label: String) -> some View {
        Button {
            tab = target
        } label: { EmptyView() }
        .buttonStyle(ExpandingTabStyle(icon: icon, label: label, selected: tab == target))
        .focused($focusedTab, equals: target)
    }
}

/// Botón nombre+avatar de perfil en la barra: píldora resaltada + escala al enfocar.
private struct ProfileMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? .white : .white.opacity(0.85))
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(focused ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
                .scaleEffect(focused ? 1.06 : 1.0)
                .shadow(color: focused ? Theme.accent.opacity(0.45) : .clear, radius: 16, y: 6)
                .animation(.smooth(duration: 0.2), value: focused)
        }
    }
}

/// Tab solo-icono: resalta con una cápsula al enfocar / estar activo (sin label).
private struct ExpandingTabStyle: ButtonStyle {
    let icon: String
    let label: String
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inner(icon: icon, label: label, selected: selected)
    }

    private struct Inner: View {
        @Environment(\.isFocused) private var focused
        let icon: String
        let label: String
        let selected: Bool

        var body: some View {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(focused ? .black : .white.opacity(selected ? 1 : 0.55))
                .frame(width: 56, height: 52)
                .background(
                    Capsule().fill(focused ? Color.white : (selected ? Color.white.opacity(0.18) : Color.clear))
                )
                .scaleEffect(focused ? 1.08 : 1.0)
                .animation(.smooth(duration: 0.18), value: focused)
                .accessibilityLabel(label)
        }
    }
}

private struct FirstSyncOverlay: View {
    @ObservedObject private var syncStatus = SyncStatus.shared

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 30) {
                Text("LumoraTV")
                    .font(.system(size: 80, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.logoGradient)
                ProgressView()
                Text(tr(L.preparing))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                if case .syncing(let detail) = syncStatus.phase {
                    Text("\(tr(L.syncingLibrary)) \(detail)…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .transition(.opacity)
    }
}
