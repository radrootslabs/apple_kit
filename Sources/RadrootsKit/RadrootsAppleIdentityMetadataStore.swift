import Foundation

public final class RadrootsAppleIdentityMetadataStore: RadrootsIdentityMetadataStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let keyPrefix: String

    public init(
        namespace: String,
        userDefaults: UserDefaults = .standard,
        keyPrefix: String = "org.radroots.kit.identity"
    ) throws {
        self.userDefaults = userDefaults
        self.keyPrefix = try Self.normalizedPrefix(keyPrefix, namespace: namespace)
    }

    public func data(for slot: RadrootsIdentityMetadataSlot) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.data(forKey: key(for: slot))
    }

    public func put(_ data: Data, for slot: RadrootsIdentityMetadataSlot) throws {
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw RadrootsIdentityCustodyError.invalidMetadata
        }
        lock.lock()
        userDefaults.set(data, forKey: key(for: slot))
        lock.unlock()
    }

    public func delete(_ slot: RadrootsIdentityMetadataSlot) throws {
        lock.lock()
        userDefaults.removeObject(forKey: key(for: slot))
        lock.unlock()
    }

    func key(for slot: RadrootsIdentityMetadataSlot) -> String {
        "\(keyPrefix).\(slot.rawValue)"
    }

    private static func normalizedPrefix(_ value: String, namespace: String) throws -> String {
        let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty,
              prefix.utf8.count <= 128,
              !namespace.isEmpty,
              namespace.utf8.count <= 128,
              !prefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !namespace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw RadrootsIdentityCustodyError.invalidConfiguration
        }
        return "\(prefix).\(namespace)"
    }
}
