import SwiftUI

/// Two-pane settings, native tvOS style: categories on the left
/// (activated on focus), detail on the right.
struct SettingsView: View {
    enum Category: Hashable, CaseIterable {
        case language, playback, services, ai, smartData, storage, parental, system

        var icon: String {
            switch self {
            case .language: "globe"
            case .playback: "play.circle"
            case .services: "antenna.radiowaves.left.and.right"
            case .ai: "sparkles"
            case .smartData: "brain.head.profile"
            case .storage: "internaldrive"
            case .parental: "lock.shield"
            case .system: "gearshape"
            }
        }

        @MainActor var label: String {
            switch self {
            case .language: tr(L.language)
            case .playback: tr(L.playbackSection)
            case .services: tr(L.servicesSection)
            case .ai: tr(L.aiSection)
            case .smartData: tr(L.smartDataSection)
            case .storage: tr(L.storageSection)
            case .parental: tr(L.parentalTitle)
            case .system: tr(L.systemSection)
            }
        }
    }

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var l10n = L10nStore.shared
    @ObservedObject private var syncStatus = SyncStatus.shared
    @ObservedObject private var iCloudSync = SyncCoordinator.shared

    @State private var selected: Category = .language
    @FocusState private var focusedCategory: Category?
    @State private var confirmPushProfiles = false

    // Add server
    @State private var addingServer = false
    @State private var discoverySearched = false
    @State private var discoveredServers: [ResolvedServer] = []

    // Language pickers
    @State private var showAudioPicker = false
    @State private var showSubtitlePicker = false

    // Trakt (community)
    @State private var traktIDInput = ""
    @State private var traktSecretInput = ""
    @StateObject private var traktLink = TraktLinkModel()

    // AI
    @State private var aiKeyInput = ""
    @State private var aiModels: [String] = []
    @State private var aiModelsLoading = false
    @State private var aiModelsError = false
    @State private var objectWillChangeTick = false

    // TMDB
    @State private var tmdbKeyInput = ""
    @State private var tmdbSaving = false
    @State private var tmdbError: String?

    // Test connection per service.
    @State private var serviceTests: [String: ServiceTest] = [:]
    @State private var serviceTesting: Set<String> = []

    private func testRow(id: String, run: @escaping () async -> ServiceTest) -> some View {
        HStack(spacing: 16) {
            Button {
                serviceTesting.insert(id)
                serviceTests[id] = nil
                Task {
                    let result = await run()
                    serviceTests[id] = result
                    serviceTesting.remove(id)
                }
            } label: {
                Label(tr(L.testConnection), systemImage: "bolt.horizontal.circle")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(serviceTesting.contains(id))

            if serviceTesting.contains(id) {
                ProgressView()
            } else if let t = serviceTests[id] {
                Label(t.message, systemImage: t.isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(t.isOK ? .green : .red)
                    .lineLimit(2)
            }
        }
        .padding(.top, 4)
    }
    @State private var prowlarrKeyInput = ""
    @State private var osKeyInput = ""
    @State private var osPassInput = ""
    @State private var speedResults: [String: String] = [:]
    @State private var speedMbps: [String: Double] = [:]
    @State private var speedTesting: Set<String> = []

    private func runSpeedTest(_ server: PlexServerRef) {
        guard let token = settings.token(forServer: server.id), !speedTesting.contains(server.id) else { return }
        speedTesting.insert(server.id)
        speedResults[server.id] = nil
        Task {
            do {
                let mbps = try await SpeedTest.run(serverID: server.id, baseURL: server.url, token: token)
                speedMbps[server.id] = mbps
                speedResults[server.id] = String(format: "%.0f Mbps", mbps)
            } catch {
                speedResults[server.id] = error.localizedDescription
            }
            speedTesting.remove(server.id)
        }
    }

    private func speedColor(_ id: String) -> Color {
        guard let mbps = speedMbps[id] else { return .orange }
        if mbps >= 80 { return .green }     // comfortable 4K
        if mbps >= 25 { return Theme.accentSoft } // 1080p
        return .orange
    }

    var body: some View {
        ZStack {
            Theme.background

            HStack(alignment: .top, spacing: 56) {
                sidebar
                    .frame(width: 320, alignment: .leading)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 90)
            .padding(.top, 150)
        }
    }

    // MARK: Sidebar

    /// En un perfil de niños NO se muestra el control parental (no debe verlo ni
    /// cambiarlo); su límite lo define el perfil, gestionado desde un perfil adulto.
    private var visibleCategories: [Category] {
        ProfileStore.shared.current.isKid
            ? Category.allCases.filter { $0 != .parental }
            : Category.allCases
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleCategories, id: \.self) { category in
                Button { selected = category } label: { EmptyView() }
                    .buttonStyle(SidebarRowStyle(icon: category.icon, label: category.label,
                                                 selected: selected == category))
                    .focused($focusedCategory, equals: category)
            }
            Spacer()
        }
        .focusSection()
        .onChange(of: focusedCategory) { _, newValue in
            if let newValue { selected = newValue }
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 34) {
                switch selected {
                case .language: languageDetail
                case .playback: playbackDetail
                case .services: servicesDetail
                case .ai: aiDetail
                case .smartData: SmartDataSection()
                case .storage: StorageDetail()
                case .parental: ParentalSection()
                case .system: systemDetail
                }
            }
            .padding(.vertical, 12)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        .focusSection()
    }

