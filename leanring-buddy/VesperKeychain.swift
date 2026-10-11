//
//  VesperKeychain.swift
//  leanring-buddy
//
//  Stores secrets (the Google text-to-speech API key) in the macOS Keychain
//  rather than in a file or UserDefaults. The key is pasted once into the
//  panel and never touches the repository or the app bundle.
//

import Foundation
import Security

enum VesperKeychain {
    private static let serviceName = "com.daivikchawla.vesper"

    static func readSecret(named secretName: String) -> String? {
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: secretName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var foundItem: CFTypeRef?
        guard SecItemCopyMatching(searchQuery as CFDictionary, &foundItem) == errSecSuccess,
              let secretData = foundItem as? Data else {
            return nil
        }
        return String(data: secretData, encoding: .utf8)
    }

    /// Saves the secret, replacing any previous value. An empty string deletes it.
    @discardableResult
    static func saveSecret(_ secretValue: String, named secretName: String) -> Bool {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: secretName
        ]
        SecItemDelete(itemQuery as CFDictionary)

        let trimmedSecretValue = secretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecretValue.isEmpty else { return true }

        var newItem = itemQuery
        newItem[kSecValueData as String] = Data(trimmedSecretValue.utf8)
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }
}
