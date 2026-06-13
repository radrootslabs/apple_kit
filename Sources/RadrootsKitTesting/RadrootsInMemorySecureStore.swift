import Foundation
import RadrootsKit

public final class RadrootsInMemorySecureStore: RadrootsSecureStore, @unchecked Sendable {
    private struct Entry: Sendable {
        let value: Data
        let policy: RadrootsSecretAccessPolicy
    }

    private let lock = NSLock()
    private var entries: [RadrootsSecureStoreKey: Entry]

    public init() {
        self.entries = [:]
    }

    public func put(
        _ value: Data,
        for key: RadrootsSecureStoreKey,
        policy: RadrootsSecretAccessPolicy
    ) throws {
        let normalizedKey = try key.normalized()
        lock.lock()
        defer { lock.unlock() }
        entries[normalizedKey] = Entry(value: value, policy: policy)
    }

    public func contains(_ key: RadrootsSecureStoreKey) throws -> Bool {
        let normalizedKey = try key.normalized()
        lock.lock()
        defer { lock.unlock() }
        return entries[normalizedKey] != nil
    }

    public func get(_ key: RadrootsSecureStoreKey) throws -> Data? {
        let normalizedKey = try key.normalized()
        lock.lock()
        defer { lock.unlock() }
        return entries[normalizedKey]?.value
    }

    public func delete(_ key: RadrootsSecureStoreKey) throws {
        let normalizedKey = try key.normalized()
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: normalizedKey)
    }

    public func deleteNamespace(_ namespace: String) throws {
        let normalizedNamespace = try RadrootsSecureStoreKey.normalizedNamespace(namespace)
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { key, _ in
            key.namespace != normalizedNamespace
        }
    }

    public func policy(for key: RadrootsSecureStoreKey) throws -> RadrootsSecretAccessPolicy? {
        let normalizedKey = try key.normalized()
        lock.lock()
        defer { lock.unlock() }
        return entries[normalizedKey]?.policy
    }

    public func keys() -> [RadrootsSecureStoreKey] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted {
            if $0.namespace == $1.namespace {
                return $0.name < $1.name
            }
            return $0.namespace < $1.namespace
        }
    }
}