    // MARK: Language

    private var languageDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader(tr(L.language))
            choiceRow(tr(L.langAuto), selected: l10n.language == .auto) { l10n.language = .auto }
            choiceRow(tr(L.langEn), selected: l10n.language == .english) { l10n.language = .english }
            choiceRow(tr(L.langEs), selected: l10n.language == .spanish) { l10n.language = .spanish }
        }
    }

    // MARK: Playback

    private var playbackDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader(tr(L.audioLanguage))
            languageSelectorRow(
                current: settings.audioLang, special: tr(L.original), specialValue: "auto"
            ) { showAudioPicker = true }

            groupHeader(tr(L.subtitleLanguage))
                .padding(.top, 18)
            languageSelectorRow(
                current: settings.subtitleLang, special: tr(L.subtitlesOff), specialValue: "off"
            ) { showSubtitlePicker = true }

            groupHeader(tr(L.subtitleStyle))
                .padding(.top, 18)
            inlineChoices(tr(L.subtitleSize), options: [
                ("small", tr(L.sizeSmall)), ("medium", tr(L.sizeMedium)),
                ("large", tr(L.sizeLarge)), ("xlarge", tr(L.sizeXLarge)),
            ], current: settings.subSize) { settings.subSize = $0 }
            inlineChoices(tr(L.subtitleFont), options: [
                ("default", tr(L.fontDefault)), ("rounded", tr(L.fontRounded)),
                ("serif", tr(L.fontSerif)), ("mono", tr(L.fontMono)),
            ], current: settings.subFont) { settings.subFont = $0 }
            inlineChoices(tr(L.subtitleColor), options: [
                ("white", tr(L.colorWhite)), ("yellow", tr(L.colorYellow)), ("cyan", tr(L.colorCyan)),
            ], current: settings.subColor) { settings.subColor = $0 }

            groupHeader(tr(L.colorModeGroup))
                .padding(.top, 18)
            inlineChoices("", options: [
                ("normal", tr(L.colorModeNormal)), ("sleep", tr(L.colorModeSleep)),
                ("vivid", tr(L.colorModeVivid)), ("noir", tr(L.colorModeNoir)),
            ], current: settings.videoColorMode) { settings.videoColorMode = $0 }

            groupHeader(tr(L.playerInfoGroup))
                .padding(.top, 18)
            toggleRow(tr(L.showClock), isOn: settings.playerShowClock) { settings.playerShowClock.toggle() }
            toggleRow(tr(L.showDate), isOn: settings.playerShowDate) { settings.playerShowDate.toggle() }
            toggleRow(tr(L.showPG), isOn: settings.playerShowPG) { settings.playerShowPG.toggle() }
            toggleRow(tr(L.showGenres), isOn: settings.playerShowGenres) { settings.playerShowGenres.toggle() }
            toggleRow(tr(L.showRatingStar), isOn: settings.playerShowRating) { settings.playerShowRating.toggle() }
            toggleRow(tr(L.showYearLabel), isOn: settings.playerShowYear) { settings.playerShowYear.toggle() }
            toggleRow(tr(L.showQuality), isOn: settings.playerShowQuality) { settings.playerShowQuality.toggle() }
            toggleRow(tr(L.showCurrentAudio), isOn: settings.playerShowAudio) { settings.playerShowAudio.toggle() }
            toggleRow(tr(L.showCurrentSubtitle), isOn: settings.playerShowSubtitle) { settings.playerShowSubtitle.toggle() }
            toggleRow(tr(L.suggestNextEpisode), isOn: settings.autoNextEpisode) { settings.autoNextEpisode.toggle() }

            groupHeader(tr(L.audioGroup))
                .padding(.top, 18)
            toggleRow(tr(L.passthroughLabel), isOn: settings.audioPassthrough) { settings.audioPassthrough.toggle() }
            Text(tr(L.passthroughHint))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .fullScreenCover(isPresented: $showAudioPicker) {
            LanguagePicker(title: tr(L.audioLanguage), specialLabel: tr(L.original), specialValue: "auto", current: settings.audioLang) {
                settings.audioLang = $0
            }
        }
        .fullScreenCover(isPresented: $showSubtitlePicker) {
            LanguagePicker(title: tr(L.subtitleLanguage), specialLabel: tr(L.subtitlesOff), specialValue: "off", current: settings.subtitleLang) {
                settings.subtitleLang = $0
            }
        }
    }

    /// Compact row that shows the current language and opens a full-screen picker.
    private func languageSelectorRow(current: String, special: String, specialValue: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(current == specialValue ? special : Languages.name(current))
                    .font(.callout)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .buttonStyle(DetailRowStyle())
    }

    // MARK: External services (all unified: Plex, torrents, subtitles, TMDB)

    private var servicesDetail: some View {
        VStack(alignment: .leading, spacing: 44) {
            serversDetail
            sectionDivider
            discoverDetail
            sectionDivider
            subtitlesServiceDetail
            sectionDivider
            communityDetail
            sectionDivider
            metadataDetail
        }
    }

    /// Trakt — community comments (read-only, phase 1). Account login (rate /
    /// comment, per user) comes in phase 2 via the device-code QR flow.
    private var communityDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupHeader(tr(L.traktSection))
            Text(tr(L.traktHint))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            fieldLabel(tr(L.traktClientID))
            TextField("••••••••", text: $traktIDInput)
                .frame(maxWidth: 560)
            // Client Secret — only needed to connect an account.
            fieldLabel(tr(L.traktClientSecret))
            SecureField("••••••••", text: $traktSecretInput)
                .frame(maxWidth: 560)
            // One Save for the whole service config; empty fields are left as-is.
            HStack(spacing: 16) {
                Button(tr(L.save)) {
                    let id = traktIDInput.trimmingCharacters(in: .whitespaces)
                    let secret = traktSecretInput.trimmingCharacters(in: .whitespaces)
                    if !id.isEmpty { settings.saveTraktClientID(id) }
                    if !secret.isEmpty { settings.saveTraktClientSecret(secret) }
                    traktIDInput = ""
                    traktSecretInput = ""
                    traktLink.refresh()
                    objectWillChangeTick.toggle()
                }
                .buttonStyle(SecondaryButtonStyle())
                if settings.traktReady {
                    Label(tr(L.tmdbConfigured), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green.opacity(0.85))
                }
            }
            .padding(.top, 4)

            // Per-user account connection (device-code, like plex.tv/link).
            traktConnectBlock
        }
    }

    @ViewBuilder
    private var traktConnectBlock: some View {
        Divider().overlay(.white.opacity(0.08)).frame(maxWidth: 700).padding(.vertical, 6)
        Text(tr(L.traktConnectPerUser))
            .font(.caption).foregroundStyle(.white.opacity(0.5))

        if let dc = traktLink.deviceCode {
            // Active device-code flow: QR + code, polling.
            HStack(alignment: .top, spacing: 24) {
                QRCodeView(content: dc.verificationURL)
                    .frame(width: 180, height: 180)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .padding(6)
                VStack(alignment: .leading, spacing: 10) {
                    Text(trf(L.traktLinkScan, dc.verificationURL))
                        .font(.callout).foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dc.userCode)
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .kerning(4)
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(tr(L.traktConnecting)).foregroundStyle(.white.opacity(0.6))
                    }
                    .font(.callout)
                    Button(tr(L.cancel)) { traktLink.cancel() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.top, 4)
        } else if traktLink.linked {
            HStack(spacing: 14) {
                Label(tr(L.traktConnected), systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green.opacity(0.9))
                Spacer()
                Button(role: .destructive) { traktLink.unlink() } label: {
                    Label(tr(L.traktDisconnect), systemImage: "person.crop.circle.badge.xmark")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: 700)
        } else {
            Button { traktLink.startLink() } label: {
                Label(tr(L.traktConnect), systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!traktLink.canLink)
            if !traktLink.canLink {
                Text(tr(L.traktNeedsSecret)).font(.caption).foregroundStyle(.orange.opacity(0.85))
            }
        }
        if let err = traktLink.error {
            Text(err).font(.caption).foregroundStyle(.red.opacity(0.85))
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(maxWidth: 900)
            .frame(height: 1)
    }

    // OpenSubtitles: external subtitle service.
    private var subtitlesServiceDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupHeader(tr(L.openSubtitlesSection))
            Text(tr(L.osHint))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            fieldLabel(tr(L.osApiKey))
            HStack(spacing: 16) {
                TextField("••••••••", text: $osKeyInput)
                    .frame(maxWidth: 560)
                Button(tr(L.save)) {
                    settings.saveOpenSubtitlesKey(osKeyInput.trimmingCharacters(in: .whitespaces))
                    osKeyInput = ""
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            fieldLabel(tr(L.osUsername))
            TextField(tr(L.osUsername), text: $settings.openSubtitlesUser)
                .frame(maxWidth: 560)
            fieldLabel(tr(L.osPassword))
            HStack(spacing: 16) {
                SecureField("••••••••", text: $osPassInput)
                    .frame(maxWidth: 560)
                Button(tr(L.save)) {
                    settings.saveOpenSubtitlesPass(osPassInput)
                    osPassInput = ""
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            HStack(spacing: 18) {
                osStatusChip(label: tr(L.osApiKey), ok: settings.openSubtitlesKey != nil)
                osStatusChip(label: tr(L.osUsername), ok: !settings.openSubtitlesUser.isEmpty)
                osStatusChip(label: tr(L.osPassword), ok: settings.openSubtitlesPass != nil)
            }
            .padding(.top, 4)
            if settings.openSubtitlesReady {
                Label(tr(L.tmdbConfigured), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green.opacity(0.85))
            }
            testRow(id: "opensubtitles") { await OpenSubtitlesClient.testConnection() }
        }
    }

    private func osStatusChip(label: String, ok: Bool) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "circle")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ok ? .green.opacity(0.85) : .white.opacity(0.4))
    }

    private func toggleRow(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(label)
                    .font(.callout)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(isOn ? Theme.accent : .white.opacity(0.3))
            }
        }
        .buttonStyle(DetailRowStyle())
    }

    // MARK: Servers

    private var serversDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupHeader(tr(L.serversTitle))

            ForEach(settings.servers) { server in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Circle().fill(.green).frame(width: 10, height: 10)
                        Text(server.name)
                            .font(.callout.weight(.semibold))
                        Text(server.isLocal ? tr(L.localNetwork) : tr(L.remote))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background((server.isLocal ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                            .foregroundStyle(server.isLocal ? .green : .orange)
                        Spacer()
                        if settings.servers.count > 1 {
                            Button(tr(L.removeServer)) {
                                settings.removeServer(id: server.id)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }

                    HStack(spacing: 16) {
                        Button {
                            runSpeedTest(server)
                        } label: {
                            if speedTesting.contains(server.id) {
                                HStack(spacing: 10) { ProgressView(); Text(tr(L.speedTesting)) }
                            } else {
                                Label(tr(L.speedTest), systemImage: "gauge.with.dots.needle.67percent")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(speedTesting.contains(server.id))

                        if let result = speedResults[server.id] {
                            Text(result)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(speedColor(server.id))
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }

            if addingServer {
                if discoveredServers.isEmpty {
                    HStack(spacing: 12) {
                        if !discoverySearched { ProgressView() }
                        Text(tr(discoverySearched ? L.noNewServers : L.searchingNewServers))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(discoveredServers) { candidate in
                        Button {
                            settings.addServer(
                                PlexServerRef(id: candidate.serverID, name: candidate.name, url: candidate.baseURL, isLocal: candidate.isLocal),
                                token: candidate.token
                            )
                            addingServer = false
                            discoveredServers = []
                            Task { await SyncEngine.shared.sync() }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Theme.accent)
                                Text(candidate.name).bold()
                                Text(candidate.displayAddress)
                                    .foregroundStyle(.white.opacity(0.4))
                                Spacer()
                            }
                            .font(.callout)
                        }
                        .buttonStyle(DetailRowStyle())
                    }
                }
            }

            HStack(spacing: 18) {
                Button {
                    discoverMoreServers()
                } label: {
                    Label(tr(L.addServer), systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    Task { await SyncEngine.shared.sync() }
                } label: {
                    if case .syncing(let detailText) = syncStatus.phase {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("\(tr(L.syncingLibrary)) \(detailText)…")
                        }
                    } else {
                        Label(tr(L.syncNow), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())

                Button(role: .destructive) {
                    // Deletes servers + account token and returns to onboarding
                    // to re-link (useful if the tokens became orphaned).
                    settings.resetPlex()
                } label: {
                    Label(tr(L.relinkPlex), systemImage: "arrow.triangle.2.circlepath.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 6)

            if case .failed = syncStatus.phase {
                HStack(spacing: 10) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(tr(L.syncFailedLabel))
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                }
            }

            HStack(spacing: 8) {
                Text("\(tr(L.lastSync)):")
                if let date = syncStatus.lastSyncAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text(tr(L.never))
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: Streaming Mode (external torrent source)

    private var discoverDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            groupHeader(tr(L.discoverSection))

            Text(tr(L.discoverDisclaimer))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            toggleRow(tr(L.enableDiscover), isOn: settings.streamingModeEnabled) {
                settings.streamingModeEnabled.toggle()
            }

            if settings.streamingModeEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel(tr(L.prowlarrURLLabel))
                    TextField("http://192.168.1.10:9696", text: $settings.prowlarrURL)
                        .frame(maxWidth: 760)
                    fieldLabel(tr(L.prowlarrKeyLabel))
                    TextField("a1b2c3…", text: $prowlarrKeyInput)
                        .frame(maxWidth: 760)
                        // Preloads the saved value so it doesn't look empty on return.
                        .onAppear {
                            if prowlarrKeyInput.isEmpty, let saved = settings.prowlarrKey {
                                prowlarrKeyInput = saved
                            }
                        }
                        // Auto-saved like the URLs: doesn't rely on a separate button.
                        .onChange(of: prowlarrKeyInput) { _, newValue in
                            settings.saveProwlarrKey(newValue)
                        }
                    if !prowlarrKeyInput.isEmpty {
                        Label(tr(L.tmdbConfigured), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.85))
                    }
                    fieldLabel(tr(L.torrServerURLLabel))
                    TextField("http://192.168.1.10:8090", text: $settings.torrServerURL)
                        .frame(maxWidth: 760)

                    testRow(id: "prowlarr") { await ProwlarrClient.testConnection() }
                    testRow(id: "torrserver") { await TorrServerClient.testConnection() }

                    toggleRow(tr(L.autoBestSource), isOn: settings.autoBestSource) {
                        settings.autoBestSource.toggle()
                    }
                    Text(tr(L.autoBestSourceHint))
                        .font(.caption).foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 6)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 8)
    }

    // MARK: Artificial Intelligence (OpenAI-compatible providers)

    private var aiDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupHeader(tr(L.aiSection))
            Text(tr(L.aiIntro))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow.opacity(0.85))
                Text(tr(L.aiModelTip))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            inlineChoices(tr(L.aiProviderLabel), options: [
                ("openai", "OpenAI"), ("gemini", "Gemini"), ("groq", "Groq"),
                ("openrouter", "OpenRouter"), ("anthropic", "Anthropic"),
                ("custom", tr(L.aiProviderCustom)),
            ], current: settings.aiProvider) {
                settings.aiProvider = $0
                aiModels = []
                aiModelsError = false
            }

            if settings.aiProvider == "custom" {
                fieldLabel(tr(L.aiBaseURLLabel))
                TextField("http://192.168.1.10:11434/v1", text: $settings.aiBaseURL)
                    .frame(maxWidth: 760)
            }

            // 1) API key, then validate (which lists the accessible models).
            fieldLabel(tr(L.aiKeyLabel))
            HStack(spacing: 16) {
                TextField("sk-…", text: $aiKeyInput)
                    .frame(maxWidth: 520)
                    .onAppear { if aiKeyInput.isEmpty, let k = settings.aiKey { aiKeyInput = k } }
                Button {
                    settings.saveAIKey(aiKeyInput)
                    loadAIModels()
                } label: {
                    if aiModelsLoading {
                        HStack(spacing: 10) { ProgressView(); Text(tr(L.aiModelsLoading)) }
                    } else {
                        Label(tr(L.aiValidate), systemImage: "checkmark.seal")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(aiModelsLoading)
                if settings.aiKey != nil {
                    Button(tr(L.delete)) {
                        settings.saveAIKey(""); aiKeyInput = ""; aiModels = []; aiModelsError = false
                        objectWillChangeTick.toggle()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if aiModelsError {
                Text(tr(L.aiModelsError))
                    .font(.caption).foregroundStyle(.orange.opacity(0.9))
            }

            // 2) Model list (only the ones the key can access).
            if !aiModels.isEmpty {
                Label(trf(L.aiKeyValid, aiModels.count), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green.opacity(0.85))
                    .padding(.top, 2)
                fieldLabel(tr(L.aiModelLabel))
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(aiModels, id: \.self) { model in
                            choiceRow(model, selected: settings.aiModel == model) { settings.aiModel = model }
                        }
                    }
                }
                .frame(maxHeight: 360)
            } else if !settings.aiModel.isEmpty && !aiModelsLoading {
                // Previously chosen model (persisted) — validate to change it.
                fieldLabel(tr(L.aiModelLabel))
                Text(settings.aiModel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }

            if settings.aiReady {
                Label(tr(L.tmdbConfigured), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green.opacity(0.85))
                    .padding(.top, 6)
            }
        }
    }

    private func loadAIModels() {
        aiModelsError = false
        aiModelsLoading = true
        aiModels = []
        let config = AIService.Config(
            baseURL: AIService.providerBaseURL(settings.aiProvider, custom: settings.aiBaseURL),
            apiKey: settings.aiKey,
            model: settings.aiModel
        )
        Task {
            let models = await AIService.listModels(config: config)
            aiModelsLoading = false
            if let models { aiModels = models } else { aiModelsError = true }
        }
    }

    // MARK: TMDB

    private var metadataDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupHeader(tr(L.metadataSection))

            HStack(spacing: 12) {
                Circle()
                    .fill(settings.hasTMDB ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text(settings.hasTMDB ? tr(L.tmdbConfigured) : tr(L.tmdbNotConfigured))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

            // Input always available: allows configuring or updating the API key.
            fieldLabel(settings.hasTMDB ? tr(L.tmdbUpdateKey) : tr(L.tmdbApiKey))
            HStack(spacing: 18) {
                TextField(tr(L.tmdbPlaceholder), text: $tmdbKeyInput)
                    .frame(maxWidth: 640)
                Button(tr(L.save)) {
                    let key = tmdbKeyInput.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return }
                    tmdbSaving = true
                    tmdbError = nil
                    Task {
                        if await TMDBClient.validate(key: key) {
                            settings.saveTMDBKey(key)
                            tmdbKeyInput = ""
                            tmdbSaving = false
                            await TMDBEnricher.shared.enrichAll()
                        } else {
                            tmdbError = tr(L.tmdbInvalidKey)
                            tmdbSaving = false
                        }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(tmdbSaving || tmdbKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if tmdbSaving { ProgressView() }
            }
            if let tmdbError {
                Text(tmdbError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            testRow(id: "tmdb") { await TMDBClient.testConnection() }
        }
    }

    // MARK: System

    private var systemDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupHeader(tr(L.systemSection))

            // Perfiles de la app (¿quién está viendo? / crear / personalizar).
            Button {
                ProfileStore.shared.requestSelection()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.2.fill").foregroundStyle(Theme.accent)
                    Text(tr(L.profileSwitch))
                    Spacer()
                    Text(ProfileStore.shared.current.name).foregroundStyle(.white.opacity(0.5))
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.35))
                }
                .font(.callout)
            }
            .buttonStyle(DetailRowStyle())

            // Subir una "foto" completa de este Apple TV a iCloud, manualmente y con
            // confirmación. La sync normal ya es automática por evento; esto es un
            // respaldo de seguridad para empujarlo TODO de una, con feedback en vivo.
            // Solo con iCloud disponible (build de pago + sesión iCloud). En el build
            // gratis el estado es .disabled → el botón no aparece (no haría nada).
            if iCloudSync.status == .active || iCloudSync.status == .syncing {
                Button { confirmPushProfiles = true } label: {
                    HStack(spacing: 14) {
                        if iCloudSync.isPushingAll {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Image(systemName: "icloud.and.arrow.up.fill").foregroundStyle(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr(L.profilePushTitle))
                            Text(iCloudSync.pushAllStatus ?? tr(L.profilePushHint))
                                .font(.caption)
                                .foregroundStyle(iCloudSync.pushAllStatus != nil ? Theme.accent : .white.opacity(0.5))
                        }
                        Spacer()
                    }
                    .font(.callout)
                }
                .buttonStyle(DetailRowStyle())
                .disabled(iCloudSync.isPushingAll)
                .alert(tr(L.profilePushConfirm), isPresented: $confirmPushProfiles) {
                    Button(tr(L.profileSave)) {
                        Task { await SyncCoordinator.shared.uploadAllToCloud() }
                    }
                    Button(tr(L.profileCancel), role: .cancel) {}
                } message: {
                    Text(tr(L.profilePushHint))
                }
            }

            HStack(spacing: 8) {
                Text("\(tr(L.appVersion)):")
                    .foregroundStyle(.white.opacity(0.5))
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.white.opacity(0.85))
            }
            .font(.callout)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

            // Cross-device sync status (iCloud).
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(.white.opacity(0.6))
                    Text(tr(L.syncTitle))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(iCloudSync.statusText)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let last = iCloudSync.lastSyncAt {
                    Text(trf(L.syncLastAt, last.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                if iCloudSync.status == .active || iCloudSync.status == .syncing {
                    Button {
                        Task { await SyncCoordinator.shared.syncNow() }
                    } label: {
                        Label(tr(L.syncNow), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Label(tr(L.syncPerUserHint), systemImage: "person.2.badge.key")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 2)
                }
            }
            .font(.callout)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

            // Licenses and attributions (legal requirement of TMDB and LGPL).
            Text(tr(L.licensesTitle).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.2)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 14) {
                // TMDB attribution (text required by its license, always in English).
                HStack(spacing: 14) {
                    Text("TMDB")
                        .font(.callout.weight(.black))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.06, green: 0.83, blue: 0.62), Color(red: 0.03, green: 0.71, blue: 0.88)],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(.white)
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text(tr(L.licensesIntro))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 4)

                ForEach(Self.licenses, id: \.0) { name, license, url in
                    HStack(spacing: 12) {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 200, alignment: .leading)
                        Text(license)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(.white.opacity(0.7))
                        Text(url)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                        Spacer()
                    }
                }

                Text(tr(L.independenceDisclaimer))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(22)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 900)

            Button(role: .destructive) {
                settings.reset()
            } label: {
                Label(tr(L.resetAll), systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 8)
        }
    }

    private static let licenses: [(String, String, String)] = [
        ("mpv / libmpv", "LGPL-2.1+", "mpv.io"),
        ("FFmpeg", "LGPL-2.1+", "ffmpeg.org"),
        ("libplacebo", "LGPL-2.1", "libplacebo.org"),
        ("libass", "ISC", "github.com/libass/libass"),
        ("MoltenVK", "Apache-2.0", "github.com/KhronosGroup/MoltenVK"),
        ("dav1d", "BSD-2-Clause", "code.videolan.org/videolan/dav1d"),
        ("MPVKit", "LGPL-2.1", "github.com/mpvkit/MPVKit"),
        ("GRDB.swift", "MIT", "github.com/groue/GRDB.swift"),
    ]

    // MARK: Components

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.45))
            .kerning(1.2)
    }

    private func choiceRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(label)
                    .font(.callout)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
            }
        }
        .buttonStyle(DetailRowStyle())
    }

    private func inlineChoices(
        _ title: String,
        options: [(String, String)],
        current: String,
        onPick: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 150, alignment: .leading)
            ForEach(options, id: \.0) { value, label in
                Button {
                    onPick(value)
                } label: {
                    HStack(spacing: 6) {
                        if current == value {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                        Text(label)
                            .font(.caption)
                    }
                }
                .buttonStyle(ChipStyle(selected: current == value))
            }
            Spacer()
        }
    }

    private func discoverMoreServers() {
        guard let accountToken = settings.plexAccountToken else { return }
        addingServer = true
        discoverySearched = false
        discoveredServers = []
        Task {
            let resources = (try? await PlexClient.fetchResources(accountToken: accountToken)) ?? []
            var found: [ResolvedServer] = []
            await withTaskGroup(of: ResolvedServer?.self) { group in
                for resource in resources {
                    group.addTask { await PlexClient.resolve(resource: resource, accountToken: accountToken) }
                }
                for await server in group {
                    if let server { found.append(server) }
                }
            }
            let existing = Set(settings.servers.map(\.id))
            discoveredServers = found.filter { !existing.contains($0.serverID) }
            discoverySearched = true
        }
    }
}

