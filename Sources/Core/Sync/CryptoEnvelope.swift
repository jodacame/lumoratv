import Foundation
import CryptoKit

/// Cifra blobs sensibles antes de subirlos a CloudKit (subtítulos traducidos,
/// referencias de OpenSubtitles, torrent elegido, config parental) con una llave
/// AES-256 por cuenta de iCloud. Apple solo ve ciphertext; la llave nunca llega a
/// sus servidores en claro.
///
/// La llave se guarda en el Keychain (local al dispositivo; `kSecAttrSynchronizable`
/// es no-op en tvOS) y se comparte entre los dispositivos de la misma persona vía el
/// record `Account` de CloudKit (campo `cryptoKey`), no por iCloud Keychain.
///
/// Formato del plaintext interno: `[1 byte flag][payload]` donde flag 1 = zlib.
enum CryptoEnvelope {
    /// Devuelve (o crea) la llave para `userID` (la identidad de cuenta de iCloud).
    static func key(for userID: String) -> SymmetricKey {
        let account = "syncKey-\(userID)"
        if let raw = Keychain.getData(account), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        Keychain.setData(raw, for: account, synchronizable: true)
        return key
    }

    /// Raw 256-bit key bytes for the user (creates one if absent). Used to share
    /// the key across devices via CloudKit (iCloud Keychain doesn't work on tvOS).
    static func rawKey(userID: String) -> Data {
        key(for: userID).withUnsafeBytes { Data($0) }
    }

    /// Adopts a key shared from another device so the same user's encrypted blobs
    /// decrypt everywhere. No-op if the bytes are invalid or already current.
    static func installKey(_ data: Data, userID: String) {
        guard data.count == 32, Keychain.getData("syncKey-\(userID)") != data else { return }
        Keychain.setData(data, for: "syncKey-\(userID)", synchronizable: true)
    }

    static func seal(_ plaintext: Data, userID: String) throws -> Data {
        var payload = Data()
        if let z = try? (plaintext as NSData).compressed(using: .zlib) as Data,
           z.count < plaintext.count {
            payload.append(1)
            payload.append(z)
        } else {
            payload.append(0)
            payload.append(plaintext)
        }
        let sealed = try AES.GCM.seal(payload, using: key(for: userID))
        guard let combined = sealed.combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func open(_ ciphertext: Data, userID: String) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let payload = try AES.GCM.open(box, using: key(for: userID))
        guard let flag = payload.first else { return Data() }
        let body = payload.dropFirst()
        if flag == 1 {
            return try (Data(body) as NSData).decompressed(using: .zlib) as Data
        }
        return Data(body)
    }
}
