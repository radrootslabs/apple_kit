import Foundation
import RadrootsKitTesting
import Testing

@testable import RadrootsKit

private let identityTestNow: UInt64 = 1_800_000_000_000
private let aliceSecretHex = "10c5304d6c9ae3a1a16f7860f1cc8f5e3a76225a2663b3a989a0d775919b7df5"
private let alicePublicKeyHex = "585591529da0bab31b3b1b1f986611cf5f435dca84f978c89ee8a40cca7103df"
private let aliceNsec = "nsec1zrznqntvnt36rgt00ps0rny0tca8vgj6ye3m82vf5rthtyvm0h6syu7drz"
private let bobSecretHex = "59392e9068f66431b12f70218fb61281cb6b433d7f27c5abee1f1a3fe1a96ff8"

@Test func identitySecretMaterialParsesHexAndNsecWithoutDebugDisclosure() throws {
  let hex = try RadrootsIdentitySecretMaterial(importText: aliceSecretHex.uppercased())
  let nsec = try RadrootsIdentitySecretMaterial(importText: aliceNsec)

  #expect(hex.copyBytes() == nsec.copyBytes())
  #expect(hex.copyBytes().count == 32)
  #expect(!String(reflecting: hex).contains(aliceSecretHex))
  #expect(throws: RadrootsIdentityCustodyError.invalidSecret) {
    _ = try RadrootsIdentitySecretMaterial(importText: "nsec1invalid")
  }
}

@Test func identityLifecycleIsOneActiveOpaqueAndSignatureBound() async throws {
  let fixture = try makeIdentityFixture()
  #expect(await fixture.custody.snapshot().state == .absent)

  let imported = try await fixture.custody.importIdentity(
    RadrootsIdentitySecretMaterial(importText: aliceSecretHex),
    label: " Alice "
  )
  #expect(imported.state == .unlocked)
  #expect(imported.identity?.publicKeyHex == alicePublicKeyHex)
  #expect(imported.identity?.label == "Alice")
  let firstHandle = try #require(imported.signerHandle)

  await #expect(throws: RadrootsIdentityCustodyError.identityAlreadyExists) {
    try await fixture.custody.importIdentity(
      RadrootsIdentitySecretMaterial(importText: bobSecretHex)
    )
  }

  let digest = Data(repeating: 0x42, count: 32)
  let request = try RadrootsOpaqueSignRequest(
    operationID: UUID().uuidString.lowercased(),
    signerHandle: firstHandle,
    publicKeyHex: alicePublicKeyHex,
    digest: digest,
    purpose: .nostrEvent,
    deadlineUnixMilliseconds: identityTestNow + 1_000
  )
  let signature = try await fixture.custody.sign(request)
  #expect(signature.operationID == request.operationID)
  #expect(signature.signature.count == 64)
  #expect(
    RadrootsIdentityCryptography().verify(
      signature: signature.signature,
      digest: digest,
      publicKeyHex: alicePublicKeyHex
    )
  )
  #expect(!String(reflecting: request).contains(digest.base64EncodedString()))
  #expect(!String(reflecting: signature).contains(signature.signature.base64EncodedString()))

  await fixture.custody.lockIdentity()
  #expect(await fixture.custody.snapshot().state == .locked)
  let unlocked = try await fixture.custody.selectIdentity(
    identityHandle: try #require(imported.identity?.identityHandle)
  )
  #expect(unlocked.state == .unlocked)
  #expect(unlocked.signerHandle != firstHandle)
  await #expect(throws: RadrootsIdentityCustodyError.identityNotFound) {
    try await fixture.custody.selectIdentity(
      identityHandle: "rrid1_\(String(repeating: "0", count: 64))")
  }
  await #expect(throws: RadrootsIdentityCustodyError.staleSigner) {
    try await fixture.custody.sign(request)
  }
}

