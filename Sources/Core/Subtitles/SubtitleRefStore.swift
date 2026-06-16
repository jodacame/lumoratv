import Foundation

/// Recuerda QUÉ subtítulo de OpenSubtitles usó el usuario para un contenido (por
/// idioma): guardamos solo la REFERENCIA (`file_id`), nunca el archivo. Así, en
/// otra TV del mismo usuario, ese mismo subtítulo se re-descarga solo para
/// continuar igual. Per-usuario, por identidad de contenido. Se sincroniza
/// cifrado vía CloudKit (ver CloudKitSync); sin iCloud queda local.
@MainActor
enum SubtitleRefStore {
    struct Ref: Codable, Sendable {
        var fileID: Int
        var lang: String
    }

    private static func key(_ userID: String, _ watchKey: String, _ lang: String) -> String {
        "subRef-\(userID)-\(watchKey)-\(lang)"
    }

    static func save(userID: String, watchKey: String, lang: String, fileID: Int) {
        let ref = Ref(fileID: fileID, lang: lang)
        guard let data = try? JSONEncoder().encode(ref) else { return }
        UserDefaults.standard.set(data, forKey: key(userID, watchKey, lang))
        SyncCoordinator.shared.enqueue(.subtitleRef(userID: userID, contentKey: watchKey, lang: lang))
    }

    static func get(userID: String, watchKey: String, lang: String) -> Ref? {
        guard let data = UserDefaults.standard.data(forKey: key(userID, watchKey, lang)) else { return nil }
        return try? JSONDecoder().decode(Ref.self, from: data)
    }

    static func clear(userID: String, watchKey: String, lang: String) {
        UserDefaults.standard.removeObject(forKey: key(userID, watchKey, lang))
        SyncCoordinator.shared.enqueue(.subtitleRef(userID: userID, contentKey: watchKey, lang: lang))
    }
}
