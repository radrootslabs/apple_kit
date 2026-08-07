import Foundation
import Testing

@testable import RadrootsKit

private let publicKey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

@Test func mobileStorePreparesTheExactIdentityScopedDirectory() throws {
  let fixture = try MobileStoreFixture()
  defer { fixture.remove() }

  let configuration = try RadrootsAppleMobileStore.prepare(
    roots: fixture.roots,
    publicKeyHex: publicKey,
    protectedDataAvailability: .available
  )

  let expectedOwner = fixture.roots.dataRoot
    .appendingPathComponent("radroots", isDirectory: true)
    .appendingPathComponent("users", isDirectory: true)
    .appendingPathComponent(publicKey, isDirectory: true)
    .standardizedFileURL
  #expect(configuration.applicationSupportDirectory == fixture.roots.dataRoot)
  #expect(configuration.ownerDirectory == expectedOwner)
  #expect(configuration.protectedDataAvailability == .available)

  // swiftlint:disable trailing_comma
  let values = try expectedOwner.resourceValues(forKeys: [
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .isExcludedFromBackupKey,
  ])
  // swiftlint:enable trailing_comma
  #expect(values.isDirectory == true)
  #expect(values.isSymbolicLink != true)
  #expect(values.isExcludedFromBackup == true)
}

@Test func mobileStoreDoesNotTouchDiskWhileProtectedDataIsUnavailable() throws {
  let fixture = try MobileStoreFixture()
  defer { fixture.remove() }

  #expect(throws: RadrootsAppleMobileStoreError.protectedDataUnavailable) {
    _ = try RadrootsAppleMobileStore.prepare(
      roots: fixture.roots,
      publicKeyHex: publicKey,
      protectedDataAvailability: .unavailable
    )
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.roots.dataRoot.path))
}

@Test func mobileStoreRejectsNonCanonicalPublicKeysBeforeTouchingDisk() throws {
  let fixture = try MobileStoreFixture()
  defer { fixture.remove() }

  // swiftlint:disable trailing_comma
  for invalidKey in [
    "", "79BE" + String(publicKey.dropFirst(4)), String(repeating: "g", count: 64),
  ] {
    #expect(throws: RadrootsAppleMobileStoreError.invalidPublicKey) {
      _ = try RadrootsAppleMobileStore.prepare(
        roots: fixture.roots,
        publicKeyHex: invalidKey,
        protectedDataAvailability: .available
      )
    }
  }
  // swiftlint:enable trailing_comma
  #expect(!FileManager.default.fileExists(atPath: fixture.roots.dataRoot.path))
}

@Test func mobileStoreRejectsAFileInTheDirectoryChain() throws {
  let fixture = try MobileStoreFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(
    at: fixture.roots.dataRoot,
    withIntermediateDirectories: true
  )
  let productPath = fixture.roots.dataRoot.appendingPathComponent("radroots")
  try Data("not a directory".utf8).write(to: productPath)

  #expect(throws: RadrootsAppleMobileStoreError.invalidDirectoryLayout) {
    _ = try RadrootsAppleMobileStore.prepare(
      roots: fixture.roots,
      publicKeyHex: publicKey,
      protectedDataAvailability: .available
    )
  }
}

@Test func mobileStoreRejectsASymlinkInTheDirectoryChain() throws {
  let fixture = try MobileStoreFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(
    at: fixture.roots.dataRoot,
    withIntermediateDirectories: true
  )
  let target = fixture.root.appendingPathComponent("target", isDirectory: true)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(
    at: fixture.roots.dataRoot.appendingPathComponent("radroots"),
    withDestinationURL: target
  )

  #expect(throws: RadrootsAppleMobileStoreError.invalidDirectoryLayout) {
    _ = try RadrootsAppleMobileStore.prepare(
      roots: fixture.roots,
      publicKeyHex: publicKey,
      protectedDataAvailability: .available
    )
  }
}

private struct MobileStoreFixture {
  let root: URL
  let roots: RadrootsAppleFileRoots

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("radroots-mobile-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    roots = try RadrootsAppleFileRoots(
      appIdentifier: "org.radroots.tests",
      dataRoot: root.appendingPathComponent("data", isDirectory: true),
      cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
      temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
