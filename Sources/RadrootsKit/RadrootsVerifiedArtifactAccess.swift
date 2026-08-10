import Foundation

public enum RadrootsVerifiedArtifactAccessError: Error, Equatable, Sendable {
  case invalidDescriptor
  case protectedDataUnavailable
  case artifactUnavailable
  case artifactCorrupt
  case fileSystemFailure
}

public struct RadrootsVerifiedArtifactDescriptor: Sendable, Equatable, Hashable {
  public let artifactID: String
  public let byteSize: UInt64
  public let mediaType: String
  public let fileExtension: String
  public let width: UInt32
  public let height: UInt32

  public init(
    artifactID: String,
    byteSize: UInt64,
    mediaType: String,
    width: UInt32,
    height: UInt32
  ) throws {
    let normalizedMediaType =
      mediaType
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard artifactID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      let fileExtension = Self.fileExtension(for: normalizedMediaType),
      byteSize > 0,
      byteSize <= 512 * 1024 * 1024,
      width > 0,
      height > 0,
      width <= 16_384,
      height <= 16_384,
      UInt64(width) * UInt64(height) <= 100_000_000
    else {
      throw RadrootsVerifiedArtifactAccessError.invalidDescriptor
    }
    self.artifactID = artifactID
    self.byteSize = byteSize
    self.mediaType = normalizedMediaType
    self.fileExtension = fileExtension
    self.width = width
    self.height = height
  }

  fileprivate var filename: String {
    "\(artifactID).\(fileExtension)"
  }

  private static func fileExtension(for mediaType: String) -> String? {
    switch mediaType {
    case "image/gif": "gif"
    case "image/jpeg": "jpg"
    case "image/png": "png"
    case "image/webp": "webp"
    default: nil
    }
  }
}

public struct RadrootsVerifiedArtifactFile: Sendable, Equatable, CustomDebugStringConvertible {
  public let descriptor: RadrootsVerifiedArtifactDescriptor
  public let fileURL: URL

  fileprivate init(descriptor: RadrootsVerifiedArtifactDescriptor, fileURL: URL) {
    self.descriptor = descriptor
    self.fileURL = fileURL
  }

  public var debugDescription: String {
    "RadrootsVerifiedArtifactFile(artifactID: \(descriptor.artifactID), byteSize: \(descriptor.byteSize), mediaType: \(descriptor.mediaType), fileURL: <redacted>)"
  }
}

/// Opens only Rust-approved, content-addressed inbound media artifacts.
///
/// Rust remains the verification and cache authority. This Apple adapter
/// independently rechecks the immutable file immediately before handing its
/// local URL to a native renderer and refuses access while protected data is
/// unavailable.
public struct RadrootsAppleVerifiedArtifactAccess: Sendable {
  private let ownerDirectory: URL
  private let protectedData: RadrootsProtectedDataProvider

  public init(
    mobileStore: RadrootsAppleMobileStoreConfiguration,
    protectedData: RadrootsProtectedDataProvider = .available
  ) {
    ownerDirectory = mobileStore.ownerDirectory.standardizedFileURL
    self.protectedData = protectedData
  }

  public func open(_ descriptor: RadrootsVerifiedArtifactDescriptor) throws
    -> RadrootsVerifiedArtifactFile
  {
    guard protectedData.currentState() == .available else {
      throw RadrootsVerifiedArtifactAccessError.protectedDataUnavailable
    }
    let cacheDirectory =
      ownerDirectory
      .appendingPathComponent("inbound_media.v1", isDirectory: true)
      .standardizedFileURL
    let candidate =
      cacheDirectory
      .appendingPathComponent(descriptor.filename, isDirectory: false)
      .standardizedFileURL
    guard candidate.deletingLastPathComponent() == cacheDirectory else {
      throw RadrootsVerifiedArtifactAccessError.invalidDescriptor
    }

    do {
      try Self.requireOrdinaryDirectory(ownerDirectory)
      try Self.requireOrdinaryDirectory(cacheDirectory)
      guard FileManager.default.fileExists(atPath: candidate.path) else {
        throw RadrootsVerifiedArtifactAccessError.artifactUnavailable
      }
      let values = try candidate.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
      ])
      guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        values.fileSize.flatMap(UInt64.init) == descriptor.byteSize
      else {
        throw RadrootsVerifiedArtifactAccessError.artifactCorrupt
      }
      guard try RadrootsAppleFileDigest.sha256(at: candidate) == descriptor.artifactID else {
        throw RadrootsVerifiedArtifactAccessError.artifactCorrupt
      }
      #if os(iOS)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: candidate.path
        )
      #endif
      return RadrootsVerifiedArtifactFile(descriptor: descriptor, fileURL: candidate)
    } catch let error as RadrootsVerifiedArtifactAccessError {
      throw error
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      throw RadrootsVerifiedArtifactAccessError.artifactUnavailable
    } catch {
      throw RadrootsVerifiedArtifactAccessError.fileSystemFailure
    }
  }

  public func revalidate(_ artifact: RadrootsVerifiedArtifactFile) throws -> Bool {
    try open(artifact.descriptor) == artifact
  }

  private static func requireOrdinaryDirectory(_ directory: URL) throws {
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw RadrootsVerifiedArtifactAccessError.artifactCorrupt
    }
  }
}
