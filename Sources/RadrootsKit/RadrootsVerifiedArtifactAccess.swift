import Foundation

public enum RadrootsVerifiedArtifactAccessError: Error, Equatable, Sendable {
  case invalidDescriptor
  case protectedDataUnavailable
  case artifactUnavailable
  case artifactCorrupt
  case fileSystemFailure
}

extension RadrootsVerifiedArtifactAccessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDescriptor: "The verified-artifact descriptor is invalid."
        case .protectedDataUnavailable: "Protected data is unavailable."
        case .artifactUnavailable: "The verified artifact is unavailable."
        case .artifactCorrupt: "The verified artifact is corrupt."
        case .fileSystemFailure: "The verified artifact could not be opened."
        }
    }
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
  public let data: Data

  fileprivate init(descriptor: RadrootsVerifiedArtifactDescriptor, data: Data) {
    self.descriptor = descriptor
    self.data = data
  }

  public var debugDescription: String {
    "RadrootsVerifiedArtifactFile(artifactID: \(descriptor.artifactID), byteSize: \(descriptor.byteSize), mediaType: \(descriptor.mediaType), data: <redacted>)"
  }
}

/// Opens only Rust-approved, content-addressed inbound media artifacts.
///
/// Rust remains the verification and cache authority. This Apple adapter
/// independently rechecks the immutable file and returns only its retained,
/// verified bytes to a native renderer. It refuses access while protected data
/// is unavailable.
public struct RadrootsAppleVerifiedArtifactAccess: Sendable {
  private let ownerDirectory: URL
  private let protectedData: RadrootsProtectedDataProvider

  public init(
    mobileStore: RadrootsAppleMobileStoreConfiguration,
    protectedData: RadrootsProtectedDataProvider = .available
  ) {
    ownerDirectory = mobileStore.ownerDirectory
    self.protectedData = protectedData
  }

  public func open(_ descriptor: RadrootsVerifiedArtifactDescriptor) throws
    -> RadrootsVerifiedArtifactFile
  {
    guard protectedData.currentState() == .available else {
      throw RadrootsVerifiedArtifactAccessError.protectedDataUnavailable
    }
    do {
      let data = try RadrootsGovernedFileReader.read(
        root: ownerDirectory,
        relativePath: "inbound_media.v1/\(descriptor.filename)",
        maximumBytes: Int(descriptor.byteSize)
      )
      guard UInt64(data.count) == descriptor.byteSize else {
        throw RadrootsVerifiedArtifactAccessError.artifactCorrupt
      }
      guard RadrootsAppleFileDigest.sha256(data) == descriptor.artifactID else {
        throw RadrootsVerifiedArtifactAccessError.artifactCorrupt
      }
      return RadrootsVerifiedArtifactFile(descriptor: descriptor, data: data)
    } catch let error as RadrootsVerifiedArtifactAccessError {
      throw error
    } catch RadrootsGovernedFileReadError.unavailable {
      throw RadrootsVerifiedArtifactAccessError.artifactUnavailable
    } catch is RadrootsGovernedFileReadError {
      throw RadrootsVerifiedArtifactAccessError.artifactCorrupt
    } catch {
      throw RadrootsVerifiedArtifactAccessError.fileSystemFailure
    }
  }

  public func revalidate(_ artifact: RadrootsVerifiedArtifactFile) throws -> Bool {
    try open(artifact.descriptor) == artifact
  }
}
