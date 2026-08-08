import Foundation
import Security

public final class RadrootsAppleKeychainSecureStore: RadrootsSecureStore, @unchecked Sendable {
    public let servicePrefix: String
    private let accessControlFactory: (RadrootsKeychainSecretPolicyMapping) throws -> SecAccessControl

    public init(servicePrefix: String = "org.radroots.kit.secure-store") {
        self.servicePrefix = servicePrefix
        accessControlFactory = Self.makeAccessControl(for:)
    }

    init(
        servicePrefix: String = "org.radroots.kit.secure-store",
        accessControlFactory: @escaping (RadrootsKeychainSecretPolicyMapping) throws -> SecAccessControl
    ) {
        self.servicePrefix = servicePrefix
        self.accessControlFactory = accessControlFactory
    }

    public func put(
        _ value: Data,
        for key: RadrootsSecureStoreKey,
        policy: RadrootsSecretAccessPolicy = .secureLocalSecret
    ) throws {
        let attributes = try mutationAttributes(value, policy: policy)
        var addQuery = try baseQuery(for: key)
        addQuery.merge(attributes) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            break
        default:
            throw Self.mapStatus(addStatus, defaultMessage: "keychain write failed")
        }

        let updateStatus = try SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw Self.mapStatus(updateStatus, defaultMessage: "keychain update failed")
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
        let status = try SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status, defaultMessage: "keychain delete failed")
        }
    }

    public func deleteNamespace(_ namespace: String) throws {
        let status = try SecItemDelete(namespaceQuery(namespace) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.mapStatus(status, defaultMessage: "keychain namespace delete failed")
        }
    }

    func baseQuery(for key: RadrootsSecureStoreKey) throws -> [String: Any] {
        let normalizedKey = try key.normalized()
        return try [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: normalizedKey.serviceName(servicePrefix: servicePrefix),
            kSecAttrAccount as String: normalizedKey.name,
        ]
    }

    func namespaceQuery(_ namespace: String) throws -> [String: Any] {
        try [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RadrootsSecureStoreKey.serviceName(
                servicePrefix: servicePrefix,
                namespace: namespace
            ),
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
        try accessControlFactory(mapping)
    }

    private func mutationAttributes(
        _ value: Data,
        policy: RadrootsSecretAccessPolicy
    ) throws -> [String: Any] {
        let mapping = keychainPolicyMapping(for: policy)
        var attributes: [String: Any] = [
            kSecValueData as String: value,
        ]
        if mapping.usesAccessControl {
            attributes[kSecAttrAccessControl as String] = try accessControl(for: mapping)
        } else {
            attributes[kSecAttrAccessible as String] = mapping.accessibilityConstant
        }
        return attributes
    }

    private static func makeAccessControl(for mapping: RadrootsKeychainSecretPolicyMapping) throws -> SecAccessControl {
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