// MARK: - Language picker (full-screen list)

private struct LanguagePicker: View {
    let title: String
    let specialLabel: String
    let specialValue: String
    let current: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 80)
                    .padding(.top, 60)
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        row(label: specialLabel, value: specialValue)
                        ForEach(Languages.allCodes, id: \.self) { code in
                            row(label: Languages.name(code), value: code)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 60)
                }
                .scrollClipDisabled()
            }
        }
        .onExitCommand { dismiss() }
        .onAppear { focus = current }
    }

    private func row(label: String, value: String) -> some View {
        Button {
            onPick(value)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Text(label).font(.callout)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(current == value ? 1 : 0)
            }
            .frame(maxWidth: 700, alignment: .leading)
        }
        .buttonStyle(DetailRowStyle())
        .focused($focus, equals: value)
    }
}

// MARK: - Styles

/// Minimalist sidebar row: icon + label always visible, flat and compact.
/// A clean highlight on focus and a subtle one for the selected section.
private struct SidebarRowStyle: ButtonStyle {
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
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 26)
                Text(label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(focused ? .black : .white.opacity(selected ? 0.95 : 0.55))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(focused ? Color.white : (selected ? Color.white.opacity(0.12) : .clear))
            )
            .scaleEffect(focused ? 1.03 : 1.0)
            .animation(.smooth(duration: 0.16), value: focused)
        }
    }
}

