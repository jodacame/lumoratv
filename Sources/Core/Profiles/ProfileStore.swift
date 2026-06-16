import SwiftUI

/// Maneja los perfiles PROPIOS de la app (independientes de los Usuarios de tvOS).
/// El perfil seleccionado define `UserContext.currentUserID`, que es la clave de
/// todos los datos per-persona y de la sincronización iCloud. Como tvOS usa una
/// sola cuenta de iCloud para todo el dispositivo, cada registro va keyado por el
/// UUID de perfil → varias personas pueden ver a la vez en TVs distintas y cada
/// una sincroniza SOLO lo suyo, sin pisarse.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [AppProfile] = []
    @Published private(set) var selectedID: String = ""
    /// True hasta que se elige perfil en esta sesión (muestra "¿Quién está viendo?").
    @Published var needsSelection: Bool = true

    private let listKey = "lumora.profiles"
    private let selectedKey = "lumora.selectedProfileID"
    private let legacyUserKey = "lumora.localUserID"   // UUID del modelo anterior
    private let pinKey = "householdPIN"                 // Keychain (device-wide)
    private let updatedKey = "lumora.profilesUpdatedAt" // reconciliación cross-device
    /// Cuándo cambió la lista por última vez (epoch). Gana la lista más reciente.
    private(set) var listUpdatedAt = 0

    private init() {
        var loaded = Self.loadProfiles(listKey)
        if loaded.isEmpty {
            // Primer arranque del nuevo modelo: el perfil por defecto ADOPTA el id
            // de datos existente para que el historial/listas no se pierdan, y
            // arrastra cualquier dato legacy ("shared") a ese id.
            let defaultID = UserDefaults.standard.string(forKey: legacyUserKey) ?? UUID().uuidString
            UserDefaults.standard.set(defaultID, forKey: legacyUserKey)
            UserIdentityMigration.migrateLocalDefaults(from: UserContext.legacyID, to: defaultID)
            loaded = [AppProfile(id: defaultID, name: "Principal", isKid: false)]
            Self.saveProfiles(loaded, listKey)
        }
        profiles = loaded
        let persisted = UserDefaults.standard.string(forKey: selectedKey)
        selectedID = persisted.flatMap { id in loaded.contains { $0.id == id } ? id : nil } ?? loaded[0].id
        listUpdatedAt = UserDefaults.standard.integer(forKey: updatedKey)
        // Heal: perfiles creados ANTES del tracking de updatedAt (varios perfiles con
        // marca 0) → asigna una marca real para que la sync los pueda subir. El
        // perfil por defecto sin tocar (1 perfil, marca 0) NO se toca → nunca pisa.
        if loaded.count > 1 && listUpdatedAt == 0 {
            listUpdatedAt = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(listUpdatedAt, forKey: updatedKey)
        }
        // Siempre se pregunta "¿quién está viendo?" al abrir la app.
        needsSelection = true
    }

    /// Perfil activo (siempre válido).
    var current: AppProfile {
        profiles.first { $0.id == selectedID } ?? profiles[0]
    }

    // MARK: - Selección

    /// Elige un perfil para la sesión y re-apunta los datos/sync a su UUID.
    func select(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
        needsSelection = false
        UserDefaults.standard.set(id, forKey: selectedKey)
        ParentalStore.shared.applyProfileLevel(current.parentalLevel)
        SettingsStore.shared.reloadProfilePrefs()   // cada perfil con su audio/subs/HUD
        SyncCoordinator.shared.profileDidChange()
        SyncStatus.shared.generation += 1
    }

    /// Aplica el nivel parental del perfil activo a `ParentalStore` (al arrancar).
    func applyActiveParental() {
        ParentalStore.shared.applyProfileLevel(current.parentalLevel)
    }

    /// Vuelve a mostrar "¿Quién está viendo?" (desde Ajustes: cambiar/crear perfil).
    func requestSelection() { needsSelection = true }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, isKid: Bool, parentalLevel: Int?, colorIndex: Int, avatar: String? = nil) -> AppProfile {
        let p = AppProfile(name: name, isKid: isKid, parentalLevel: parentalLevel, colorIndex: colorIndex, avatar: avatar)
        profiles.append(p)
        persist()
        return p
    }

    func update(_ profile: AppProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        persist()
        if profile.id == selectedID {
            ParentalStore.shared.applyProfileLevel(current.parentalLevel)
            SyncStatus.shared.generation += 1
        }
    }

    /// Elimina un perfil (no el último, no el activo). Limpia TODOS sus datos —local
    /// y en iCloud— para no dejar rastros huérfanos (ver `ProfileDataCleaner`).
    func remove(_ id: String) {
        guard profiles.count > 1, id != selectedID else { return }
        profiles.removeAll { $0.id == id }
        persist()
        ProfileDataCleaner.purge(userID: id)
    }

    // MARK: - PIN del hogar (protege perfiles de adulto y la edición)

    var hasPIN: Bool { !(Keychain.get(pinKey) ?? "").isEmpty }

    func setPIN(_ pin: String) {
        let p = pin.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { Keychain.delete(pinKey) } else { Keychain.set(p, for: pinKey) }
    }

    func verifyPIN(_ pin: String) -> Bool {
        guard let stored = Keychain.get(pinKey), !stored.isEmpty else { return true }
        return stored == pin.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Persistencia

    private func persist() {
        listUpdatedAt = Int(Date().timeIntervalSince1970)
        UserDefaults.standard.set(listUpdatedAt, forKey: updatedKey)
        Self.saveProfiles(profiles, listKey)
        SyncCoordinator.shared.enqueue(.profiles)
    }

    /// Instantánea para sincronizar (lista + marca de tiempo).
    func snapshot() -> (profiles: [AppProfile], updatedAt: Int) { (profiles, listUpdatedAt) }

    /// Fuerza la subida de la lista a iCloud: la marca como cambiada AHORA (la hace
    /// la más nueva) y encola el push. Botón manual en Ajustes.
    func pushNow() {
        listUpdatedAt = Int(Date().timeIntervalSince1970)
        UserDefaults.standard.set(listUpdatedAt, forKey: updatedKey)
        SyncCoordinator.shared.enqueue(.profiles)
    }

    private static func loadProfiles(_ key: String) -> [AppProfile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([AppProfile].self, from: data) else { return [] }
        return list
    }

    private static func saveProfiles(_ list: [AppProfile], _ key: String) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Adopta la lista remota (sync) SOLO si es más reciente que la local (gana el
    /// cambio más reciente). Propaga altas/ediciones/bajas entre TVs.
    func applyRemote(_ remote: [AppProfile], updatedAt: Int) {
        guard !remote.isEmpty, updatedAt > listUpdatedAt else { return }
        profiles = remote
        listUpdatedAt = updatedAt
        UserDefaults.standard.set(updatedAt, forKey: updatedKey)
        Self.saveProfiles(remote, listKey)
        // Si el perfil activo ya no existe, no forzamos cambio (el selector decide).
        ParentalStore.shared.applyProfileLevel(current.parentalLevel)
        SyncStatus.shared.generation += 1
    }
}