@Test func identitySigningRejectsTimeoutCancellationAndWrongBinding() async throws {
  let fixture = try makeIdentityFixture()
  let imported = try await fixture.custody.importIdentity(
    RadrootsIdentitySecretMaterial(importText: aliceSecretHex)
  )
  let handle = try #require(imported.signerHandle)
  let operationID = UUID().uuidString.lowercased()
  let expired = try RadrootsOpaqueSignRequest(
    operationID: operationID,
    signerHandle: handle,
    publicKeyHex: alicePublicKeyHex,
    digest: Data(repeating: 1, count: 32),
    purpose: .blossomUpload,
    deadlineUnixMilliseconds: identityTestNow - 1
  )
  await #expect(throws: RadrootsIdentityCustodyError.timedOut) {
    try await fixture.custody.sign(expired)
  }

  try await fixture.custody.cancelSigning(operationID: operationID)
  let cancelled = try RadrootsOpaqueSignRequest(
    operationID: operationID,
    signerHandle: handle,
    publicKeyHex: alicePublicKeyHex,
    digest: Data(repeating: 1, count: 32),
    purpose: .blossomUpload,
    deadlineUnixMilliseconds: identityTestNow + 1
  )
  await #expect(throws: RadrootsIdentityCustodyError.cancelled) {
    try await fixture.custody.sign(cancelled)
  }

  let wrongKey = String(repeating: "0", count: 64)
  let wrongBinding = try RadrootsOpaqueSignRequest(
    operationID: UUID().uuidString.lowercased(),
    signerHandle: handle,
    publicKeyHex: wrongKey,
    digest: Data(repeating: 2, count: 32),
    purpose: .nostrEvent,
    deadlineUnixMilliseconds: identityTestNow + 1
  )
  await #expect(throws: RadrootsIdentityCustodyError.staleSigner) {
    try await fixture.custody.sign(wrongBinding)
  }
}

@Test func identityReplacementAndDeleteRecoverAfterMetadataFailures() async throws {
  let fixture = try makeIdentityFixture()
  fixture.metadata.failNext(.write, slot: .activeIdentity)
  await #expect(throws: RadrootsIdentityCustodyError.recoveryRequired) {
    try await fixture.custody.importIdentity(
      RadrootsIdentitySecretMaterial(importText: aliceSecretHex)
    )
  }
  #expect(await fixture.custody.snapshot().state == .recoveryRequired)
  let recovered = try await fixture.custody.recover()
  #expect(recovered.state == .locked)
  #expect(recovered.identity?.publicKeyHex == alicePublicKeyHex)

  fixture.metadata.failNext(.delete, slot: .activeIdentity)
  await #expect(throws: RadrootsIdentityCustodyError.recoveryRequired) {
    try await fixture.custody.deleteIdentity()
  }
  #expect(await fixture.custody.snapshot().state == .recoveryRequired)
  #expect(try await fixture.custody.recover().state == .absent)
  #expect(fixture.secureStore.keys().isEmpty)
}

@Test func corruptMetadataIsDistinctFromAbsenceAndCanBeRepaired() async throws {
  let fixture = try makeIdentityFixture()
  _ = try await fixture.custody.importIdentity(
    RadrootsIdentitySecretMaterial(importText: aliceSecretHex),
    label: "Before"
  )
  await fixture.custody.lockIdentity()
  fixture.metadata.replaceRawData(Data("not-json".utf8), for: .activeIdentity)

  let corrupt = await fixture.custody.snapshot()
  #expect(corrupt.state == .corrupt)
  #expect(corrupt.recoveryCode == "identity.corrupt_metadata")
  #expect(fixture.metadata.rawData(for: .quarantinedMetadata) == Data("not-json".utf8))

  let repaired = try await fixture.custody.repairCorruptMetadata(label: "Recovered")
  #expect(repaired.state == .unlocked)
  #expect(repaired.identity?.publicKeyHex == alicePublicKeyHex)
  #expect(repaired.identity?.label == "Recovered")
  #expect(fixture.metadata.rawData(for: .quarantinedMetadata) == nil)
}

@Test func corruptTransactionJournalRequiresRecoveryWithoutClaimingAbsence() async throws {
  let fixture = try makeIdentityFixture()
  _ = try await fixture.custody.importIdentity(
    RadrootsIdentitySecretMaterial(importText: aliceSecretHex)
  )
  await fixture.custody.lockIdentity()
  fixture.metadata.replaceRawData(Data("not-a-journal".utf8), for: .transactionJournal)

  let snapshot = await fixture.custody.snapshot()
  #expect(snapshot.state == .corrupt)
  #expect(snapshot.identity == nil)
  #expect(snapshot.recoveryCode == "identity.corrupt_metadata")
  await #expect(throws: RadrootsIdentityCustodyError.corruptMetadata) {
    try await fixture.custody.recover()
  }
}

@Test func identityCustodyRoundTripsAgainstAppleStorageAdapters() async throws {
  let suffix = UUID().uuidString.lowercased()
  let namespace = "native-storage-\(suffix)"
  let servicePrefix = "org.radroots.tests.identity.\(suffix)"
  let suiteName = "org.radroots.tests.identity.metadata.\(suffix)"
  let keychain = RadrootsAppleKeychainSecureStore(servicePrefix: servicePrefix)
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer {
    try? keychain.deleteNamespace(namespace)
    defaults.removePersistentDomain(forName: suiteName)
  }
  let custody = try RadrootsIdentityCustody(
    configuration: RadrootsIdentityCustodyConfiguration(
      namespace: namespace,
      secretPolicy: .secureLocalSecret
    ),
    secureStore: keychain,
    metadataStore: RadrootsAppleIdentityMetadataStore(
      namespace: namespace,
      userDefaults: defaults
    ),
    userPresence: RadrootsFakeUserPresence(),
    now: { identityTestNow }
  )

  let imported = try await custody.importIdentity(
    RadrootsIdentitySecretMaterial(importText: aliceSecretHex),
    label: "Native"
  )
  #expect(imported.state == .unlocked)
  #expect(imported.identity?.publicKeyHex == alicePublicKeyHex)

  await custody.lockIdentity()
  #expect(await custody.snapshot().state == .locked)
  #expect(try await custody.unlockIdentity().state == .unlocked)
  #expect(try await custody.deleteIdentity().state == .absent)
  #expect(
    try keychain.contains(
      RadrootsSecureStoreKey(namespace: namespace, name: "active_secret_v1")
    ) == false)
}

