import Foundation
import Testing

@testable import RadrootsKit

private let verifiedArtifactPublicKey =
  "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

@Test func verifiedArtifactAccessRechecksExactProtectedBytes() throws {
  let fixture = try VerifiedArtifactFixture()
  defer { fixture.remove() }
  let data = Data("verified inbound media".utf8)
  let digest = try fixture.install(data, mediaType: "image/png")
  let descriptor = try RadrootsVerifiedArtifactDescriptor(
    artifactID: digest,
    byteSize: UInt64(data.count),
    mediaType: "image/png",
    width: 12,
    height: 8
  )

  let artifact = try fixture.access.open(descriptor)

  #expect(try Data(contentsOf: artifact.fileURL) == data)
  #expect(try fixture.access.revalidate(artifact))
  #expect(!artifact.debugDescription.contains(artifact.fileURL.path))
}

@Test func verifiedArtifactAccessFailsClosedForLockMissingTamperAndSymlink() throws {
  let fixture = try VerifiedArtifactFixture()
  defer { fixture.remove() }
  let data = Data("immutable".utf8)
  let digest = try fixture.install(data, mediaType: "image/jpeg")
  let descriptor = try RadrootsVerifiedArtifactDescriptor(
    artifactID: digest,
    byteSize: UInt64(data.count),
    mediaType: "image/jpeg",
    width: 4,
    height: 4
  )

  fixture.protectedData.state = .locked
  #expect(throws: RadrootsVerifiedArtifactAccessError.protectedDataUnavailable) {
    _ = try fixture.access.open(descriptor)
  }
  fixture.protectedData.state = .available

  try Data("tampered".utf8).write(to: fixture.artifactURL(for: descriptor), options: .atomic)
  #expect(throws: RadrootsVerifiedArtifactAccessError.artifactCorrupt) {
    _ = try fixture.access.open(descriptor)
  }
  try FileManager.default.removeItem(at: fixture.artifactURL(for: descriptor))
  #expect(throws: RadrootsVerifiedArtifactAccessError.artifactUnavailable) {
    _ = try fixture.access.open(descriptor)
  }

  let outside = fixture.root.appendingPathComponent("outside.jpg")
  try data.write(to: outside)
  try FileManager.default.createSymbolicLink(
    at: fixture.artifactURL(for: descriptor), withDestinationURL: outside)
  #expect(throws: RadrootsVerifiedArtifactAccessError.artifactCorrupt) {
    _ = try fixture.access.open(descriptor)
  }
}

@Test func verifiedArtifactDescriptorRejectsUngovernedMetadata() throws {
  #expect(throws: RadrootsVerifiedArtifactAccessError.invalidDescriptor) {
    _ = try RadrootsVerifiedArtifactDescriptor(
      artifactID: String(repeating: "A", count: 64), byteSize: 1, mediaType: "image/png", width: 1,
      height: 1
    )
  }
  #expect(throws: RadrootsVerifiedArtifactAccessError.invalidDescriptor) {
    _ = try RadrootsVerifiedArtifactDescriptor(
      artifactID: String(repeating: "a", count: 64), byteSize: 1, mediaType: "image/svg+xml",
      width: 1, height: 1
    )
  }
  #expect(throws: RadrootsVerifiedArtifactAccessError.invalidDescriptor) {
    _ = try RadrootsVerifiedArtifactDescriptor(
      artifactID: String(repeating: "a", count: 64), byteSize: 1, mediaType: "image/png",
      width: 16_384, height: 16_384
    )
  }
}

private final class VerifiedArtifactProtectedData: @unchecked Sendable {
  private let lock = NSLock()
  private var value = RadrootsProtectedDataState.available

  var state: RadrootsProtectedDataState {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }
}

private struct VerifiedArtifactFixture {
  let root: URL
  let store: RadrootsAppleMobileStoreConfiguration
  let protectedData: VerifiedArtifactProtectedData
  let access: RadrootsAppleVerifiedArtifactAccess

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("radroots-verified-artifact-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let roots = try RadrootsAppleFileRoots(
      appIdentifier: "org.radroots.tests",
      dataRoot: root.appendingPathComponent("data", isDirectory: true),
      cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
      temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
    store = try RadrootsAppleMobileStore.prepare(
      roots: roots,
      publicKeyHex: verifiedArtifactPublicKey,
      protectedDataAvailability: .available
    )
    let protectedData = VerifiedArtifactProtectedData()
    self.protectedData = protectedData
    access = RadrootsAppleVerifiedArtifactAccess(
      mobileStore: store,
      protectedData: RadrootsProtectedDataProvider { protectedData.state }
    )
  }

  func install(_ data: Data, mediaType: String) throws -> String {
    let temporary = root.appendingPathComponent("digest-source")
    try data.write(to: temporary)
    let digest = try RadrootsAppleFileDigest.sha256(at: temporary)
    let fileExtension = mediaType == "image/jpeg" ? "jpg" : "png"
    let directory = store.ownerDirectory.appendingPathComponent(
      "inbound_media.v1", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try data.write(to: directory.appendingPathComponent("\(digest).\(fileExtension)"))
    return digest
  }

  func artifactURL(for descriptor: RadrootsVerifiedArtifactDescriptor) -> URL {
    store.ownerDirectory
      .appendingPathComponent("inbound_media.v1", isDirectory: true)
      .appendingPathComponent("\(descriptor.artifactID).\(descriptor.fileExtension)")
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