private struct DetailRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration

        var body: some View {
            configuration.label
                .padding(.horizontal, 22)
                .padding(.vertical, 15)
                .frame(maxWidth: 760, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(focused ? Color.white.opacity(0.22) : Color.white.opacity(0.05))
                )
                .foregroundColor(.white.opacity(focused ? 1 : 0.8))
                .scaleEffect(focused ? 1.01 : 1.0)
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}

private struct ChipStyle: ButtonStyle {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(focused ? Color.white : (selected ? Color.white.opacity(0.2) : Color.white.opacity(0.06)))
                )
                .foregroundColor(focused ? .black : .white.opacity(selected ? 1 : 0.6))
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}

// MARK: - Parental controls

private struct ParentalSection: View {
    @ObservedObject private var parental = ParentalStore.shared
    @State private var pinInput = ""
    @State private var newPin = ""
    @State private var unlocked = false
    @State private var wrongPin = false
    @State private var pendingLevel = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr(L.parentalTitle).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.2)

            // Locked: a PIN exists and it hasn't been unlocked this session.
            if parental.hasPin && !unlocked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle().fill(.green).frame(width: 10, height: 10)
                        Text(tr(L.parentalActive))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Label("\(tr(L.parentalMaxRating)): \(levelName(parental.config?.maxLevel ?? 3))",
                          systemImage: "lock.shield.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.accentSoft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 18) {
                    TextField(tr(L.parentalEnterPin), text: $pinInput)
                        .frame(maxWidth: 360)
                    Button(tr(L.parentalUnlock)) {
                        if parental.verify(pin: pinInput) { unlocked = true; wrongPin = false }
                        else { wrongPin = true }
                        pinInput = ""
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if wrongPin {
                    Text(tr(L.parentalWrongPin)).font(.callout).foregroundStyle(.red.opacity(0.9))
                }
            } else {
                // Editable: choosing a level applies the filter instantly (PIN optional).
                Text(tr(L.parentalHint))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: 860, alignment: .leading)
                levelPicker(current: parental.config?.maxLevel ?? 3) { parental.setLevel($0) }

                // Optional PIN to protect the setting (only if a restriction is active).
                if (parental.config?.maxLevel ?? 3) < 3 {
                    fieldLabel(parental.hasPin ? tr(L.parentalChangePin) : tr(L.parentalOptionalPin))
                    HStack(spacing: 18) {
                        TextField(tr(L.parentalSetPin), text: $newPin)
                            .frame(maxWidth: 360)
                        Button(tr(L.save)) {
                            parental.setPin(newPin)
                            newPin = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(newPin.trimmingCharacters(in: .whitespaces).isEmpty)
                        if parental.hasPin {
                            Button(tr(L.parentalRemovePin)) { parental.setPin("") }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
    }

    private func levelName(_ level: Int) -> String {
        switch level {
        case 0: return tr(L.ratingKids)
        case 1: return tr(L.rating7)
        case 2: return tr(L.rating13)
        default: return tr(L.ratingAll)
        }
    }

    private func levelPicker(current: Int, onPick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr(L.parentalMaxRating))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 14) {
                levelChip(0, label: tr(L.ratingKids), current: current, onPick: onPick)
                levelChip(1, label: tr(L.rating7), current: current, onPick: onPick)
                levelChip(2, label: tr(L.rating13), current: current, onPick: onPick)
                levelChip(3, label: tr(L.ratingAll), current: current, onPick: onPick)
            }
        }
    }

    private func levelChip(_ level: Int, label: String, current: Int, onPick: @escaping (Int) -> Void) -> some View {
        Button {
            onPick(level)
        } label: {
            HStack(spacing: 6) {
                if current == level {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(label)
                    .font(.caption)
            }
        }
        .buttonStyle(ChipStyle(selected: current == level))
    }
}


// MARK: - Storage

private struct StorageDetail: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var cacheBytes: Int64 = 0
    @State private var dbBytes: Int64 = 0
    @State private var purging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr(L.storageSection).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.2)

            usageRow(icon: "photo.stack", label: tr(L.imageCacheLabel), bytes: cacheBytes)
            usageRow(icon: "cylinder.split.1x2", label: tr(L.databaseLabel), bytes: dbBytes)

            // Cache limit.
            HStack(spacing: 14) {
                Text(tr(L.cacheLimitLabel))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 220, alignment: .leading)
                limitChip(1, label: "1 GB")
                limitChip(2, label: "2 GB")
                limitChip(5, label: "5 GB")
                limitChip(0, label: tr(L.unlimited))
                Spacer()
            }
            .padding(.top, 6)

            Button {
                guard !purging else { return }
                purging = true
                Task {
                    await ImageCache.shared.purgeAll()
                    ImageMemoryCache.clear()
                    cacheBytes = await ImageCache.shared.totalSizeBytes()
                    purging = false
                }
            } label: {
                if purging {
                    HStack(spacing: 12) { ProgressView(); Text(tr(L.clearCache)) }
                } else {
                    Label(tr(L.clearCache), systemImage: "trash")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 8)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        cacheBytes = await ImageCache.shared.totalSizeBytes()
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dbPath = caches.appendingPathComponent("lumoratv.sqlite").path
            dbBytes = Int64((try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0)
        }
    }

    private func usageRow(icon: String, label: String, bytes: Int64) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 40)
            Text(label)
                .font(.callout)
            Spacer()
            Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) \(tr(L.inUse))")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .frame(maxWidth: 760)
    }

    private func limitChip(_ value: Int, label: String) -> some View {
        Button {
            settings.cacheLimitGB = value
            if value > 0 {
                Task {
                    await ImageCache.shared.enforceLimit(maxBytes: Int64(value) * 1_073_741_824)
                    cacheBytes = await ImageCache.shared.totalSizeBytes()
                }
            }
        } label: {
            HStack(spacing: 6) {
                if settings.cacheLimitGB == value {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(label)
                    .font(.caption)
            }
        }
        .buttonStyle(SettingsChipStyle(selected: settings.cacheLimitGB == value))
    }
}

