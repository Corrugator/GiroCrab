import Foundation
import Security

// Which Enable Banking application each bank login signs with, shared between
// devices through the iCloud Keychain (#962). The default application keeps its
// own entry and logic (`EnableBankingKeySync`); this only adds the logins'
// own applications next to it.

/// Where the logins' applications are shared between devices.
protocol EnableBankingLoginStore {
    /// An application by its ID (with its key), saved by any device.
    func loadApp(id: String) -> EnableBankingApp?
    func saveApp(_ app: EnableBankingApp) throws
    /// Login (`sync_key` from the core) → application ID; `""` = back to the default application.
    func loadLogins() -> [String: String]
    func saveLogins(_ logins: [String: String]) throws
}

/// The iCloud Keychain: same service as the default application, one item per
/// application (`app.<id>`) plus one item with the assignments (`logins`).
struct KeychainEnableBankingLoginStore: EnableBankingLoginStore {
    private let loginsAccount = "logins"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainEnableBankingKeyStore.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func load(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        enableBankingKeyLog.info("keychain load (login): status \(status, privacy: .public)")
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    private func save(_ data: Data, _ account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        enableBankingKeyLog.info("keychain save (login): status \(status, privacy: .public)")
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func appAccount(_ id: String) -> String {
        "app." + id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadApp(id: String) -> EnableBankingApp? {
        load(Self.appAccount(id)).flatMap { try? JSONDecoder().decode(EnableBankingApp.self, from: $0) }
    }

    func saveApp(_ app: EnableBankingApp) throws {
        try save(JSONEncoder().encode(app), Self.appAccount(app.applicationID))
    }

    func loadLogins() -> [String: String] {
        load(loginsAccount).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func saveLogins(_ logins: [String: String]) throws {
        try save(JSONEncoder().encode(logins), loginsAccount)
    }
}

/// Shown after logins took over applications from another device (never a key).
struct EnableBankingLoginNotice: Identifiable, Equatable {
    let id = UUID()
    /// "Bank: shortened application ID" (or the default application).
    var assigned: [String]
    /// Logins changed here and on another device: this device kept its own.
    var conflicts: [String]

    var message: String {
        var lines: [String] = []
        if !assigned.isEmpty {
            lines.append(String(localized: "Ein anderes Gerät hat Bankzugängen eine eigene Enable-Banking-Anwendung gegeben. Beim nächsten Abruf ist auf diesem Gerät eine neue Zustimmung nötig."))
            lines.append(contentsOf: assigned)
        }
        if !conflicts.isEmpty {
            lines.append(String(localized: "Auf diesem und einem anderen Gerät wurde eine andere Anwendung gewählt. Hier bleibt die bisherige, bis Sie sie im Bankzugang erneut speichern: \(conflicts.joined(separator: ", "))"))
        }
        return lines.joined(separator: "\n")
    }
}

enum EnableBankingLoginSync {
    enum Action: Equatable {
        case none
        /// Already the same here and in the store; only remember it as shared.
        case markSynced(String)
        /// Store → this login (another device changed it).
        case adopt(String)
        /// This login → store (changed here).
        case upload(String)
        /// Changed here and on another device: keep it here, tell the user.
        case conflict
    }

    /// One login, three-way: `here` its application (`""` = the default),
    /// `synced` what this device last shared (nil = never), `store` what the
    /// keychain holds (nil = no entry). A change on either side wins over an
    /// unchanged one; a change on both is never silently replaced.
    static func reconcile(here: String, synced: String?, store: String?) -> Action {
        let here = here.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = store?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return here.isEmpty ? .none : .upload(here)
        }
        if store == here { return synced == here ? .none : .markSynced(here) }
        // never shared and on the default: nothing was decided here yet
        if here == (synced ?? "") { return .adopt(store) }
        if store == synced { return .upload(here) }
        return .conflict
    }

    /// `action` for how the sync was triggered: only on opening a vault
    /// (`adopting`) is anything taken over; a login the user just saved
    /// (`forced`) is shared even over another device's change.
    static func filter(_ action: Action, here: String, forced: Bool, adopting: Bool) -> Action {
        switch action {
        case .none, .markSynced:
            return action
        case .upload:
            return action
        case .adopt, .conflict:
            if forced { return .upload(here.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return adopting ? action : .none
        }
    }

    static func shortID(_ id: String) -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.count > 8 ? String(id.prefix(8)) + "…" : id
    }

    static func notice(assigned: [(bank: String, applicationID: String)], conflicts: [String]) -> EnableBankingLoginNotice? {
        guard !assigned.isEmpty || !conflicts.isEmpty else { return nil }
        let lines = assigned.map { item in
            item.applicationID.isEmpty
                ? String(localized: "\(item.bank): Standard-Anwendung")
                : String(localized: "\(item.bank): Anwendung \(shortID(item.applicationID))")
        }
        return EnableBankingLoginNotice(assigned: lines, conflicts: conflicts)
    }
}
