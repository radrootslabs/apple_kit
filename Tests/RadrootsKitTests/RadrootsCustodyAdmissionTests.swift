import Foundation
import RadrootsKitTesting
import Testing

@testable import RadrootsKit

@Test func guardedLegacyMigrationRejectsMetadataMismatchBeforeImportOrDeletion() async throws {
    let fixture = try AdmissionFixture()
    let legacy = Data(String(repeating: "01", count: 32).utf8)
    try fixture.secure.put(legacy, for: fixture.legacyKey)
    await #expect(throws: RadrootsIdentityCustodyError.inconsistentState) {
        try await fixture.custody.migrateLegacyIdentity(
            from: fixture.legacyKey, expectedPublicKeyHex: String(repeating: "ab", count: 32)
        )
    }
    #expect(await fixture.custody.snapshot().state == .absent)
    #expect(try fixture.secure.get(fixture.legacyKey) == legacy)
}

@Test func guardedLegacyReplayPreservesInstalledIdentityAndValidatesAbsentLegacy() async throws {
    let fixture = try AdmissionFixture()
    let installed = try await fixture.importIdentity()
    let record = try #require(installed.identity)
    let legacy = Data(String(repeating: "01", count: 32).utf8)
    try fixture.secure.put(legacy, for: fixture.legacyKey)
    await #expect(throws: RadrootsIdentityCustodyError.inconsistentState) {
        try await fixture.custody.migrateLegacyIdentity(
            from: fixture.legacyKey, expectedPublicKeyHex: String(repeating: "ab", count: 32)
        )
    }
    #expect(try fixture.secure.get(fixture.legacyKey) == legacy)
    let replayed = try await fixture.custody.migrateLegacyIdentity(
        from: fixture.legacyKey, expectedPublicKeyHex: record.publicKeyHex
    )
    #expect(replayed.identity == record)
    #expect(try fixture.secure.get(fixture.legacyKey) == nil)
    #expect(try await fixture.custody.migrateLegacyIdentity(
        from: fixture.legacyKey, expectedPublicKeyHex: record.publicKeyHex
    ).identity == record)
    try fixture.secure.put(Data(repeating: 0, count: 32), for: fixture.activeKey)
    await #expect(throws: RadrootsIdentityCustodyError.invalidSecret) {
        try await fixture.custody.migrateLegacyIdentity(
            from: fixture.legacyKey, expectedPublicKeyHex: record.publicKeyHex
        )
    }
    #expect(await fixture.custody.snapshot().identity == record)
}

@Test(arguments: ["", "ab", String(repeating: "AB", count: 32), String(repeating: "g", count: 64)])
func guardedLegacyMigrationRejectsNoncanonicalExpectedIdentity(expected: String) async throws {
    let fixture = try AdmissionFixture()
    await #expect(throws: RadrootsIdentityCustodyError.invalidMetadata) {
        try await fixture.custody.migrateLegacyIdentity(
            from: fixture.legacyKey, expectedPublicKeyHex: expected
        )
    }
    #expect(await fixture.custody.snapshot().state == .absent)
    #expect(fixture.secure.keys().isEmpty)
}

@Test func alreadyCancelledCustodyRequestNeverStartsPresenceOrCreatesKey() async throws {
    let fixture = try AdmissionFixture()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await fixture.custody.createIdentity()
    }
    await #expect(throws: RadrootsIdentityCustodyError.cancelled) { try await task.value }
    #expect(await fixture.presence.requests == 0)
    #expect(fixture.secure.keys().isEmpty)
    #expect(await fixture.custody.snapshot().state == .absent)
}

@Test(arguments: ["create", "import", "replace", "unlock", "export", "delete"])
func cancelledPresenceSuccessCannotAuthorizeCustodyEffects(operation: String) async throws {
    let fixture = try AdmissionFixture()
    if !["create", "import"].contains(operation) { _ = try await fixture.importIdentity() }
    if operation == "unlock" { await fixture.custody.lockIdentity() }
    let before = await fixture.custody.snapshot()
    let original = try fixture.secure.get(fixture.activeKey)
    await fixture.presence.arm()
    let task = Task {
        switch operation {
        case "create": _ = try await fixture.custody.createIdentity()
        case "import", "replace":
            _ = try await fixture.custody.importIdentity(
                RadrootsIdentitySecretMaterial(rawRepresentation: Data(repeating: 2, count: 32)),
                replaceExisting: operation == "replace"
            )
        case "unlock": _ = try await fixture.custody.unlockIdentity()
        case "export":
            _ = try await fixture.custody.exportPortableIdentity(
                passphrase: RadrootsIdentityPassphrase("synthetic custody test passphrase")
            )
        case "delete": _ = try await fixture.custody.deleteIdentity()
        default: Issue.record("Unknown test operation")
        }
    }
    for await _ in fixture.presence.entered { break }
    task.cancel()
    await fixture.presence.release()
    await #expect(throws: RadrootsIdentityCustodyError.cancelled) { try await task.value }
    let after = await fixture.custody.snapshot()
    #expect(after.identity == before.identity)
    #expect(after.state == before.state)
    #expect(try fixture.secure.get(fixture.activeKey) == original)
    #expect(fixture.secure.keys().allSatisfy { $0 == fixture.activeKey })
}

