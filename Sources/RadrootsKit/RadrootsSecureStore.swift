import Foundation

public enum RadrootsSecretAccessibility: Sendable, Equatable {
    case whenUnlocked
    case afterFirstUnlock
}

public struct RadrootsSecretAccessPolicy: Sendable, Equatable {
    public let accessibility: RadrootsSecretAccessibility
    public let deviceLocalOnly: Bool
    public let userPresenceRequired: Bool

    public init(
        accessibility: RadrootsSecretAccessibility,
        deviceLocalOnly: Bool,
        userPresenceRequired: Bool
    ) {
        self.accessibility = accessibility
        self.deviceLocalOnly = deviceLocalOnly
        self.userPresenceRequired = userPresenceRequired
    }

    public static let secureLocalSecret = Self(
        accessibility: .whenUnlocked,
        deviceLocalOnly: true,
        userPresenceRequired: false
    )

    public static let userPresenceLocalSecret = Self(
        accessibility: .whenUnlocked,
        deviceLocalOnly: true,
        userPresenceRequired: true
    )
}

public struct RadrootsSecureStoreKey: Hashable, Sendable {
    public let namespace: String
    public let name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    public func serviceName(servicePrefix: String) throws -> String {
        let trimmedPrefix = servicePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else {
            throw RadrootsAppleSecurityError.invalidRequest("secure store service prefix cannot be empty")
        }
        guard !trimmedNamespace.isEmpty else {
            throw RadrootsAppleSecurityError.invalidRequest("secure store namespace cannot be empty")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RadrootsAppleSecurityError.invalidRequest("secure store key name cannot be empty")
        }
        return "\(trimmedPrefix).\(trimmedNamespace)"
    }
}

public protocol RadrootsSecureStore: AnyObject, Sendable {
    func put(
        _ value: Data,
        for key: RadrootsSecureStoreKey,
        policy: RadrootsSecretAccessPolicy
    ) throws
    func get(_ key: RadrootsSecureStoreKey) throws -> Data?
    func delete(_ key: RadrootsSecureStoreKey) throws
    func deleteNamespace(_ namespace: String) throws
}

extension RadrootsSecureStore {
    public func put(_ value: Data, for key: RadrootsSecureStoreKey) throws {
        try put(value, for: key, policy: .secureLocalSecret)
    }
}
