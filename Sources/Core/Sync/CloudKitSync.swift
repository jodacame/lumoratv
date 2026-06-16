import Foundation

#if LUMORA_ICLOUD
import CloudKit
import GRDB

/// Sincroniza los datos preciosos del PERFIL (progreso, Mi Lista, votos, parental
/// vive local) vía CloudKit private database del hogar, en una zona custom con sync
/// incremental por change tokens. Local-first: GRDB/UserDefaults son la verdad local.
///
/// **Identidad única = el UUID del perfil de la app** (`localUserID`, alineado con
/// `UserContext.currentUserID`). tvOS usa una sola cuenta iCloud para todo el equipo,
/// así que TODOS los registros van keyados por el UUID de perfil: dos TVs con
/// perfiles distintos tocan claves distintas (no se pisan) y el mismo perfil en dos
/// TVs reconcilia por `updatedAt`. El cifrado usa una llave del hogar (`cryptoID`).
actor CloudKitSync: SyncProvider {
    nonisolated var name: String { "cloudkit" }

    private let container = CKContainer.default()
    private let zoneID = CKRecordZone.ID(zoneName: "Lumora", ownerName: CKCurrentUserDefaultName)
    /// UUID del perfil activo (clave de todos los datos de este perfil).
    private let localUserID: String
    private var zoneEnsured = false

    // Debounce de progreso (update() se llama periódicamente durante reproducción).
    private var pendingWatch: Set<String> = []
    private var watchFlushScheduled = false

    init(localUserID: String) { self.localUserID = localUserID }

    private var db: CKDatabase { container.privateCloudDatabase }

    /// Identidad de TODOS los registros = el UUID del **perfil activo**. Así cada
    /// perfil tiene sus propias claves en la base privada del hogar: dos TVs con
    /// perfiles distintos tocan claves distintas → nunca se pisan; el mismo perfil
    /// en dos TVs reconcilia por `updatedAt`.
    private var cid: String { localUserID }

    /// Clave de cifrado del HOGAR (una sola, compartida entre las TVs vía el record
    /// `Account`). El aislamiento entre perfiles lo da la clave-de-registro (UUID),
    /// no el cifrado, así que una llave por hogar basta.
    private let cryptoID = "household"

    /// Transient on-screen notification (iCloud build only). Hops to the main actor.
    private func toast(_ text: String, _ icon: String) {
        Task { @MainActor in ToastCenter.shared.show(text, icon: icon) }
    }

    // MARK: - SyncProvider

    func push(_ change: SyncChange) async {
        switch change {
        case .watchState(let uid, let itemID):
            guard uid == localUserID else { return }
            scheduleWatchPush(itemID)
        case .myList(let uid, let itemID):
            guard uid == localUserID else { return }
            await pushMyList(itemID)
        case .userRating(let uid, let itemID):
            guard uid == localUserID else { return }
            await pushUserRating(itemID)
        case .stoppedShow(let uid, let mergeKey):
            guard uid == localUserID else { return }
            await pushStopped(mergeKey)
        case .torrentChoice(let uid, let watchKey):
            guard uid == localUserID else { return }
            await pushTorrentChoice(watchKey)
        case .vocab(let uid, let lang):
            guard uid == localUserID else { return }
            scheduleVocabPush(lang)
        case .subtitleRef(let uid, let contentKey, let lang):
            guard uid == localUserID else { return }
            await pushSubtitleRef(contentKey, lang)
        case .traktToken(let uid):
            guard uid == localUserID else { return }
            await pushTraktToken()
        case .prefs(let uid):
            guard uid == localUserID else { return }
            await pushPrefs()
        case .profiles:
            await pushProfiles()
        case .globalConfig:
            pushAccountDebounced()
        default:
            break
        }
    }

    func pull() async {
        await ensureZone()
        await syncAccount()          // shared crypto key + global config FIRST
        await fetchZoneChanges()
        await reconcileProfiles()    // publica la lista local si es más nueva que la remota
    }

    /// Sube la lista de perfiles si la local es más reciente que la remota (la
    /// descarga la maneja `applyProfiles` desde `fetchZoneChanges`). Un perfil por
    /// defecto de instalación nueva tiene `updatedAt = 0` → nunca pisa una lista real.
    private func reconcileProfiles() async {
        let snap = await MainActor.run { ProfileStore.shared.snapshot() }
        // NUNCA subir un perfil por defecto sin tocar (updatedAt 0) — solo listas
        // con un cambio real del usuario (add/edit/delete → updatedAt > 0).
        guard !snap.profiles.isEmpty, snap.updatedAt > 0 else { return }
        let remoteUpdated = ((try? await db.record(for: profilesRecordID()))?["updatedAt"] as? Int) ?? -1
        if snap.updatedAt > remoteUpdated { await pushProfiles() }
    }

    /// Suscripción de base de datos para push silencioso (cambios remotos en vivo).
    /// Idempotente. En tvOS el push solo llega con la app activa → es una PISTA; el
    /// fetch por change-token en foreground sigue siendo la fuente de verdad.
    /// API actual: `CKDatabaseSubscription` + `modifySubscriptions(saving:deleting:)`.
    func registerSubscription() async {
        // Ya registrada → no recrear.
        if (try? await db.subscription(for: Self.subscriptionID)) != nil { return }
        let sub = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        // Silencioso: en tvOS 13+/iOS 13+ NO debe llevar alertBody/soundName.
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        _ = try? await db.modifySubscriptions(saving: [sub], deleting: [])
    }

    static let subscriptionID = "lumora-db-changes"

    /// Flush de cambios pendientes antes de pasar a segundo plano / ser terminados
    /// en un cambio de usuario. Cierra la carrera "guardado en vuelo ↔ relanzamiento".
    func flush() async {
        await flushWatch()
        await flushVocab()
        if accountPushScheduled { await pushAccount() }
    }

    /// One-time upload of all existing local data for this user (run after the
    /// first successful sync, so prior history reaches CloudKit). Idempotent
    /// (.changedKeys upsert); serial to avoid hammering CloudKit.
    /// Devuelve cuántos registros de datos del perfil se subieron (para feedback).
    @discardableResult
    func backfill() async -> Int {
        await ensureZone()
        let uid = localUserID
        var count = 0
        let watch = (try? await AppDatabase.shared.dbQueue.read { db in
            try WatchState.filter(Column("userID") == uid).fetchAll(db).map(\.itemID)
        }) ?? []
        for itemID in watch { await pushWatchState(itemID); count += 1 }
        let list = (try? await AppDatabase.shared.dbQueue.read { db in
            try MyListEntry.filter(Column("userID") == uid).fetchAll(db).map(\.itemID)
        }) ?? []
        for itemID in list { await pushMyList(itemID); count += 1 }
        let ratings = (try? await AppDatabase.shared.dbQueue.read { db in
            try UserRating.filter(Column("userID") == uid).fetchAll(db).map(\.itemID)
        }) ?? []
        for itemID in ratings { await pushUserRating(itemID); count += 1 }

        for mk in Set(UserDefaults.standard.stringArray(forKey: "stoppedShows-\(uid)") ?? []) {
            await pushStopped(mk); count += 1
        }

        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        let vocabPrefix = "vocab.\(uid)."
        for k in allKeys where k.hasPrefix(vocabPrefix) {
            await pushVocab(String(k.dropFirst(vocabPrefix.count))); count += 1
        }
        let tcPrefix = "torrentChoice-\(uid)-"
        for k in allKeys where k.hasPrefix(tcPrefix) {
            await pushTorrentChoice(String(k.dropFirst(tcPrefix.count))); count += 1
        }
        let srPrefix = "subRef-\(uid)-"
        for k in allKeys where k.hasPrefix(srPrefix) {
            let rem = String(k.dropFirst(srPrefix.count))
            if let r = rem.range(of: "-", options: .backwards) {
                await pushSubtitleRef(String(rem[..<r.lowerBound]), String(rem[r.upperBound...])); count += 1
            }
        }
        await pushTraktToken()
        await pushPrefs()           // prefs personales del perfil (audio/subs/HUD)
        await reconcileProfiles()   // sube la lista solo si la local es más nueva
        // (parental es local-only: no se sube)
        await pushAccount()   // publish crypto key + global config for other devices
        return count
    }

    /// Borra de iCloud TODOS los records de este perfil (al eliminar el perfil). Lee
    /// las claves locales para reconstruir los record IDs — mismo enumerado que
    /// `backfill()`, pero en sentido inverso. NO toca el record `Account` ni la lista
    /// de perfiles (son del hogar, no de un perfil). Llamar ANTES de borrar lo local.
    func purge() async {
        await ensureZone()
        let uid = localUserID
        var ids: [CKRecord.ID] = []
        let watch = (try? await AppDatabase.shared.dbQueue.read { db in
            try WatchState.filter(Column("userID") == uid).fetchAll(db).map(\.itemID)
        }) ?? []
        ids += watch.map { recordID("ws", $0) }
        let list = (try? await AppDatabase.shared.dbQueue.read { db in
            try MyListEntry.filter(Column("userID") == uid).fetchAll(db).map(\.itemID)
        }) ?? []
        ids += list.map { recordID("ml", $0) }
        let ratings = (try? await AppDatabase.shared.dbQueue.read { db in
            try UserRating.filter(Column("userID") == uid).fetchAll(db).map(\.itemID)
        }) ?? []
        ids += ratings.map { recordID("ur", $0) }
        for mk in Set(UserDefaults.standard.stringArray(forKey: "stoppedShows-\(uid)") ?? []) {
            ids.append(recordID("st", mk))
        }
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        let vocabPrefix = "vocab.\(uid)."
        for k in allKeys where k.hasPrefix(vocabPrefix) {
            ids.append(recordID("vc", String(k.dropFirst(vocabPrefix.count))))
        }
        let tcPrefix = "torrentChoice-\(uid)-"
        for k in allKeys where k.hasPrefix(tcPrefix) {
            ids.append(recordID("tc", String(k.dropFirst(tcPrefix.count))))
        }
        let srPrefix = "subRef-\(uid)-"
        for k in allKeys where k.hasPrefix(srPrefix) {
            let rem = String(k.dropFirst(srPrefix.count))
            if let r = rem.range(of: "-", options: .backwards) {
                ids.append(recordID("sr", "\(String(rem[..<r.lowerBound]))|\(String(rem[r.upperBound...]))"))
            }
        }
        ids.append(recordID("tk", "token"))
        ids.append(recordID("pf", "prefs"))
        for chunk in ids.chunked(into: 400) {
            _ = try? await db.modifyRecords(saving: [], deleting: chunk,
                                            savePolicy: .changedKeys, atomically: false)
        }
    }

    // MARK: - Watch state (debounced)

    private func scheduleWatchPush(_ itemID: String) {
        pendingWatch.insert(itemID)
        guard !watchFlushScheduled else { return }
        watchFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.flushWatch()
        }
    }

    private func flushWatch() async {
        let items = pendingWatch
        pendingWatch.removeAll()
        watchFlushScheduled = false
        for itemID in items { await pushWatchState(itemID) }
    }

    private func pushWatchState(_ itemID: String) async {
        let row = await readWatchState(itemID)
        let rid = recordID("ws", itemID)
        guard let row else { await delete(rid); return }
        let rec = CKRecord(recordType: "WatchState", recordID: rid)
        rec["userID"] = cid
        rec["itemID"] = itemID
        rec["isEpisode"] = row.isEpisode ? 1 : 0
        rec["refID"] = row.refID
        rec["viewOffsetMs"] = row.viewOffsetMs
        rec["viewCount"] = row.viewCount
        rec["lastViewedAt"] = row.lastViewedAt
        rec["finishedAt"] = row.finishedAt
        rec["durationMs"] = row.durationMs
        await save(rec)
    }

    private func readWatchState(_ itemID: String) async -> WatchState? {
        let uid = localUserID
        return (try? await AppDatabase.shared.dbQueue.read { db in
            try WatchState
                .filter(Column("userID") == uid && Column("itemID") == itemID)
                .fetchOne(db)
        }) ?? nil
    }

    // MARK: - My List

    private func pushMyList(_ itemID: String) async {
        let uid = localUserID
        let entry = (try? await AppDatabase.shared.dbQueue.read { db in
            try MyListEntry
                .filter(Column("userID") == uid && Column("itemID") == itemID)
                .fetchOne(db)
        }) ?? nil
        let rid = recordID("ml", itemID)
        guard let entry else { await delete(rid); return }
        let rec = CKRecord(recordType: "MyListEntry", recordID: rid)
        rec["userID"] = cid
        rec["itemID"] = itemID
        rec["addedAt"] = entry.addedAt
        await save(rec)
    }

    // MARK: - User Rating

    private func pushUserRating(_ itemID: String) async {
        let uid = localUserID
        let rating = (try? await AppDatabase.shared.dbQueue.read { db in
            try UserRating
                .filter(Column("userID") == uid && Column("itemID") == itemID)
                .fetchOne(db)
        }) ?? nil
        let rid = recordID("ur", itemID)
        guard let rating else { await delete(rid); return }
        let rec = CKRecord(recordType: "UserRating", recordID: rid)
        rec["userID"] = cid
        rec["itemID"] = itemID
        rec["liked"] = rating.liked ? 1 : 0
        rec["ratedAt"] = rating.ratedAt
        await save(rec)
    }

    // MARK: - Stopped shows

    private func pushStopped(_ mergeKey: String) async {
        let set = Set(UserDefaults.standard.stringArray(forKey: "stoppedShows-\(localUserID)") ?? [])
        let rid = recordID("st", mergeKey)
        guard set.contains(mergeKey) else { await delete(rid); return }
        let rec = CKRecord(recordType: "StoppedShow", recordID: rid)
        rec["userID"] = cid
        rec["mergeKey"] = mergeKey
        rec["stoppedAt"] = Int(Date().timeIntervalSince1970)
        await save(rec)
    }

    // MARK: - Torrent choice (encrypted: magnet/infoHash are sensitive)

    private func pushTorrentChoice(_ watchKey: String) async {
        let key = "torrentChoice-\(localUserID)-\(watchKey)"
        let rid = recordID("tc", watchKey)
        guard let data = UserDefaults.standard.data(forKey: key) else { await delete(rid); return }
        guard let blob = try? CryptoEnvelope.seal(data, userID: cryptoID) else { return }
        let rec = CKRecord(recordType: "TorrentChoice", recordID: rid)
        rec["userID"] = cid
        rec["watchKey"] = watchKey
        rec["blob"] = blob
        await save(rec)
    }

    // NOTE: el control parental es LOCAL-ONLY a propósito (seguridad del menor): no
    // se sube ni se aplica desde CloudKit, así no puede filtrarse entre perfiles que
    // compartan un Apple ID. Ver ParentalStore.

    // MARK: - Vocabulary (debounced; merged by maximum on apply)

    private var pendingVocab: Set<String> = []
    private var vocabFlushScheduled = false

    private func scheduleVocabPush(_ lang: String) {
        pendingVocab.insert(lang)
        guard !vocabFlushScheduled else { return }
        vocabFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await self?.flushVocab()
        }
    }

    private func flushVocab() async {
        let langs = pendingVocab
        pendingVocab.removeAll()
        vocabFlushScheduled = false
        for lang in langs { await pushVocab(lang) }
    }

    private func pushVocab(_ lang: String) async {
        let key = "vocab.\(localUserID).\(lang.lowercased())"
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int],
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let rec = CKRecord(recordType: "VocabState", recordID: recordID("vc", lang))
        rec["userID"] = cid
        rec["lang"] = lang
        rec["counts"] = data
        rec["updatedAt"] = Int(Date().timeIntervalSince1970)
        await save(rec)
    }

    // MARK: - Subtitle reference (OpenSubtitles file_id, encrypted)

    private func pushSubtitleRef(_ watchKey: String, _ lang: String) async {
        let key = "subRef-\(localUserID)-\(watchKey)-\(lang)"
        let rid = recordID("sr", "\(watchKey)|\(lang)")
        guard let data = UserDefaults.standard.data(forKey: key) else { await delete(rid); return }
        guard let blob = try? CryptoEnvelope.seal(data, userID: cryptoID) else { return }
        let rec = CKRecord(recordType: "SubtitleRef", recordID: rid)
        rec["userID"] = cid
        rec["watchKey"] = watchKey
        rec["lang"] = lang
        rec["blob"] = blob
        await save(rec)
    }

    // MARK: - Trakt token (encrypted: OAuth access/refresh tokens)

    private func pushTraktToken() async {
        let rid = recordID("tk", "token")
        guard let data = Keychain.getData("traktTokens-\(localUserID)") else { await delete(rid); return }
        guard let blob = try? CryptoEnvelope.seal(data, userID: cryptoID) else { return }
        let rec = CKRecord(recordType: "TraktToken", recordID: rid)
        rec["userID"] = cid
        rec["blob"] = blob
        await save(rec)
    }

    // MARK: - Per-profile preferences (audio/subtitle/HUD, cifrado; un record por perfil)

    private func pushPrefs() async {
        let snap = await MainActor.run { SettingsStore.shared.prefsSnapshot() }
        guard let json = try? JSONSerialization.data(withJSONObject: snap.dict),
              let blob = try? CryptoEnvelope.seal(json, userID: cryptoID) else { return }
        await ensureZone()
        let rid = recordID("pf", "prefs")
        let rec = (try? await db.record(for: rid)) ?? CKRecord(recordType: "Prefs", recordID: rid)
        rec["userID"] = cid
        rec["blob"] = blob
        rec["updatedAt"] = snap.updatedAt
        await save(rec)
    }

    private func applyPrefs(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let blob = r["blob"] as? Data,
              let data = try? CryptoEnvelope.open(blob, userID: cryptoID),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        let updatedAt = r["updatedAt"] as? Int ?? 0
        await MainActor.run { SettingsStore.shared.applyRemotePrefs(dict, updatedAt: updatedAt) }
    }

    // MARK: - Remote → local

    private func fetchZoneChanges() async {
        var token = loadToken()
        var changed = false
        while true {
            do {
                let result = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, res) in result.modificationResultsByID {
                    if case .success(let mod) = res {
                        await apply(record: mod.record)
                        changed = true
                    }
                }
                for deletion in result.deletions {
                    await applyDeletion(recordID: deletion.recordID)
                    changed = true
                }
                token = result.changeToken
                saveToken(token)
                if !result.moreComing { break }
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                saveToken(nil)
                continue
            } catch let error as CKError where error.code == .zoneNotFound {
                break
            } catch {
                toast(tr(L.toastSyncFailed), "exclamationmark.icloud")
                break
            }
        }
        if changed {
            // Silent: applying remote data updates the UI; no toast on every change.
            await MainActor.run { SyncStatus.shared.generation += 1 }
        }
    }

    private func apply(record: CKRecord) async {
        switch record.recordType {
        case "WatchState": await applyWatchState(record)
        case "MyListEntry": await applyMyList(record)
        case "UserRating": await applyUserRating(record)
        case "StoppedShow": await applyStopped(record)
        case "TorrentChoice": await applyTorrentChoice(record)
        case "VocabState": await applyVocab(record)
        case "SubtitleRef": await applySubtitleRef(record)
        case "TraktToken": await applyTraktToken(record)
        case "Prefs": await applyPrefs(record)
        case "Profiles": await applyProfiles(record)
        case "Account": applyAccountRecord(record); await applyAccountConfig(record)
        default: break
        }
    }

    // MARK: - Account: shared crypto key + device-wide global config

    /// Fixed name (NOT keyed by user id): the global config is account-wide and the
    /// private DB already scopes it to the iCloud account, so every device of the
    /// same person resolves the same record.
    private func accountRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: "lumora-account", zoneID: zoneID)
    }

    // MARK: - Profiles (lista del hogar, cifrada; un record fijo por cuenta)

    private func profilesRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: "lumora-profiles", zoneID: zoneID)
    }

    private func pushProfiles() async {
        let snap = await MainActor.run { ProfileStore.shared.snapshot() }
        guard let json = try? JSONEncoder().encode(snap.profiles),
              let blob = try? CryptoEnvelope.seal(json, userID: cryptoID) else { return }
        await ensureZone()
        let rid = profilesRecordID()
        let rec = (try? await db.record(for: rid)) ?? CKRecord(recordType: "Profiles", recordID: rid)
        rec["blob"] = blob
        rec["updatedAt"] = snap.updatedAt
        await save(rec)
    }

    private func applyProfiles(_ r: CKRecord) async {
        guard let blob = r["blob"] as? Data,
              let data = try? CryptoEnvelope.open(blob, userID: cryptoID),
              let list = try? JSONDecoder().decode([AppProfile].self, from: data) else { return }
        let updatedAt = r["updatedAt"] as? Int ?? 0
        await MainActor.run { ProfileStore.shared.applyRemote(list, updatedAt: updatedAt) }
    }

    /// Global config keys (non-secret config + secrets) kept in the user-independent
    /// keychain; serialized (encrypted) into the Account record for cross-device.
    private static let globalKeys = [
        "prowlarrURL", "torrServerURL", "osUser", "aiProvider", "aiBaseURL", "aiModel",
        "discoverEnabled", "autoBestSource", "isConfigured", "cacheLimitGB",
        "tmdbKey", "prowlarrKey", "osKey", "osPass", "aiKey", "traktClientID",
        "traktClientSecret", "plexAccountToken", "plexToken-legacy",
    ]

    /// At sync start: adopt the shared crypto key + global config from CloudKit; if
    /// none exists yet, publish this device's. The key MUST be installed before the
    /// encrypted per-user records (torrent/parental/subtitle) are applied.
    private func syncAccount() async {
        let remote = try? await db.record(for: accountRecordID())
        if let remote {
            applyAccountRecord(remote)          // adopt the shared crypto key
            await applyAccountConfig(remote)    // apply remote config (sets present keys only)
        }
        // A CONFIGURED device publishes/refreshes its config so the record is
        // never left empty by a device that synced while still in onboarding.
        let configured = Keychain.getSecret("tmdbKey") != nil
        let remoteHasConfig = (remote?["config"] as? Data) != nil
        if configured && !remoteHasConfig {
            await pushAccount()
        }
    }

    private func applyAccountRecord(_ r: CKRecord) {
        if let keyData = r["cryptoKey"] as? Data { CryptoEnvelope.installKey(keyData, userID: cryptoID) }
    }

    private func applyAccountConfig(_ r: CKRecord) async {
        guard let blob = r["config"] as? Data,
              let data = try? CryptoEnvelope.open(blob, userID: cryptoID),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        // Only announce when THIS device transitions to configured (i.e. it just
        // got set up from another device) — not on every routine re-apply.
        let wasConfigured = Keychain.getSecret("isConfigured") == "1"
        for (k, v) in dict {
            if k == "servers" {
                if let d = Data(base64Encoded: v) { Keychain.setSecretData(d, for: "servers") }
            } else if k.hasPrefix("s.") {
                Keychain.setSecret(v, for: String(k.dropFirst(2)))
            }
        }
        await MainActor.run {
            SettingsStore.shared.reloadGlobalsFromStore()
            SyncStatus.shared.generation += 1
            let nowConfigured = Keychain.getSecret("isConfigured") == "1"
            if !wasConfigured && nowConfigured {
                ToastCenter.shared.show(tr(L.toastConfigDown), icon: "icloud.and.arrow.down")
            }
        }
    }

    private var accountPushScheduled = false
    private func pushAccountDebounced() {
        guard !accountPushScheduled else { return }
        accountPushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.pushAccount()
        }
    }

    private func pushAccount() async {
        accountPushScheduled = false
        let configured = Keychain.getSecret("tmdbKey") != nil
        await ensureZone()
        let rid = accountRecordID()
        let existing = try? await db.record(for: rid)
        // An unconfigured device must NOT create an empty record (it would pre-empt
        // a configured device, which would then just adopt the empty config).
        if !configured && existing == nil { return }
        let rec = existing ?? CKRecord(recordType: "Account", recordID: rid)
        rec["userID"] = cid
        // Converge on ONE key per account: keep the published one if it exists.
        if let remoteKey = rec["cryptoKey"] as? Data {
            CryptoEnvelope.installKey(remoteKey, userID: cryptoID)
        } else {
            rec["cryptoKey"] = CryptoEnvelope.rawKey(userID: cryptoID)
        }
        // Only a configured device writes the config blob (never overwrite with empty).
        var wroteConfig = false
        if configured,
           let data = currentGlobalConfigData(),
           let blob = try? CryptoEnvelope.seal(data, userID: cryptoID) {
            rec["config"] = blob
            wroteConfig = true
        }
        await save(rec)
        if wroteConfig { toast(tr(L.toastConfigUp), "icloud.and.arrow.up") }
    }

    private func currentGlobalConfigData() -> Data? {
        var dict: [String: String] = [:]
        var keys = Self.globalKeys
        if let serversData = Keychain.getSecretData("servers") {
            dict["servers"] = serversData.base64EncodedString()
            if let decoded = try? JSONDecoder().decode([PlexServerRef].self, from: serversData) {
                keys += decoded.map { "plexToken-\($0.id)" }
            }
        }
        for k in keys { if let v = Keychain.getSecret(k) { dict["s.\(k)"] = v } }
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    private func applyWatchState(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let itemID = r["itemID"] as? String else { return }
        let uid = localUserID
        let remote = WatchState(
            userID: uid,
            itemID: itemID,
            isEpisode: (r["isEpisode"] as? Int ?? 0) == 1,
            refID: r["refID"] as? String,
            viewOffsetMs: r["viewOffsetMs"] as? Int ?? 0,
            viewCount: r["viewCount"] as? Int ?? 0,
            lastViewedAt: r["lastViewedAt"] as? Int ?? 0,
            finishedAt: r["finishedAt"] as? Int,
            durationMs: r["durationMs"] as? Int
        )
        try? await AppDatabase.shared.dbQueue.write { db in
            let local = try WatchState
                .filter(Column("userID") == uid && Column("itemID") == itemID)
                .fetchOne(db)
            if let local, local.lastViewedAt > remote.lastViewedAt { return } // local más reciente gana
            try remote.save(db)
        }
    }

    private func applyMyList(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let itemID = r["itemID"] as? String else { return }
        let uid = localUserID
        let addedAt = r["addedAt"] as? Int ?? Int(Date().timeIntervalSince1970)
        try? await AppDatabase.shared.dbQueue.write { db in
            try MyListEntry(userID: uid, itemID: itemID, addedAt: addedAt).save(db)
        }
    }

    private func applyUserRating(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let itemID = r["itemID"] as? String else { return }
        let uid = localUserID
        let liked = (r["liked"] as? Int ?? 0) == 1
        let ratedAt = r["ratedAt"] as? Int ?? Int(Date().timeIntervalSince1970)
        try? await AppDatabase.shared.dbQueue.write { db in
            let local = try UserRating
                .filter(Column("userID") == uid && Column("itemID") == itemID)
                .fetchOne(db)
            if let local, local.ratedAt > ratedAt { return }
            try UserRating(userID: uid, itemID: itemID, liked: liked, ratedAt: ratedAt).save(db)
        }
    }

    private func applyStopped(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let mergeKey = r["mergeKey"] as? String else { return }
        let uid = localUserID
        await MainActor.run {
            var set = Set(UserDefaults.standard.stringArray(forKey: "stoppedShows-\(uid)") ?? [])
            set.insert(mergeKey)
            UserDefaults.standard.set(Array(set), forKey: "stoppedShows-\(uid)")
            SyncStatus.shared.generation += 1
        }
    }

    private func applyTorrentChoice(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let watchKey = r["watchKey"] as? String,
              let blob = r["blob"] as? Data,
              let data = try? CryptoEnvelope.open(blob, userID: cryptoID) else { return }
        UserDefaults.standard.set(data, forKey: "torrentChoice-\(localUserID)-\(watchKey)")
    }

    private func applyVocab(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let lang = r["lang"] as? String,
              let data = r["counts"] as? Data,
              let remote = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int] else { return }
        let uid = localUserID
        await MainActor.run {
            VocabularyStore.shared.mergeRemote(remote, userID: uid, lang: lang)
            SyncStatus.shared.generation += 1
        }
    }

    private func applySubtitleRef(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let watchKey = r["watchKey"] as? String,
              let lang = r["lang"] as? String, let blob = r["blob"] as? Data,
              let data = try? CryptoEnvelope.open(blob, userID: cryptoID) else { return }
        UserDefaults.standard.set(data, forKey: "subRef-\(localUserID)-\(watchKey)-\(lang)")
    }

    private func applyTraktToken(_ r: CKRecord) async {
        guard r["userID"] as? String == cid, let blob = r["blob"] as? Data,
              let data = try? CryptoEnvelope.open(blob, userID: cryptoID) else { return }
        Keychain.setData(data, for: "traktTokens-\(localUserID)")
        await MainActor.run { SyncStatus.shared.generation += 1 }
    }

    private func applyDeletion(recordID: CKRecord.ID) async {
        guard let parsed = parse(recordName: recordID.recordName),
              parsed.userID == cid else { return }
        let uid = localUserID, itemID = parsed.itemID
        switch parsed.type {
        case "ws", "ml", "ur":
            let table = ["ws": "watchState", "ml": "myList", "ur": "userRating"][parsed.type]!
            try? await AppDatabase.shared.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE userID = ? AND itemID = ?",
                    arguments: [uid, itemID]
                )
            }
        case "st":
            await MainActor.run {
                var set = Set(UserDefaults.standard.stringArray(forKey: "stoppedShows-\(uid)") ?? [])
                set.remove(itemID)
                UserDefaults.standard.set(Array(set), forKey: "stoppedShows-\(uid)")
                SyncStatus.shared.generation += 1
            }
        case "tc":
            UserDefaults.standard.removeObject(forKey: "torrentChoice-\(uid)-\(itemID)")
        case "sr":
            let parts = itemID.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                UserDefaults.standard.removeObject(forKey: "subRef-\(uid)-\(parts[0])-\(parts[1])")
            }
        case "tk":
            Keychain.delete("traktTokens-\(uid)")
            await MainActor.run { SyncStatus.shared.generation += 1 }
        default:
            break
        }
    }

    // MARK: - CloudKit helpers

    private func ensureZone() async {
        guard !zoneEnsured else { return }
        do {
            _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        } catch {
            // Idempotente; si falla, los saves reintentarán. Marcamos para no spamear.
        }
        zoneEnsured = true
    }

    private func save(_ record: CKRecord) async {
        await ensureZone()
        do {
            _ = try await db.modifyRecords(saving: [record], deleting: [],
                                           savePolicy: .changedKeys, atomically: false)
        } catch {
            // best-effort; el próximo cambio o pull reconcilia.
        }
    }

    private func delete(_ recordID: CKRecord.ID) async {
        do {
            _ = try await db.modifyRecords(saving: [], deleting: [recordID],
                                           savePolicy: .changedKeys, atomically: false)
        } catch {
            // si no existía, no pasa nada.
        }
    }

    // MARK: - Record name encoding (reversible, para enrutar borrados)

    private func recordID(_ type: String, _ itemID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type).\(b64(cid)).\(b64(itemID))", zoneID: zoneID)
    }

    private nonisolated func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated func unb64(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private nonisolated func parse(recordName: String) -> (type: String, userID: String, itemID: String)? {
        let parts = recordName.split(separator: ".")
        guard parts.count == 3,
              let u = unb64(String(parts[1])),
              let i = unb64(String(parts[2])) else { return nil }
        return (String(parts[0]), u, i)
    }

    // MARK: - Change token (device-local, per perfil — NUNCA se sincroniza)

    private nonisolated var tokenKey: String { "ckZoneToken-\(localUserID)" }

    private func loadToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveToken(_ token: CKServerChangeToken?) {
        guard let token else { UserDefaults.standard.removeObject(forKey: tokenKey); return }
        let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: tokenKey)
    }
}
#endif
