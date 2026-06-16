import Foundation
import GRDB

/// Migración única de los datos per-usuario desde el id legacy (`"shared"`, fruto
/// del `TVUserManager.currentUserIdentifier` deprecado que devolvía nil) hacia el
/// nuevo id estable por usuario (ver `UserContext`).
///
/// Todo ocurre DENTRO del contenedor del usuario actual, que el sistema ya aísla
/// por perfil; sólo reescribimos las claves para que coincidan con la nueva
/// identidad. Idempotente: si el destino ya existe no se pisa, y el origen se
/// limpia. No referencia iCloud → compila igual en build gratis.
enum UserIdentityMigration {

    /// Parte síncrona: claves en `UserDefaults` + tokens de Trakt en Keychain.
    /// Se ejecuta al acuñar el id (antes de la primera lectura de parental).
    @MainActor
    static func migrateLocalDefaults(from old: String, to new: String) {
        guard old != new else { return }
        let d = UserDefaults.standard

        // Claves exactas.
        move(d, "parental-\(old)", "parental-\(new)")
        move(d, "stoppedShows-\(old)", "stoppedShows-\(new)")
        move(d, "recentSearches-\(old)", "recentSearches-\(new)")

        // Claves con prefijo (una entrada por contenido / idioma).
        movePrefixed(d, "vocab.\(old).", "vocab.\(new).")
        movePrefixed(d, "torrentChoice-\(old)-", "torrentChoice-\(new)-")
        movePrefixed(d, "subRef-\(old)-", "subRef-\(new)-")

        // Tokens de Trakt (Keychain per-usuario).
        let oldTrakt = "traktTokens-\(old)", newTrakt = "traktTokens-\(new)"
        if Keychain.getData(newTrakt) == nil, let t = Keychain.getData(oldTrakt) {
            Keychain.setData(t, for: newTrakt)
        }
        Keychain.delete(oldTrakt)
    }

    /// Parte asíncrona: filas en GRDB (progreso, Mi Lista, votos). Se ejecuta una
    /// vez al arrancar; protegida por flag. Refresca la UI al terminar.
    static func migrateDatabaseIfNeeded(to new: String, from old: String) async {
        guard old != new else { return }
        let flag = "didMigrateUserDB-\(new)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        try? await AppDatabase.shared.dbQueue.write { db in
            for table in ["watchState", "myList", "userRating"] {
                try db.execute(
                    sql: "UPDATE \(table) SET userID = ? WHERE userID = ?",
                    arguments: [new, old]
                )
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
        await MainActor.run { SyncStatus.shared.generation += 1 }
    }

    // MARK: - Helpers

    private static func move(_ d: UserDefaults, _ oldKey: String, _ newKey: String) {
        guard let value = d.object(forKey: oldKey) else { return }
        if d.object(forKey: newKey) == nil { d.set(value, forKey: newKey) }
        d.removeObject(forKey: oldKey)
    }

    private static func movePrefixed(_ d: UserDefaults, _ oldPrefix: String, _ newPrefix: String) {
        for key in d.dictionaryRepresentation().keys where key.hasPrefix(oldPrefix) {
            let newKey = newPrefix + key.dropFirst(oldPrefix.count)
            if d.object(forKey: newKey) == nil, let value = d.object(forKey: key) {
                d.set(value, forKey: newKey)
            }
            d.removeObject(forKey: key)
        }
    }
}
