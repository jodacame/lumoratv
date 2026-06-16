import Foundation

/// Trakt OAuth **device-code** flow (phase 2) + per-user token storage.
///
/// Reading comments needs no auth; rating/commenting/scrobbling does. Each Apple
/// TV user has their OWN Trakt integration — tokens are keyed by `userID` in the
/// per-user Keychain (device-local) and, on the iCloud build, sync **encrypted**
/// across that person's Apple TVs via CloudKit, so the login follows the user.
///
/// Not wired to UI yet; the player/Settings call these in phase 2 (QR login,
/// like plex.tv/link).
enum TraktAuth {

    // MARK: - Token storage (per user)

    private static func tokenKey(_ userID: String) -> String { "traktTokens-\(userID)" }

    static func tokens(for userID: String) -> TraktTokens? {
        guard let data = Keychain.getData(tokenKey(userID)) else { return nil }
        return try? JSONDecoder().decode(TraktTokens.self, from: data)
    }

    private static func store(_ tokens: TraktTokens, for userID: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        Keychain.setData(data, for: tokenKey(userID))
        Task { @MainActor in SyncCoordinator.shared.enqueue(.traktToken(userID: userID)) }
    }

    static func signOut(userID: String) {
        Keychain.delete(tokenKey(userID))
        Task { @MainActor in SyncCoordinator.shared.enqueue(.traktToken(userID: userID)) }
    }
    static func isAuthorized(userID: String) -> Bool { tokens(for: userID) != nil }

    // MARK: - Credentials (Client ID + Secret from Settings)

    @MainActor private static func creds() -> (id: String, secret: String)? {
        let s = SettingsStore.shared
        guard let id = s.traktClientID, !id.isEmpty,
              let secret = s.traktClientSecret, !secret.isEmpty else { return nil }
        return (id, secret)
    }

    // MARK: - Device-code flow

    /// Step 1 — request a device code. Show `userCode` + a QR of `verificationURL`.
    static func requestDeviceCode() async -> TraktDeviceCode? {
        guard let (id, _) = await MainActor.run(body: { creds() }) else { return nil }
        struct R: Decodable {
            let device_code: String; let user_code: String
            let verification_url: String; let interval: Int; let expires_in: Int
        }
        guard let (data, code) = await TraktHTTP.postRaw("/oauth/device/code",
                                                         json: ["client_id": id], clientID: id),
              code == 200, let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        return TraktDeviceCode(deviceCode: r.device_code, userCode: r.user_code,
                               verificationURL: r.verification_url, interval: r.interval,
                               expiresIn: r.expires_in)
    }

    /// Step 2 — poll until the user approves (or the code expires). On success the
    /// tokens are stored for `userID`. Returns whether authorization completed.
    static func pollForToken(_ dc: TraktDeviceCode, userID: String) async -> Bool {
        guard let (id, secret) = await MainActor.run(body: { creds() }) else { return false }
        let deadline = Date().addingTimeInterval(Double(dc.expiresIn))
        struct R: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int }
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(max(dc.interval, 1)) * 1_000_000_000)
            let json: [String: Any] = ["code": dc.deviceCode, "client_id": id, "client_secret": secret]
            guard let (data, code) = await TraktHTTP.postRaw("/oauth/device/token", json: json, clientID: id) else { continue }
            if code == 200, let r = try? JSONDecoder().decode(R.self, from: data) {
                store(TraktTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                                  expiresAt: Date().addingTimeInterval(Double(r.expires_in))), for: userID)
                return true
            }
            if code != 400 { return false }   // 400 = still pending; anything else = stop
        }
        return false
    }

    /// A valid access token for the user, refreshing if expired. nil if not linked.
    static func accessToken(userID: String) async -> String? {
        guard let t = tokens(for: userID) else { return nil }
        if !t.isExpired { return t.accessToken }
        guard let refreshed = await refresh(t, userID: userID) else { signOut(userID: userID); return nil }
        return refreshed.accessToken
    }

    private static func refresh(_ tokens: TraktTokens, userID: String) async -> TraktTokens? {
        guard let (id, secret) = await MainActor.run(body: { creds() }) else { return nil }
        struct R: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int }
        let json: [String: Any] = [
            "refresh_token": tokens.refreshToken, "client_id": id,
            "client_secret": secret, "grant_type": "refresh_token",
        ]
        guard let (data, code) = await TraktHTTP.postRaw("/oauth/token", json: json, clientID: id),
              code == 200, let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        let new = TraktTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                              expiresAt: Date().addingTimeInterval(Double(r.expires_in)))
        store(new, for: userID)
        return new
    }
}
