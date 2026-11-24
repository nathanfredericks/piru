import Foundation
import Security

@MainActor
protocol SyncAccountStorage {
    func read<T: Decodable>(_ type: T.Type, at account: String) throws -> T?
    func write(_ value: some Encodable, at account: String) throws
    func remove(_ account: String) throws
}

/// Device credentials and synchronizable recovery codes occupy different services.
nonisolated struct SyncAccountKeychain: SyncAccountStorage {
    enum Failure: LocalizedError {
        case unavailable(OSStatus)
        case invalidData
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Keychain is temporarily unavailable. Unlock this device and try again.")
            case .invalidData: String(localized: "Journal Sync could not read the saved credential.")
            case .status: String(localized: "Journal Sync could not access Keychain.")
            }
        }
    }

    let service: String
    let synchronized: Bool

    private var accessibility: CFString {
        synchronized ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    init(namespace: String, synchronized: Bool = false) {
        self.synchronized = synchronized
        service = AppIdentity.bundleID + ".sync.v1." + namespace
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: synchronized,
        ]
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecUserCanceled, errSecAuthFailed:
            throw Failure.unavailable(status)
        default: throw Failure.status(status)
        }
    }

    func read<T: Decodable>(_ type: T.Type, at account: String) throws -> T? {
        let item = query(account)
        var q = item
        q[kSecAttrAccessible as String] = accessibility
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound {
            // Tighten an existing item's protection in place before reading its secret.
            var previous = item
            previous[kSecAttrAccessible as String] = synchronized ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let upgrade = SecItemUpdate(previous as CFDictionary, [kSecAttrAccessible: accessibility] as CFDictionary)
            if upgrade != errSecItemNotFound { try check(upgrade) }
            // A synchronizable item can arrive or be upgraded between the two queries.
            status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
        }
        try check(status)
        guard let bytes = result as? Data, let value = try? JSONDecoder().decode(type, from: bytes)
        else { throw Failure.invalidData }
        return value
    }

    func write(_ value: some Encodable, at account: String) throws {
        let data = try JSONEncoder().encode(value)
        let q = query(account)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessibility]
        let update = SecItemUpdate(q as CFDictionary, changes as CFDictionary)
        guard update == errSecItemNotFound else { return try check(update) }
        let add = q.merging(changes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(q as CFDictionary, changes as CFDictionary))
        } else {
            try check(status)
        }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}
