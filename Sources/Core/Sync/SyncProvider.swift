import Foundation

/// Un cambio local que debe propagarse a los demás dispositivos del MISMO
/// usuario. El `userID` (alineado con `UserContext.currentUserID`) forma parte de
/// la identidad de todo lo sincronizable. Se amplía por fase.
enum SyncChange: Sendable {
    case config(key: String)                                  // Fase 2
    case watchState(userID: String, itemID: String)          // Fase 3
    case myList(userID: String, itemID: String)              // Fase 3
    case userRating(userID: String, itemID: String)          // Fase 3
    case trackChoice(userID: String, contentKey: String)     // Fase 4
    case stoppedShow(userID: String, mergeKey: String)       // Fase 4
    case torrentChoice(userID: String, watchKey: String)     // Fase 4 (cifrado)
    case vocab(userID: String, lang: String)                 // Fase 4
    case subtitleRef(userID: String, contentKey: String, lang: String) // Fase 5 (cifrado)
    case traktToken(userID: String)                                    // login Trakt (cifrado)
    case prefs(userID: String)                                         // prefs personales por perfil (audio/subs/HUD)
    case profiles                                                      // lista de perfiles del hogar
    case globalConfig                                                  // device-wide config + crypto key
}

/// Un destino de sincronización (KVS, CloudKit, …). Local-first: estos providers
/// solo reflejan lo que ya está guardado localmente.
protocol SyncProvider: Sendable {
    /// Identificador legible para diagnóstico.
    var name: String { get }
    /// Propaga un cambio local pendiente al destino remoto.
    func push(_ change: SyncChange) async
    /// Descarga cambios remotos y los aplica a los stores locales.
    func pull() async
    /// Drena cambios pendientes antes de que la app pase a segundo plano / sea
    /// terminada en un cambio de usuario. Por defecto, nada que drenar.
    func flush() async
}

extension SyncProvider {
    func flush() async {}
}

/// Provider inerte: se usa cuando no hay iCloud (cuenta gratis, sin sesión, etc.).
/// Nunca toca red ni APIs con entitlement.
struct NoopSyncProvider: SyncProvider {
    var name: String { "noop" }
    func push(_ change: SyncChange) async {}
    func pull() async {}
}
