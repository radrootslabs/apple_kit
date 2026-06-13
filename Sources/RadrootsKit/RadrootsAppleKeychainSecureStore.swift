import Foundation
import Security

public final class RadrootsAppleKeychainSecureStore: RadrootsSecureStore, @unchecked Sendable {
    public let servicePrefix: String

    public init(servicePrefix: String = "org.radroots.kit.secure-store") {
        self.servicePrefix = servicePrefix
    }

    public func put(
        _ value: Data,
        for key: RadrootsSecureStoreKey,
        policy: RadrootsSecretAccessPolicy = .secureLocalSecret
    ) throws {
        try delete(key)

        var query = try baseQuery(for: key)
        query[kSecValueData as String] = value

        let mapping = keychainPolicyMapping(for: policy)
        if mapping.usesAccessControl {
            query[kSecAttrAccessControl as String] = try accessControl(for: mapping)
        } else {
            query[kSecAttrAccessible as String] = mapping.accessibilityConstant
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Self.mapStatus(status, defaultMessage: "keychain write failed")
        }
    }

    public func contains(_ key: RadrootsSecureStoreKey) throws -> Bool {
        var query = try baseQuery(for: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw Self.mapStatus(status, defaultMessage: "keychain presence check failed")
        }
        return true
    }

    public func get(_ key: RadrootsSecureStoreKey) throws -> Data? {
        var query = try baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Self.mapStatus(status, defaultMessage: "keychain read failed")
        }
        guard let data = result as? Data else {
            throw RadrootsAppleSecurityError.permanentFailure("keychain returned an invalid value type")
        }
        return data
    }

    public func delete(_ key: RadrootsSecureStoreKey) throws {
        let status = SecItemDelete(try baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status, defaultMessage: "keychain delete failed")
        }
    }

    public func deleteNamespace(_ namespace: String) throws {
        let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNamespace.isEmpty else {
            throw RadrootsAppleSecurityError.invalidRequest("secure store namespace cannot be empty")
        }
        let status = SecItemDelete(namespaceQuery(trimmedNamespace) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status, defaultMessage: "keychain namespace delete failed")
        }
    }

    func baseQuery(for key: RadrootsSecureStoreKey) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: try key.serviceName(servicePrefix: servicePrefix),
            kSecAttrAccount as String: key.name
        ]
    }

    func namespaceQuery(_ namespace: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(namespace)"
        ]
    }

    func accessibilityConstant(for policy: RadrootsSecretAccessPolicy) -> CFString {
        switch (policy.accessibility, policy.deviceLocalOnly) {
        case (.whenUnlocked, true):
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case (.whenUnlocked, false):
            kSecAttrAccessibleWhenUnlocked
        case (.afterFirstUnlock, true):
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case (.afterFirstUnlock, false):
            kSecAttrAccessibleAfterFirstUnlock
        }
    }

    func keychainPolicyMapping(for policy: RadrootsSecretAccessPolicy) -> RadrootsKeychainSecretPolicyMapping {
        RadrootsKeychainSecretPolicyMapping(
            accessibilityConstant: accessibilityConstant(for: policy),
            usesAccessControl: policy.userPresenceRequired,
            accessControlFlags: policy.userPresenceRequired ? .userPresence : []
        )
    }

    func accessControl(for policy: RadrootsSecretAccessPolicy) throws -> SecAccessControl {
        try accessControl(for: keychainPolicyMapping(for: policy))
    }

    func accessControl(for mapping: RadrootsKeychainSecretPolicyMapping) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            mapping.accessibilityConstant,
            mapping.accessControlFlags,
            &error
        ) else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "keychain access control initialization failed"
            throw RadrootsAppleSecurityError.invalidRequest(message)
        }
        return accessControl
    }

    static func mapStatus(_ status: OSStatus, defaultMessage: String) -> RadrootsAppleSecurityError {
        switch status {
        case errSecItemNotFound:
            .notFound(defaultMessage)
        case errSecAuthFailed:
            .permissionDenied(defaultMessage)
        case errSecInteractionNotAllowed:
            .transientFailure(defaultMessage)
        case errSecUserCanceled:
            .userCancelled(defaultMessage)
        case errSecNotAvailable:
            .unavailable(defaultMessage)
        default:
            .keychainStatus(status, defaultMessage)
        }
    }
}

struct RadrootsKeychainSecretPolicyMapping: Equatable {
    let accessibilityConstant: CFString
    let usesAccessControl: Bool
    let accessControlFlags: SecAccessControlCreateFlags

    static func == (
        lhs: RadrootsKeychainSecretPolicyMapping,
        rhs: RadrootsKeychainSecretPolicyMapping
    ) -> Bool {
        String(lhs.accessibilityConstant) == String(rhs.accessibilityConstant)
            && lhs.usesAccessControl == rhs.usesAccessControl
            && lhs.accessControlFlags == rhs.accessControlFlags
    }
}