@Test func protectedDataAndUserPresenceFailuresDoNotClaimIdentitySuccess() async throws {
  let secureStore = RadrootsInMemorySecureStore()
  let metadata = RadrootsInMemoryIdentityMetadataStore()
  let presence = RadrootsFakeUserPresence(verificationOutcome: .success(false))
  let custody = try RadrootsIdentityCustody(
    configuration: RadrootsIdentityCustodyConfiguration(namespace: "protected-test"),
    secureStore: secureStore,
    metadataStore: metadata,
    userPresence: presence,
    protectedData: RadrootsProtectedDataProvider { .available },
    now: { identityTestNow }
  )
  await #expect(throws: RadrootsIdentityCustodyError.userPresenceRequired) {
    try await custody.importIdentity(RadrootsIdentitySecretMaterial(importText: aliceSecretHex))
  }
  #expect(await custody.snapshot().state == .absent)

  let unavailable = try RadrootsIdentityCustody(
    configuration: RadrootsIdentityCustodyConfiguration(namespace: "locked-test"),
    secureStore: RadrootsInMemorySecureStore(),
    metadataStore: RadrootsInMemoryIdentityMetadataStore(),
    userPresence: RadrootsFakeUserPresence(),
    protectedData: RadrootsProtectedDataProvider { .locked },
    now: { identityTestNow }
  )
  await #expect(throws: RadrootsIdentityCustodyError.protectedDataUnavailable) {
    try await unavailable.createIdentity()
  }
  #expect(await unavailable.snapshot().state == .absent)
}

@Test func encryptedPortabilityRoundTripsAcrossIndependentHostsAndRejectsTampering() async throws {
  let source = try makeIdentityFixture(namespace: "portability-source")
  _ = try await source.custody.importIdentity(
    RadrootsIdentitySecretMaterial(importText: aliceNsec),
    label: "Portable"
  )
  let passphrase = try RadrootsIdentityPassphrase("correct horse battery staple")
  let envelope = try await source.custody.exportPortableIdentity(passphrase: passphrase)
  let serialized = envelope.serializedRepresentation
  let rendered = String(decoding: serialized, as: UTF8.self)
  #expect(envelope.version == 1)
  #expect(!rendered.contains(aliceSecretHex))
  #expect(!rendered.contains(aliceNsec))
  #expect(!String(reflecting: passphrase).contains("correct horse"))

  let destination = try makeIdentityFixture(namespace: "portability-destination")
  let imported = try await destination.custody.importPortableIdentity(
    envelope,
    passphrase: passphrase
  )
  #expect(imported.identity?.publicKeyHex == alicePublicKeyHex)
  #expect(imported.identity?.label == "Portable")

  let wrongDestination = try makeIdentityFixture(namespace: "portability-wrong")
  await #expect(throws: RadrootsIdentityCustodyError.portabilityAuthenticationFailed) {
    try await wrongDestination.custody.importPortableIdentity(
      envelope,
      passphrase: RadrootsIdentityPassphrase("incorrect but sufficiently long")
    )
  }

  let unsupported = serialized.replacingOccurrences(
    of: Data("\"version\":1".utf8),
    with: Data("\"version\":2".utf8)
  )
  #expect(throws: RadrootsIdentityCustodyError.unsupportedPortabilityEnvelope) {
    _ = try RadrootsIdentityPortabilityEnvelope(serializedRepresentation: unsupported)
  }
}

@Test func legacyIdentityMigrationIsIdempotentAndDeletesOnlyAfterCommit() async throws {
  let fixture = try makeIdentityFixture(namespace: "legacy-test")
  let legacyKey = RadrootsSecureStoreKey(namespace: "legacy", name: "selected_secret_hex")
  try fixture.secureStore.put(Data(aliceSecretHex.utf8), for: legacyKey)

  let migrated = try await fixture.custody.migrateLegacyIdentity(from: legacyKey, label: "Migrated")
  #expect(migrated.identity?.publicKeyHex == alicePublicKeyHex)
  #expect(try fixture.secureStore.get(legacyKey) == nil)

  try fixture.secureStore.put(Data(aliceSecretHex.utf8), for: legacyKey)
  let replayed = try await fixture.custody.migrateLegacyIdentity(from: legacyKey)
  #expect(replayed.identity?.publicKeyHex == alicePublicKeyHex)
  #expect(try fixture.secureStore.get(legacyKey) == nil)
}

