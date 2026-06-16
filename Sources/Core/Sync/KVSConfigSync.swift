import Foundation

#if LUMORA_ICLOUD
/// Espeja la configuración (Nivel 2) en NSUbiquitousKeyValueStore para que viaje
/// entre los dispositivos del MISMO usuario. Self-driven: observa cambios locales
/// (UserDefaults) y remotos (KVS) sin tocar los setters de SettingsStore.
///
/// Solo existe en el build iCloud; en cuenta gratis ni se compila.
@MainActor
final class KVSConfigSync: SyncProvider {
    nonisolated var name: String { "kvs-config" }

    private let store = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    /// True mientras aplicamos cambios remotos (evita rebote local→KVS).
    private var applyingRemote = false
    private var mirrorScheduled = false

    // DEVICE-WIDE personalization only. Personal audio/subtitle/HUD prefs are now
    // PER-PROFILE (synced via the CloudKit Prefs record, see SettingsStore), so they
    // are NOT mirrored here. What stays device-wide: app UI language, picture mode and
    // audio passthrough (the last two depend on this TV's panel/receiver). Global
    // service config (servers, URLs, keys…) lives in the user-independent keychain.
    static let stringKeys = ["videoColorMode", "appLanguage"]
    static let boolKeys = ["audioPassthrough"]
    static let intKeys: [String] = []
    static let dataKeys: [String] = []
    // Per-content audio/subtitle choices ([String:String], keyed userID|content).
    static let dictKeys = ["trackChoice.sub", "trackChoice.audio"]

    private var allKeys: [String] {
        Self.stringKeys + Self.boolKeys + Self.intKeys + Self.dataKeys + Self.dictKeys
    }

    func activate() {
        // App-lifetime observers (held by the SyncCoordinator singleton); no
        // teardown needed. `queue: .main` guarantees the main thread, so the
        // hop into MainActor isolation is valid.
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] note in
            let keys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            MainActor.assumeIsolated { self?.externalChanged(keys: keys) }
        }
        nc.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChanged() }
        }
        store.synchronize()
        reconcile()
    }

    // MARK: SyncProvider

    func push(_ change: SyncChange) async {
        if case .config = change { mirrorAll() }
    }

    func pull() async {
        store.synchronize()
        applyRemote(keys: allKeys)
    }

    /// Empuja lo pendiente a iCloud antes de pasar a segundo plano (la app se
    /// relanza al cambiar de usuario en tvOS; sin esto un cambio en vuelo se perdería).
    func flush() async {
        mirrorAll()
        store.synchronize()
    }

    // MARK: Initial reconcile (KVS gana donde exista; siembra lo que falte)

    private func reconcile() {
        var pushed = false
        applyingRemote = true
        for key in allKeys {
            if store.object(forKey: key) != nil {
                applyOne(key)
            } else if defaults.object(forKey: key) != nil {
                mirrorOne(key)
                pushed = true
            }
        }
        applyingRemote = false
        if pushed { store.synchronize() }
        notifyReload()
    }

    // MARK: Remote → local

    private func externalChanged(keys: [String]) {
        let relevant = keys.filter { allKeys.contains($0) }
        applyRemote(keys: relevant.isEmpty ? allKeys : relevant)
    }

    private func applyRemote(keys: [String]) {
        guard !keys.isEmpty else { return }
        applyingRemote = true
        for key in keys { applyOne(key) }
        applyingRemote = false
        notifyReload()
    }

    private func applyOne(_ key: String) {
        guard store.object(forKey: key) != nil else { return }
        if Self.dataKeys.contains(key) {
            if let d = store.data(forKey: key), d != defaults.data(forKey: key) {
                defaults.set(d, forKey: key)
            }
        } else if Self.boolKeys.contains(key) {
            let v = store.bool(forKey: key)
            if defaults.object(forKey: key) as? Bool != v { defaults.set(v, forKey: key) }
        } else if Self.intKeys.contains(key) {
            let v = Int(store.longLong(forKey: key))
            if defaults.object(forKey: key) as? Int != v { defaults.set(v, forKey: key) }
        } else if Self.dictKeys.contains(key) {
            let remote = store.dictionary(forKey: key) as? [String: String]
            let local = defaults.dictionary(forKey: key) as? [String: String]
            if let remote, remote != local { defaults.set(remote, forKey: key) }
        } else if let v = store.string(forKey: key), v != defaults.string(forKey: key) {
            defaults.set(v, forKey: key)
        }
    }

    // MARK: Local → remote

    private func localChanged() {
        guard !applyingRemote, !mirrorScheduled else { return }
        mirrorScheduled = true
        Task { @MainActor [weak self] in
            self?.mirrorScheduled = false
            self?.mirrorAll()
        }
    }

    func mirrorAll() {
        for key in allKeys { mirrorOne(key) }
        store.synchronize()
    }

    private func mirrorOne(_ key: String) {
        if Self.dataKeys.contains(key) {
            let d = defaults.data(forKey: key)
            if d != store.data(forKey: key) { d.map { store.set($0, forKey: key) } }
        } else if Self.boolKeys.contains(key) {
            let v = defaults.bool(forKey: key)
            if store.object(forKey: key) as? Bool != v { store.set(v, forKey: key) }
        } else if Self.intKeys.contains(key) {
            let v = defaults.integer(forKey: key)
            if Int(store.longLong(forKey: key)) != v { store.set(Int64(v), forKey: key) }
        } else if Self.dictKeys.contains(key) {
            let local = defaults.dictionary(forKey: key) as? [String: String]
            let remote = store.dictionary(forKey: key) as? [String: String]
            if local != remote { local.map { store.set($0 as [String: Any], forKey: key) } }
        } else {
            let v = defaults.string(forKey: key)
            if v != store.string(forKey: key) { v.map { store.set($0, forKey: key) } }
        }
    }

    private func notifyReload() {
        SettingsStore.shared.reloadFromDefaults()
        L10nStore.shared.reloadFromDefaults()
        // Refresh views that read on-demand stores (track choices, etc.).
        SyncStatus.shared.generation += 1
    }
}
#endif