private struct SettingsChipStyle: ButtonStyle {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(focused ? Color.white : (selected ? Color.white.opacity(0.2) : Color.white.opacity(0.06)))
                )
                .foregroundColor(focused ? .black : .white.opacity(selected ? 1 : 0.6))
                .animation(.smooth(duration: 0.15), value: focused)
        }
    }
}

// MARK: - Smart Data (learned reputation)

/// Visualizes what the app has learned from real viewing behavior — the
/// indexer reputation and uploader (release group) scores that feed the
/// "best source" ranking — with a reset to start over.
private struct SmartDataSection: View {
    @State private var indexers: [(name: String, stats: IndexerReputation.Stats)] = []
    @State private var uploaders: [(name: String, stats: UploaderReputation.Stats)] = []
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(tr(L.smartDataSection))
            Text(tr(L.smartDataIntro))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            if indexers.isEmpty && uploaders.isEmpty {
                Label(tr(L.smartDataEmpty), systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 16)
            }

            if !indexers.isEmpty {
                header(tr(L.smartDataIndexers))
                    .padding(.top, 12)
                ForEach(indexers, id: \.name) { row in
                    scoreRow(
                        name: row.name,
                        score: IndexerReputation.score(indexer: row.name),
                        detail: trf(L.smartDataPlaybackStats, row.stats.loads, row.stats.completions, row.stats.failures)
                    )
                }
            }

