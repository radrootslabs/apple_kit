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

    public func normalized() throws -> Self {
        try Self(
            namespace: Self.normalizedNamespace(namespace),
            name: Self.normalizedName(name)
        )
    }

    public func serviceName(servicePrefix: String) throws -> String {
        try Self.serviceName(servicePrefix: servicePrefix, namespace: namespace)
    }

    public static func serviceName(servicePrefix: String, namespace: String) throws -> String {
        try "\(normalizedServicePrefix(servicePrefix)).\(normalizedNamespace(namespace))"
    }

    public static func normalizedServicePrefix(_ servicePrefix: String) throws -> String {
        let trimmedPrefix = servicePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else {
            throw RadrootsAppleSecurityError.invalidRequest("secure store service prefix cannot be empty")
        }
        return trimmedPrefix
    }

    public static func normalizedNamespace(_ namespace: String) throws -> String {
        let trimmedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNamespace.isEmpty else {
            throw RadrootsAppleSecurityError.invalidRequest("secure store namespace cannot be empty")
        }
        return trimmedNamespace
    }

    public static func normalizedName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw RadrootsAppleSecurityError.invalidRequest("secure store key name cannot be empty")
        }
        return trimmedName
    }
}

public protocol RadrootsSecureStore: AnyObject, Sendable {
    func put(
        _ value: Data,
        for key: RadrootsSecureStoreKey,
        policy: RadrootsSecretAccessPolicy
    ) throws
    func contains(_ key: RadrootsSecureStoreKey) throws -> Bool
    func get(_ key: RadrootsSecureStoreKey) throws -> Data?
    func delete(_ key: RadrootsSecureStoreKey) throws
    func deleteNamespace(_ namespace: String) throws
}

public extension RadrootsSecureStore {
    func put(_ value: Data, for key: RadrootsSecureStoreKey) throws {
        try put(value, for: key, policy: .secureLocalSecret)
    }
}
