import Foundation
import RadrootsKitTesting
import Testing

@testable import RadrootsKit

@Test func cancellationAfterImportRetainsCommittedKeyAndLegacyUntilExplicitRecovery() async throws {
    let key = RadrootsSecureStoreKey(namespace: "legacy", name: "selected_secret_hex")
    let store = CancelOnActiveReadStore()
    let legacy = Data(String(repeating: "01", count: 32).utf8)
    try store.put(legacy, for: key)
    let custody = try RadrootsIdentityCustody(
        configuration: RadrootsIdentityCustodyConfiguration(namespace: UUID().uuidString.lowercased()),
        secureStore: store, metadataStore: RadrootsInMemoryIdentityMetadataStore(),
        userPresence: RadrootsFakeUserPresence()
    )
    let task = Task { try await custody.migrateLegacyIdentity(from: key) }
    await #expect(throws: RadrootsIdentityCustodyError.cancelled) { try await task.value }
    let retained = await custody.snapshot()
    let expected = try #require(retained.identity?.publicKeyHex)
    #expect(retained.state == .unlocked)
    #expect(try store.get(key) == legacy)
    let recovered = try await custody.migrateLegacyIdentity(from: key, expectedPublicKeyHex: expected)
    #expect(recovered.identity == retained.identity)
    #expect(try store.get(key) == nil)
}

// The backing store synchronizes bytes; the lock protects the one-shot fault.
private final class CancelOnActiveReadStore: RadrootsSecureStore, @unchecked Sendable {
    private let backing = RadrootsInMemorySecureStore()
    private let lock = NSLock()
    private var shouldCancel = true

    func put(_ value: Data, for key: RadrootsSecureStoreKey, policy: RadrootsSecretAccessPolicy) throws {
        try backing.put(value, for: key, policy: policy)
    }
    func contains(_ key: RadrootsSecureStoreKey) throws -> Bool { try backing.contains(key) }
    func delete(_ key: RadrootsSecureStoreKey) throws { try backing.delete(key) }
    func deleteNamespace(_ namespace: String) throws { try backing.deleteNamespace(namespace) }
    func get(_ key: RadrootsSecureStoreKey) throws -> Data? {
        let value = try backing.get(key)
        lock.lock()
        let cancel = key.name == "active_secret_v1" && shouldCancel
        if cancel { shouldCancel = false }
        lock.unlock()
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return value
    }
}
