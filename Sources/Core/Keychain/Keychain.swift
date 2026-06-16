import Foundation
import Security

/// Llavero del dispositivo. LumoraTV ya NO usa el multiusuario de tvOS
/// (`runs-as-current-user`), así que el llavero estándar es **device-wide**
/// (compartido por todo el equipo). Eso es lo correcto para:
///  • **Config global** (API keys, servidores, URLs, Trakt client): claves sin
///    prefijo de perfil → una sola copia por dispositivo, heredada por todos.
///  • **Secretos per-perfil** (token de Trakt, llave de cifrado): el nombre de la
///    clave lleva el UUID de perfil (`traktTokens-<uuid>`), así quedan separados.
///
/// Las APIs `set/get` (per-perfil por convención de nombre) y `setSecret/getSecret`
/// (config global) apuntan al MISMO llavero estándar; se conservan ambas por
/// compatibilidad de código.
enum Keychain {
    private static let service = "dev.jodacame.lumoratv"

    // MARK: Core

    private static func add(account: String, data: Data) {
        deleteRaw(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func copy(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Empareja también el bucket "synchronizable" legacy de builds previos.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    private static func deleteRaw(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: API (todo apunta al mismo llavero device-wide)

    static func set(_ value: String, for key: String) { add(account: key, data: Data(value.utf8)) }
    static func get(_ key: String) -> String? { copy(account: key).flatMap { String(data: $0, encoding: .utf8) } }
    static func delete(_ key: String) { deleteRaw(account: key) }

    static func setData(_ data: Data, for key: String, synchronizable: Bool = false) { add(account: key, data: data) }
    static func getData(_ key: String) -> Data? { copy(account: key) }

    // Aliases de "config global" (mismo llavero device-wide).
    static func setSecret(_ value: String, for key: String) { set(value, for: key) }
    static func getSecret(_ key: String) -> String? { get(key) }
    static func deleteSecret(_ key: String) { delete(key) }
    static func setSecretData(_ data: Data, for key: String) { add(account: key, data: data) }
    static func getSecretData(_ key: String) -> Data? { copy(account: key) }

    /// Compatibilidad: en el modelo device-wide no hay nada que promover (un solo
    /// llavero). No-op.
    static func promoteToGlobal(_ key: String) {}
}