@Test func guardedLegacyImportKeepsExpectedIdentityAcrossFreshCustodyInstance() async throws {
    let reference = try AdmissionFixture()
    let expected = try #require(try await reference.importIdentity().identity?.publicKeyHex)
    let secure = RadrootsInMemorySecureStore()
    let metadata = RadrootsInMemoryIdentityMetadataStore()
    let configuration = try RadrootsIdentityCustodyConfiguration(namespace: UUID().uuidString.lowercased())
    let key = RadrootsSecureStoreKey(namespace: "legacy", name: "selected_secret_hex")
    try secure.put(Data(String(repeating: "01", count: 32).utf8), for: key)
    let first = RadrootsIdentityCustody(
        configuration: configuration, secureStore: secure, metadataStore: metadata,
        userPresence: CustodyPresenceGate()
    )
    let migrated = try await first.migrateLegacyIdentity(from: key, expectedPublicKeyHex: expected)
    #expect(migrated.identity?.publicKeyHex == expected)
    #expect(try secure.get(key) == nil)
    let restarted = RadrootsIdentityCustody(
        configuration: configuration, secureStore: secure, metadataStore: metadata,
        userPresence: CustodyPresenceGate()
    )
    let replayed = try await restarted.migrateLegacyIdentity(from: key, expectedPublicKeyHex: expected)
    #expect(replayed.identity == migrated.identity)
    #expect(replayed.state == .locked)
}

@Test func cancelledPortableImportDoesNotInstallOpenedIdentity() async throws {
    let source = try AdmissionFixture()
    _ = try await source.importIdentity()
    let passphrase = try RadrootsIdentityPassphrase("synthetic portable test passphrase")
    let envelope = try await source.custody.exportPortableIdentity(passphrase: passphrase)
    let destination = try AdmissionFixture()
    await destination.presence.arm()
    let task = Task {
        try await destination.custody.importPortableIdentity(envelope, passphrase: passphrase)
    }
    for await _ in destination.presence.entered { break }
    task.cancel()
    await destination.presence.release()
    await #expect(throws: RadrootsIdentityCustodyError.cancelled) { try await task.value }
    #expect(await destination.custody.snapshot().state == .absent)
    #expect(destination.secure.keys().isEmpty)
}

private struct AdmissionFixture: Sendable {
    let secure = RadrootsInMemorySecureStore()
    let presence = CustodyPresenceGate()
    let custody: RadrootsIdentityCustody
    let activeKey: RadrootsSecureStoreKey
    let legacyKey = RadrootsSecureStoreKey(namespace: "legacy", name: "selected_secret_hex")

    init() throws {
        let namespace = UUID().uuidString.lowercased()
        activeKey = RadrootsSecureStoreKey(namespace: namespace, name: "active_secret_v1")
        custody = try RadrootsIdentityCustody(
            configuration: RadrootsIdentityCustodyConfiguration(namespace: namespace),
            secureStore: secure, metadataStore: RadrootsInMemoryIdentityMetadataStore(),
            userPresence: presence
        )
    }

    func importIdentity() async throws -> RadrootsIdentitySnapshot {
        try await custody.importIdentity(
            RadrootsIdentitySecretMaterial(rawRepresentation: Data(repeating: 1, count: 32))
        )
    }
}

private actor CustodyPresenceGate: RadrootsUserPresence {
    nonisolated let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Void, Never>?
    private var blocks = false
    private(set) var requests = 0

    init() { (entered, signal) = AsyncStream.makeStream() }
    func currentStatus() async throws -> RadrootsUserPresenceStatus { .unavailable }
    func arm() { blocks = true }
    func release() {
        pending?.resume()
        pending = nil
    }

    func verify(_ request: RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult {
        requests += 1
        if blocks {
            blocks = false
            await withCheckedContinuation { continuation in
                pending = continuation
                signal.yield(())
            }
        }
        return RadrootsUserPresenceResult(policy: request.policy, verified: true)
    }
}
