import Foundation

/// Device-wide app configuration shared by ALL Apple TV users (not per-user).
/// Backed by the **user-independent keychain** (the documented tvOS mechanism for
/// data every user on the device must see identically). Used for the "service"
/// config: Plex server list, service URLs, streaming mode, cache limit, onboarding
/// completion. Secrets (API keys/tokens) go through `Keychain.setSecret` directly.
///
/// On the non-iCloud (free) build there's no per-user partitioning, so this still
/// works (user-independent flag is simply ignored / behaves as the normal keychain).
enum GlobalStore {
    static func string(_ key: String) -> String? { Keychain.getSecret(key) }
    static func setString(_ value: String, _ key: String) { Keychain.setSecret(value, for: key) }

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let v = Keychain.getSecret(key) else { return fallback }
        return v == "1"
    }
    static func setBool(_ value: Bool, _ key: String) { Keychain.setSecret(value ? "1" : "0", for: key) }

    static func int(_ key: String, default fallback: Int) -> Int {
        Keychain.getSecret(key).flatMap(Int.init) ?? fallback
    }
    static func setInt(_ value: Int, _ key: String) { Keychain.setSecret(String(value), for: key) }

    static func data(_ key: String) -> Data? { Keychain.getSecretData(key) }
    static func setData(_ value: Data, _ key: String) { Keychain.setSecretData(value, for: key) }
    static func remove(_ key: String) { Keychain.deleteSecret(key) }
}
