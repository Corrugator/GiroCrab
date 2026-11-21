import Foundation
import GiroCrabCore

// MARK: Enable Banking application per bank login via iCloud Keychain (#962)

extension AppModel {
    /// What to do with the logins' assignments.
    enum EnableBankingLoginShare {
        /// The vault opened: take over what other devices changed, share what changed here.
        case open
        /// Something was saved here: only share, never take over (the store still holds the old state).
        case shareOnly
        /// The user saved this login's application: share it even over a change from another device.
        case force(Int64)
    }

    /// Same condition as the default application (`sharesEnableBankingKey`).
    private var sharesEnableBankingLogins: Bool {
        VaultKeyManager.shared.syncViaICloudKeychain && !demoActive && vault != nil
    }

    /// Reconciles the logins' applications with the store. Runs after the
    /// default application was reconciled: taking over a new default pins the
    /// logins to the old one first (`pin_default_app`), and that is what gets shared.
    func syncEnableBankingLogins(_ mode: EnableBankingLoginShare) {
        guard sharesEnableBankingLogins, let vault else { return }
        let store = enableBankingLoginStore
        // the keychain query can block (iCloud Keychain): never on the main thread
        Task { [weak self] in
            let (stored, apps) = await Task.detached(priority: .utility) { () -> ([String: String], [String: EnableBankingApp]) in
                let logins = store.loadLogins()
                var apps: [String: EnableBankingApp] = [:]
                for id in Set(logins.values) where !id.isEmpty {
                    if let app = store.loadApp(id: id), app.isComplete { apps[id] = app }
                }
                return (logins, apps)
            }.value
            guard let self, self.vault === vault, self.sharesEnableBankingLogins else { return }
            self.applyEnableBankingLogins(mode, stored: stored, apps: apps, vault: vault)
        }
    }

    private func applyEnableBankingLogins(_ mode: EnableBankingLoginShare, stored: [String: String],
                                          apps: [String: EnableBankingApp], vault: Vault) {
        guard let logins = try? vault.listEnableBankingLogins() else { return }
        var shared = stored
        var uploads: [EnableBankingApp] = []
        // marked as shared only once the store has them (see `markUploadedEnableBankingLogins`)
        var uploaded: [(id: Int64, app: String)] = []
        var assigned: [(bank: String, applicationID: String)] = []
        var conflicts: [String] = []
        for login in logins {
            let forced: Bool
            if case .force(let id) = mode { forced = id == login.connectionId } else { forced = false }
            var adopting = false
            if case .open = mode { adopting = true }
            let action = EnableBankingLoginSync.filter(
                EnableBankingLoginSync.reconcile(here: login.applicationId, synced: login.syncedApplicationId,
                                                 store: stored[login.syncKey]),
                here: login.applicationId, forced: forced, adopting: adopting)
            let bank = connections.first { $0.id == login.connectionId }?.displayName ?? ""
            switch action {
            case .none:
                continue
            case .conflict:
                conflicts.append(bank)
            case .markSynced(let app):
                markEnableBankingLogin(login.connectionId, app, vault: vault)
            case .upload(let app):
                if !app.isEmpty {
                    let pem = ((try? vault.connectionEnableBankingKey(connectionId: login.connectionId)) ?? nil) ?? ""
                    let full = EnableBankingApp(applicationID: app, pem: pem)
                    guard full.isComplete else { continue }
                    uploads.append(full)
                }
                shared[login.syncKey] = app
                uploaded.append((login.connectionId, app))
            case .adopt(let app):
                guard adoptEnableBankingLogin(login.connectionId, app, apps: apps, vault: vault) else { continue }
                markEnableBankingLogin(login.connectionId, app, vault: vault)
                assigned.append((bank, app))
            }
        }
        if !uploaded.isEmpty {
            let store = enableBankingLoginStore
            let logins = shared
            let keys = uploads
            let marks = uploaded
            Task.detached(priority: .utility) { [weak self] in
                do {
                    // the keys first: a device that sees the assignment must find its key
                    for app in keys { try store.saveApp(app) }
                    try store.saveLogins(logins)
                } catch {
                    // no iCloud Keychain here: the logins keep their applications anyway. Not
                    // marked as shared, so the next sync uploads them again instead of taking
                    // over the store's older state.
                    enableBankingKeyLog.info("logins upload failed: \((error as NSError).code, privacy: .public)")
                    return
                }
                await self?.markUploadedEnableBankingLogins(marks, vault: vault)
            }
        }
        if !assigned.isEmpty { reloadSettings() }
        if !AppDefaults.store.bool(forKey: EnableBankingKeySync.noticeSuppressedKey),
           let notice = EnableBankingLoginSync.notice(assigned: assigned, conflicts: conflicts) {
            enableBankingLoginNotice = notice
        }
    }

    /// Gives the login the application another device chose; false when its
    /// key has not arrived yet (iCloud lags) or does not sign.
    private func adoptEnableBankingLogin(_ id: Int64, _ app: String, apps: [String: EnableBankingApp], vault: Vault) -> Bool {
        var pem = ""
        if !app.isEmpty {
            guard let stored = apps[app] else { return false }
            pem = stored.pem
        }
        do {
            _ = try vault.setConnectionEnableBankingApp(connectionId: id, applicationId: app, privateKeyPem: pem)
            return true
        } catch {
            Self.debugLog("enablebanking login adopt failed: \(error)")
            return false
        }
    }

    /// After the store took the uploads: remembers them as shared, but only for
    /// logins that still use the uploaded application (changed meanwhile = the
    /// next sync shares the newer one).
    private func markUploadedEnableBankingLogins(_ marks: [(id: Int64, app: String)], vault: Vault) {
        guard self.vault === vault, let current = try? vault.listEnableBankingLogins() else { return }
        for mark in marks where current.first(where: { $0.connectionId == mark.id })?.applicationId == mark.app {
            markEnableBankingLogin(mark.id, mark.app, vault: vault)
        }
    }

    private func markEnableBankingLogin(_ id: Int64, _ app: String, vault: Vault) {
        do {
            try vault.markEnableBankingLoginSynced(connectionId: id, applicationId: app)
        } catch {
            Self.debugLog("enablebanking login mark failed: \(error)")
        }
    }
}
