import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Equatable {
        case welcome
        case plexChoice
        case plexLink
        case serverPick
        case manualConfig
        case tmdb
        case done
    }

    enum AsyncState: Equatable {
        case idle, working, failed(LString)
    }

    @Published var step: Step = .welcome

    // plex.tv/link
    @Published var pinCode: String?
    @Published var linkState: AsyncState = .idle

    // Server discovery
    @Published var servers: [ResolvedServer] = []
    @Published var discoveryState: AsyncState = .idle

    // Manual config
    @Published var manualState: AsyncState = .idle

    // TMDB
    @Published var tmdbState: AsyncState = .idle

    private var linkTask: Task<Void, Never>?
    private let settings = SettingsStore.shared

    deinit { linkTask?.cancel() }

    // MARK: plex.tv/link

    func beginPlexLink() {
        step = .plexLink
        pinCode = nil
        linkState = .working
        linkTask?.cancel()
        linkTask = Task {
            do {
                let pin = try await PlexClient.createPin()
                guard !Task.isCancelled else { return }
                pinCode = pin.code
                // The PIN lasts ~15 min; we poll every 2 s for 10 min.
                for _ in 0..<300 {
                    try await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    let check = try await PlexClient.checkPin(id: pin.id)
                    if let token = check.authToken, !token.isEmpty {
                        settings.saveAccountToken(token)
                        await discoverServers(accountToken: token)
                        return
                    }
                }
                linkState = .failed(L.errLinkExpired)
            } catch is CancellationError {
                // Cancelled by the user; no action.
            } catch {
                linkState = .failed(L.errPlexTv)
            }
        }
    }

    func cancelPlexLink() {
        linkTask?.cancel()
        linkState = .idle
        pinCode = nil
        step = .plexChoice
    }

    // MARK: Discovery

    func discoverServers(accountToken: String) async {
        step = .serverPick
        discoveryState = .working
        servers = []
        do {
            let resources = try await PlexClient.fetchResources(accountToken: accountToken)
            var found: [ResolvedServer] = []
            await withTaskGroup(of: ResolvedServer?.self) { group in
                for resource in resources {
                    group.addTask { await PlexClient.resolve(resource: resource, accountToken: accountToken) }
                }
                for await server in group {
                    if let server { found.append(server) }
                }
            }
            servers = found.sorted {
                if $0.isLocal != $1.isLocal { return $0.isLocal }
                return $0.name < $1.name
            }
            discoveryState = servers.isEmpty
                ? .failed(L.errNoServers)
                : .idle
        } catch {
            discoveryState = .failed(L.errResources)
        }
    }

    func retryDiscovery() {
        guard let token = settings.plexAccountToken else {
            step = .plexChoice
            return
        }
        Task { await discoverServers(accountToken: token) }
    }

    func select(server: ResolvedServer) {
        settings.addServer(
            PlexServerRef(id: server.serverID, name: server.name, url: server.baseURL, isLocal: server.isLocal),
            token: server.token
        )
        // The server is the last step (optional); TMDB was already configured earlier.
        step = .done
    }

    // MARK: Manual

    func connectManually(host: String, port: String, token: String) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            manualState = .failed(L.errHostRequired)
            return
        }
        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = "http://\(cleanHost):\(cleanPort.isEmpty ? "32400" : cleanPort)"
        manualState = .working
        Task {
            guard await PlexClient.isReachable(baseURL: baseURL, token: cleanToken) else {
                manualState = .failed(L.errManualConnect)
                return
            }
            let name = await PlexClient.serverName(baseURL: baseURL, token: cleanToken) ?? cleanHost
            manualState = .idle
            select(server: ResolvedServer(
                serverID: "manual-\(cleanHost)",
                name: name,
                baseURL: baseURL,
                displayAddress: "\(cleanHost):\(cleanPort.isEmpty ? "32400" : cleanPort)",
                token: cleanToken,
                isLocal: true,
                owned: true
            ))
        }
    }

    // MARK: TMDB

    // TMDB is REQUIRED (it organizes the catalog): on validation we advance to
    // the server step, which is optional.
    func validateTMDB(key: String) {
        tmdbState = .working
        Task {
            if await TMDBClient.validate(key: key) {
                settings.saveTMDBKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                tmdbState = .idle
                step = .plexChoice
            } else {
                tmdbState = .failed(L.errTmdbKey)
            }
        }
    }

    /// From the welcome screen: TMDB first (required); if it was already configured
    /// (e.g. after re-linking), skip straight to the server step.
    func beginOnboarding() {
        step = settings.hasTMDB ? .plexChoice : .tmdb
    }

    /// The server is optional: it can be skipped and connected later in Settings.
    func skipServer() {
        step = .done
    }

    func finish() {
        settings.completeOnboarding()
    }
}
