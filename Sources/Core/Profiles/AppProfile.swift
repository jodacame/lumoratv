import Foundation

/// Un perfil GESTIONADO POR LA APP (no por tvOS). LumoraTV maneja sus propios
/// perfiles porque tvOS no aísla las cuentas de menores ni expone un identificador
/// de perfil utilizable. Cada perfil tiene un UUID propio que es la identidad de
/// TODO lo per-persona (historial, continuar viendo, Mi Lista, parental, Trakt…)
/// y la clave de sincronización en iCloud — el mismo UUID en otra TV = la misma
/// persona, sin pisar a los demás.
struct AppProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String              // UUID estable; clave de todos los datos del perfil
    var name: String
    var isKid: Bool             // perfil de menor: restringido, entra sin PIN
    var parentalLevel: Int?     // nil = sin restricción · 0=G · 1=PG · 2=PG-13
    var colorIndex: Int         // color del fondo (degradado animado)
    var avatar: String?         // nombre del PNG del avatar (nil = inicial del nombre)

    init(id: String = UUID().uuidString, name: String, isKid: Bool = false,
         parentalLevel: Int? = nil, colorIndex: Int = 0, avatar: String? = nil) {
        self.id = id
        self.name = name
        self.isKid = isKid
        self.parentalLevel = parentalLevel
        self.colorIndex = colorIndex
        self.avatar = avatar
    }

    /// Avatares disponibles (PNG de DiceBear, varios estilos — en Resources/Avatars).
    static let avatars: [String] = (1...50).map { String(format: "a%02d", $0) }
}
