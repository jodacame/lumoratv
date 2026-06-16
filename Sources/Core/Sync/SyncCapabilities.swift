import Foundation
#if LUMORA_ICLOUD
import CloudKit
#endif

/// Detecta si la capa de sincronización iCloud puede operar.
///
/// Sin el flag de compilación `LUMORA_ICLOUD` (build de cuenta gratis) TODO es
/// `false` y nada de CloudKit/KVS se referencia jamás — el binario no contiene
/// rutas que puedan fallar por falta de entitlements.
@MainActor
enum SyncCapabilities {
    /// El binario fue compilado con soporte iCloud (flag activo + entitlements
    /// firmados con cuenta de pago).
    static var isCompiledWithICloud: Bool {
        #if LUMORA_ICLOUD
        return true
        #else
        return false
        #endif
    }

    /// Hay una sesión de iCloud activa en este dispositivo.
    static var hasICloudAccount: Bool {
        #if LUMORA_ICLOUD
        return FileManager.default.ubiquityIdentityToken != nil
        #else
        return false
        #endif
    }

    /// KVS utilizable (config pequeña, Fase 2).
    static var kvsAvailable: Bool {
        isCompiledWithICloud && hasICloudAccount
    }

    /// Puerta rápida y síncrona para CloudKit. La verificación robusta del estado
    /// de la cuenta es `cloudKitAccountReady()` (async).
    static var cloudKitAvailable: Bool {
        isCompiledWithICloud && hasICloudAccount
    }

    #if LUMORA_ICLOUD
    /// Estado real de la cuenta CloudKit del usuario (async, robusto).
    static func cloudKitAccountReady() async -> Bool {
        guard isCompiledWithICloud else { return false }
        do {
            return try await CKContainer.default().accountStatus() == .available
        } catch {
            return false
        }
    }

    #endif
}