@Test func opaqueSignerBridgeCancelsPendingWorkAndCompletesExactlyOnce() async throws {
  let secureStore = RadrootsInMemorySecureStore()
  let metadata = RadrootsInMemoryIdentityMetadataStore()
  let presence = ControllableIdentityPresence()
  let custody = try RadrootsIdentityCustody(
    configuration: RadrootsIdentityCustodyConfiguration(namespace: "bridge-test"),
    secureStore: secureStore,
    metadataStore: metadata,
    userPresence: presence,
    now: { identityTestNow }
  )
  let imported = try await custody.importIdentity(
    RadrootsIdentitySecretMaterial(importText: aliceSecretHex)
  )
  let signerHandle = try #require(imported.signerHandle)
  await presence.suspendNextVerification()
  let request = try RadrootsOpaqueSignRequest(
    operationID: UUID().uuidString.lowercased(),
    signerHandle: signerHandle,
    publicKeyHex: alicePublicKeyHex,
    digest: Data(repeating: 9, count: 32),
    purpose: .nostrEvent,
    deadlineUnixMilliseconds: identityTestNow + 1
  )
  let result = LockedIdentityResult()
  let cancellation = RadrootsOpaqueSignerBridge(custody: custody).submit(request) {
    result.record($0)
  }
  while await presence.pendingVerificationCount == 0 {
    await Task.yield()
  }
  cancellation.cancel()
  await presence.resumePending(verified: true)
  while result.count == 0 {
    await Task.yield()
  }
  #expect(result.count == 1)
  guard case .failure(.cancelled) = result.value else {
    Issue.record("expected one cancelled completion")
    return
  }
}

private struct IdentityFixture {
  let custody: RadrootsIdentityCustody
  let secureStore: RadrootsInMemorySecureStore
  let metadata: RadrootsInMemoryIdentityMetadataStore
}

private func makeIdentityFixture(namespace: String = UUID().uuidString.lowercased()) throws
  -> IdentityFixture
{
  let secureStore = RadrootsInMemorySecureStore()
  let metadata = RadrootsInMemoryIdentityMetadataStore()
  let custody = try RadrootsIdentityCustody(
    configuration: RadrootsIdentityCustodyConfiguration(namespace: namespace),
    secureStore: secureStore,
    metadataStore: metadata,
    userPresence: RadrootsFakeUserPresence(),
    now: { identityTestNow }
  )
  return IdentityFixture(custody: custody, secureStore: secureStore, metadata: metadata)
}

private actor ControllableIdentityPresence: RadrootsUserPresence {
  private var suspendNext = false
  private var pending: [CheckedContinuation<RadrootsUserPresenceResult, Never>] = []

  func currentStatus() async throws -> RadrootsUserPresenceStatus {
    RadrootsUserPresenceStatus(
      support: .biometricsOrDeviceCredential,
      biometryKind: .faceID,
      canEvaluateDeviceCredential: true,
      canEvaluateBiometrics: true
    )
  }

  func verify(_ request: RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult {
    guard suspendNext else {
      return RadrootsUserPresenceResult(policy: request.policy, verified: true)
    }
    suspendNext = false
    return await withCheckedContinuation { continuation in
      pending.append(continuation)
    }
  }

  func suspendNextVerification() {
    suspendNext = true
  }

  var pendingVerificationCount: Int {
    pending.count
  }

  func resumePending(verified: Bool) {
    let continuations = pending
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(
        returning: RadrootsUserPresenceResult(
          policy: .deviceOwnerAuthentication,
          verified: verified
        )
      )
    }
  }
}

private final class LockedIdentityResult: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<RadrootsOpaqueSignature, RadrootsIdentityCustodyError>] = []

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return results.count
  }

  var value: Result<RadrootsOpaqueSignature, RadrootsIdentityCustodyError>? {
    lock.lock()
    defer { lock.unlock() }
    return results.first
  }

  func record(_ value: Result<RadrootsOpaqueSignature, RadrootsIdentityCustodyError>) {
    lock.lock()
    results.append(value)
    lock.unlock()
  }
}

extension Data {
  fileprivate func replacingOccurrences(of needle: Data, with replacement: Data) -> Data {
    guard let range = range(of: needle) else {
      return self
    }
    var copy = self
    copy.replaceSubrange(range, with: replacement)
    return copy
  }
}
