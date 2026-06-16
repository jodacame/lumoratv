import Foundation

/// Punto único de la sincronización entre dispositivos del MISMO usuario.
///
/// Local-first: los stores locales (GRDB, UserDefaults, Keychain) siguen siendo
/// la fuente de verdad; esto solo refleja. Sin iCloud (cuenta gratis o sin
/// sesión) es un no-op completo y la app se comporta idéntica a hoy.
@MainActor
final class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()

    enum Status: Equatable {
        case disabled      // binario sin soporte iCloud (cuenta gratis)
        case unavailable   // con soporte, pero sin sesión iCloud
        case active        // listo / sincronizando en background
        case syncing       // pull en curso
    }

    @Published private(set) var status: Status = .disabled
    @Published private(set) var lastSyncAt: Date?

    /// Localized one-liner for the Settings status row.
    var statusText: String {
        switch status {
        case .disabled: return tr(L.syncDisabled)
        case .unavailable: return tr(L.syncUnavailable)
        case .active: return tr(L.syncActive)
        case .syncing: return tr(L.syncSyncing)
        }
    }

    private init() {
        lastSyncAt = UserDefaults.standard.object(forKey: "lastICloudSyncAt") as? Date
        refreshStatus()
    }

    /// Llamar una vez al arrancar la app.
    func bootstrap() {
        refreshStatus()
        Task {
            // Migra los datos del id legacy ("shared") al id estable por usuario.
            // Corre en ambos builds (no toca iCloud) y ANTES de iniciar la sync.
            await UserIdentityMigration.migrateDatabaseIfNeeded(
                to: UserContext.currentUserID, from: UserContext.legacyID)
            #if LUMORA_ICLOUD
            start(for: UserContext.currentUserID)
            #endif
        }
    }

    /// Disparar pull al volver a foreground.
    func applicationDidBecomeActive() {
        #if LUMORA_ICLOUD
        // start(...) ensures the providers exist (idempotent) and runs a sync.
        start(for: UserContext.currentUserID)
        #endif
    }

    /// Se cambió el perfil activo de la app: re-apunta la sync al UUID del nuevo
    /// perfil (cada perfil sincroniza SOLO lo suyo).
    func profileDidChange() {
        #if LUMORA_ICLOUD
        start(for: UserContext.currentUserID)
        #endif
    }

    /// Al pasar a segundo plano / inactivo: drena lo pendiente a iCloud. tvOS
    /// TERMINA y relanza la app al cambiar de usuario, así que este flush cierra la
    /// carrera "guardado en vuelo ↔ cambio de cuenta" antes del relanzamiento.
    func applicationWillResignActive() {
        #if LUMORA_ICLOUD
        Task { [providers] in
            for p in providers { await p.flush() }
        }
        #endif
    }

    /// Llegó un push silencioso de CloudKit (cambio remoto). Solo lo entrega tvOS
    /// con la app activa; lo tratamos como pista y hacemos un pull por change-token.
    func handleRemotePush() async {
        #if LUMORA_ICLOUD
        await syncNow()
        #endif
    }

    /// Feedback en vivo del botón "Subir todo a iCloud" (texto de progreso que se
    /// muestra en Ajustes). `nil` = inactivo / sin nada que mostrar.
    @Published private(set) var pushAllStatus: String?
    /// True mientras una subida manual completa está en curso (deshabilita el botón).
    @Published private(set) var isPushingAll = false

    /// Sube una FOTO COMPLETA de este Apple TV a iCloud, manualmente: la lista de
    /// perfiles, la configuración global (servidores, claves) y los datos de CADA
    /// perfil (continuar viendo, historial, Mi Lista, valoraciones, Trakt…). La
    /// sincronización normal ya ocurre automáticamente por evento (play/pausa/agregar);
    /// este botón es un respaldo/seguridad para empujarlo TODO de una. Reporta avance
    /// vía `pushAllStatus` para dar feedback de lo que está haciendo.
    func uploadAllToCloud() async {
        #if LUMORA_ICLOUD
        guard SyncCapabilities.isCompiledWithICloud, !isPushingAll else { return }
        isPushingAll = true
        defer { isPushingAll = false }
        pushAllStatus = tr(L.pushAllChecking)
        guard await SyncCapabilities.cloudKitAccountReady() else {
            status = .unavailable
            pushAllStatus = nil
            ToastCenter.shared.show(tr(L.toastNoICloud), icon: "icloud.slash")
            return
        }
        let list = ProfileStore.shared.profiles
        // Marca la lista como cambiada AHORA para que gane y se suba sí o sí.
        ProfileStore.shared.pushNow()
        var total = 0
        for (i, p) in list.enumerated() {
            pushAllStatus = trf(L.pushAllProfile, p.name, i + 1, list.count)
            total += await CloudKitSync(localUserID: p.id).backfill()
        }
        // El perfil activo queda con su backfill automático marcado como hecho.
        UserDefaults.standard.set(true, forKey: "didBackfillV2-\(UserContext.currentUserID)")
        lastSyncAt = Date()
        UserDefaults.standard.set(lastSyncAt, forKey: "lastICloudSyncAt")
        pushAllStatus = trf(L.pushAllDone, list.count, total)
        ToastCenter.shared.show(trf(L.pushAllDone, list.count, total), icon: "checkmark.icloud")
        // Limpia el texto tras unos segundos para no dejarlo pegado.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.pushAllStatus = nil
        }
        #endif
    }

    /// Registrar un cambio local para propagar. Si el sync aún no está listo
    /// (providers sin crear, o iCloud `.unavailable` transitorio) NO se pierde: se
    /// almacena y se drena en cuanto el sync arranca. No-op en build gratis.
    func enqueue(_ change: SyncChange) {
        #if LUMORA_ICLOUD
        guard SyncCapabilities.isCompiledWithICloud else { return }
        guard (status == .active || status == .syncing), !providers.isEmpty else {
            // Buffer acotado: si iCloud no aparece, el backfill/botón manual cubre el
            // estado completo igual, así que descartar los más viejos es seguro.
            pending.append(change)
            if pending.count > pendingCap { pending.removeFirst(pending.count - pendingCap) }
            return
        }
        Task { [providers] in
            for p in providers { await p.push(change) }
        }
        #else
        _ = change
        #endif
    }

    /// Pull manual / al volver a foreground.
    func syncNow() async {
        #if LUMORA_ICLOUD
        guard SyncCapabilities.isCompiledWithICloud else { return }
        guard await SyncCapabilities.cloudKitAccountReady() else {
            status = .unavailable
            ToastCenter.shared.show(tr(L.toastNoICloud), icon: "icloud.slash")
            return
        }
        status = .syncing
        for p in providers { await p.pull() }
        lastSyncAt = Date()
        UserDefaults.standard.set(lastSyncAt, forKey: "lastICloudSyncAt")
        status = .active
        flushPending()
        #endif
    }

    // MARK: - Private

    private func refreshStatus() {
        // ubiquityIdentityToken is nil on tvOS (no iCloud Drive) even when CloudKit
        // is available, so DON'T gate on it. Optimistic .active when compiled;
        // syncNow() downgrades to .unavailable if CloudKit isn't actually ready.
        if status == .syncing { return }
        status = SyncCapabilities.isCompiledWithICloud ? .active : .disabled
    }

    #if LUMORA_ICLOUD
    /// Usuario para el que está activo el sync (alineado con UserContext).
    private(set) var activeUserID: String?
    private var providers: [SyncProvider] = []
    private var kvs: KVSConfigSync?
    private var cloudKit: CloudKitSync?
    /// Cambios que llegaron antes de que el sync estuviera listo; se drenan al
    /// activarse (cierra la ventana de arranque y los baches de iCloud).
    private var pending: [SyncChange] = []
    private let pendingCap = 1000

    /// Drena los cambios bufferizados (si los hay) ahora que el sync está activo.
    private func flushPending() {
        guard !pending.isEmpty, !providers.isEmpty,
              status == .active || status == .syncing else { return }
        let drained = pending
        pending.removeAll()
        Task { [providers] in
            for change in drained {
                for p in providers { await p.push(change) }
            }
        }
    }

    private func start(for userID: String) {
        guard SyncCapabilities.isCompiledWithICloud else { return }
        refreshStatus()
        // KVS: una sola vez (no es per-user; observa los defaults del usuario actual).
        if kvs == nil {
            let k = KVSConfigSync()
            k.activate()
            kvs = k
            providers.append(k)
        }
        // CloudKit: (re)crear si cambió el usuario.
        if activeUserID != userID || cloudKit == nil {
            activeUserID = userID
            let ck = CloudKitSync(localUserID: userID)
            cloudKit = ck
            providers.removeAll { $0 is CloudKitSync }
            providers.append(ck)
        }
        Task { [cloudKit] in
            await syncNow()
            await cloudKit?.registerSubscription()   // push en vivo (pista; el pull manda)
            await runBackfillIfNeeded(userID: userID)
        }
    }

    /// One-time upload of all pre-existing local data for this user, after the
    /// first successful sync. Idempotent and guarded by a per-user flag.
    private func runBackfillIfNeeded(userID: String) async {
        // V2: el modelo cambió (identidad = UUID de perfil + cifrado del hogar), así
        // que se fuerza una re-subida completa una sola vez bajo el nuevo esquema.
        let flag = "didBackfillV2-\(userID)"
        guard !UserDefaults.standard.bool(forKey: flag),
              let cloudKit,
              await SyncCapabilities.cloudKitAccountReady() else { return }
        await cloudKit.backfill()
        UserDefaults.standard.set(true, forKey: flag)
    }
    #endif
}
