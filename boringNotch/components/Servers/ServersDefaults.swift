//
//  ServersDefaults.swift
//  boringNotch
//
//  Settings for the Servers tab: the servers a Beszel hub watches.
//

import Defaults
import Foundation
import Security

extension Defaults.Keys {
    /// Shows the Servers tab. Off by default; nothing is read while it is off.
    static let serversTabEnabled = Key<Bool>("serversTabEnabled", default: false)
    /// The notch reopens on the Servers tab when it was closed there, instead of going back to Home.
    static let serversStayOnTab = Key<Bool>("serversStayOnTab", default: true)
    /// The Beszel hub's address.
    static let serversHubURL = Key<String>("serversHubURL", default: "https://vps.bojyu.world/")
    /// The hub account's e-mail; its password is in the keychain (`ServerCredentialStore`).
    static let serversUser = Key<String>("serversUser", default: "")
}

/// The Beszel password, in this app's own keychain item.
enum ServerCredentialStore {
    private static let service = "theboringteam.boringnotch.servers.beszel"

    static func password(for user: String) -> String? {
        guard !user.isEmpty else { return nil }
        var query = baseQuery(user)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `password` for `user`; an empty password removes it.
    @discardableResult
    static func setPassword(_ password: String, for user: String) -> Bool {
        guard !user.isEmpty else { return false }
        SecItemDelete(baseQuery(user) as CFDictionary)
        guard !password.isEmpty else { return true }
        var item = baseQuery(user)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Boring Notch · Beszel"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: user]
    }
}
