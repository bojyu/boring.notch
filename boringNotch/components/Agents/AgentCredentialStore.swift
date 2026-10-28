//
//  AgentCredentialStore.swift
//  boringNotch
//
//  The Dmit hub's password, kept in this app's own keychain item: a sandboxed app cannot read agent-hud's.
//

import Foundation
import Security

enum AgentCredentialStore {
    private static let service = "theboringteam.boringnotch.agents.dmit"

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
        item[kSecAttrLabel as String] = "Boring Notch · Dmit quota hub"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: user]
    }
}