            if !uploaders.isEmpty {
                header(tr(L.smartDataUploaders))
                    .padding(.top, 18)
                ForEach(uploaders, id: \.name) { row in
                    scoreRow(
                        name: row.name.uppercased(),
                        score: UploaderReputation.score(uploader: row.name),
                        detail: trf(
                            L.smartDataUploaderStats,
                            row.stats.loads, row.stats.completions,
                            row.stats.subsUsed, row.stats.subsRescued,
                            row.stats.failures + row.stats.abandons
                        )
                    )
                }
            }

            Button {
                confirmReset = true
            } label: {
                Label(tr(L.smartDataReset), systemImage: "arrow.counterclockwise")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 22)
        }
        .onAppear(perform: reload)
        .alert(tr(L.smartDataResetTitle), isPresented: $confirmReset) {
            Button(tr(L.smartDataReset), role: .destructive) {
                IndexerReputation.reset()
                UploaderReputation.reset()
                reload()
            }
            Button(tr(L.cancel), role: .cancel) {}
        } message: {
            Text(tr(L.smartDataResetMessage))
        }
    }

    private func reload() {
        indexers = IndexerReputation.allStats()
            .map { (name: $0.key, stats: $0.value) }
            .sorted { IndexerReputation.score(indexer: $0.name) > IndexerReputation.score(indexer: $1.name) }
        uploaders = UploaderReputation.allStats()
            .map { (name: $0.key, stats: $0.value) }
            .sorted { UploaderReputation.score(uploader: $0.name) > UploaderReputation.score(uploader: $1.name) }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.45))
            .kerning(1.2)
    }

    /// One learned entity: name, score bar (-1…+1 centered at neutral),
    /// signed score, and a compact stats line. A focusable row so the
    /// settings detail pane can scroll through long lists.
    private func scoreRow(name: String, score: Double, detail: String) -> some View {
        Button {} label: {
            HStack(spacing: 18) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: 250, alignment: .leading)

                scoreBar(score)
                    .frame(width: 190, height: 10)

                Text(String(format: "%+d", Int((score * 100).rounded())))
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(scoreColor(score))
                    .frame(width: 64, alignment: .trailing)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(DetailRowStyle())
    }

    /// Horizontal gauge: fill grows from the center — right for positive
    /// reputation, left for negative.
    private func scoreBar(_ score: Double) -> some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Rectangle()
                    .fill(scoreColor(score))
                    .frame(width: max(3, half * abs(score)))
                    .offset(x: score >= 0 ? half : half - half * abs(score))
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 2)
                    .offset(x: half - 1)
            }
            .clipShape(Capsule())
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        if score > 0.08 { return .green }
        if score < -0.08 { return .orange }
        return .white.opacity(0.55)
    }
}
