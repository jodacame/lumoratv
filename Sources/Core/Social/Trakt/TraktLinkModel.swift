import Foundation

/// Drives the per-user Trakt device-code login (phase 2), like plex.tv/link.
/// The SERVICE config (Client ID/Secret) is global; the resulting token is stored
/// per Apple TV user (`UserContext.currentUserID`).
@MainActor
final class TraktLinkModel: ObservableObject {
    @Published var linked = false
    @Published var linking = false
    @Published var deviceCode: TraktDeviceCode?
    @Published var error: String?
    /// Whether the global service credentials (Client ID + Secret) are present.
    /// Published so Settings reacts immediately after saving the keys.
    @Published var canLink = false

    private var pollTask: Task<Void, Never>?

    init() { refresh() }

    /// Re-reads credential/auth state. Call after saving the Client ID/Secret.
    func refresh() {
        linked = TraktAuth.isAuthorized(userID: UserContext.currentUserID)
        canLink = SettingsStore.shared.traktReady
            && (SettingsStore.shared.traktClientSecret?.isEmpty == false)
    }

    func startLink() {
        guard !linking, canLink else { return }
        error = nil
        linking = true
        let userID = UserContext.currentUserID
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            guard let dc = await TraktAuth.requestDeviceCode() else {
                self.error = tr(L.traktLinkError)
                self.linking = false
                return
            }
            self.deviceCode = dc
            let ok = await TraktAuth.pollForToken(dc, userID: userID)
            self.deviceCode = nil
            self.linking = false
            self.linked = ok
            if ok {
                TraktSync.pullWatchlist(userID: userID)   // bring the Trakt watchlist in
            } else {
                self.error = tr(L.traktLinkError)
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        deviceCode = nil
        linking = false
    }

    func unlink() {
        TraktAuth.signOut(userID: UserContext.currentUserID)
        refresh()
    }
}
