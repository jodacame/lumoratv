import Foundation
import GRDB

/// Limpia TODOS los datos de un perfil al eliminarlo: filas en GRDB, claves en
/// UserDefaults/Keychain y —si el build trae iCloud— sus records en CloudKit. Evita
/// dejar datos huérfanos local y remotamente (almacenamiento + privacidad: el dato
/// del perfil borrado no debe quedarse en iCloud). La lista de perfiles y la config
/// global son del HOGAR, no de un perfil → no se tocan aquí.
@MainActor
enum ProfileDataCleaner {

    /// Borra el perfil `userID`. Primero lo remoto (necesita leer las claves locales
    /// para saber qué eliminar) y después lo local. Fire-and-forget.
    static func purge(userID: String) {
        Task {
            #if LUMORA_ICLOUD
            await CloudKitSync(localUserID: userID).purge()
            #endif
            await purgeLocal(userID: userID)
            SyncStatus.shared.generation += 1
        }
    }

    /// Borra todos los rastros locales del perfil (GRDB + UserDefaults + Keychain).
    static func purgeLocal(userID uid: String) async {
        try? await AppDatabase.shared.dbQueue.write { db in
            for table in ["watchState", "myList", "userRating"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE userID = ?", arguments: [uid])
            }
        }
        let d = UserDefaults.standard
        // Claves exactas por perfil.
        for key in ["stoppedShows-\(uid)", "parental-\(uid)", "recentSearches-\(uid)",
                    "lumora.prefsUpdatedAt#\(uid)", "ckZoneToken-\(uid)",
                    "didBackfillV2-\(uid)", "didMigrateUserDB-\(uid)"] {
            d.removeObject(forKey: key)
        }
        // Claves con prefijo (vocab/torrent/subtítulo, una por contenido o idioma) y
        // las prefs personales (sufijo "#<uuid>": audioLang#…, playerShow…#…).
        for key in d.dictionaryRepresentation().keys {
            if key.hasPrefix("vocab.\(uid).") || key.hasPrefix("torrentChoice-\(uid)-")
                || key.hasPrefix("subRef-\(uid)-") || key.hasSuffix("#\(uid)") {
                d.removeObject(forKey: key)
            }
        }
        // Elecciones de pista por contenido (dict keyado "<uuid>|contenido").
        for store in ["trackChoice.sub", "trackChoice.audio"] {
            if var dict = d.dictionary(forKey: store) as? [String: String] {
                let before = dict.count
                dict = dict.filter { !$0.key.hasPrefix("\(uid)|") }
                if dict.count != before { d.set(dict, forKey: store) }
            }
        }
        // Token de Trakt del perfil (Keychain).
        Keychain.delete("traktTokens-\(uid)")
    }
}
