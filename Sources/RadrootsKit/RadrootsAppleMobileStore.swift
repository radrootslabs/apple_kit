import Foundation

#if canImport(UIKit)
  import UIKit
#endif

public enum RadrootsAppleProtectedDataAvailability: Sendable, Equatable {
  case available
  case unavailable

  @MainActor
  public static var current: Self {
    #if canImport(UIKit)
      UIApplication.shared.isProtectedDataAvailable ? .available : .unavailable
    #else
      .available
    #endif
  }
}

public struct RadrootsAppleMobileStoreConfiguration: Sendable, Equatable {
  public let applicationSupportDirectory: URL
  public let ownerDirectory: URL
  public let protectedDataAvailability: RadrootsAppleProtectedDataAvailability
}

public enum RadrootsAppleMobileStoreError: Error, Sendable, Equatable {
  case invalidPublicKey
  case protectedDataUnavailable
  case invalidDirectoryLayout
  case fileSystemFailure
}

public enum RadrootsAppleMobileStore {
  private static let productDirectory = "radroots"
  private static let userDirectory = "users"

  /// Prepares the Apple-owned directory consumed by the Rust mobile runtime.
  ///
  /// The returned Application Support directory is passed to Rust, which
  /// independently derives and validates the same identity-scoped suffix.
  public static func prepare(
    roots: RadrootsAppleFileRoots,
    publicKeyHex: String,
    protectedDataAvailability: RadrootsAppleProtectedDataAvailability,
    fileManager: FileManager = .default
  ) throws -> RadrootsAppleMobileStoreConfiguration {
    guard protectedDataAvailability == .available else {
      throw RadrootsAppleMobileStoreError.protectedDataUnavailable
    }
    guard isCanonicalPublicKey(publicKeyHex) else {
      throw RadrootsAppleMobileStoreError.invalidPublicKey
    }

    let applicationSupportDirectory = roots.dataRoot.standardizedFileURL
    let productRoot =
      applicationSupportDirectory
      .appendingPathComponent(productDirectory, isDirectory: true)
    let userRoot =
      productRoot
      .appendingPathComponent(userDirectory, isDirectory: true)
    let ownerRoot =
      userRoot
      .appendingPathComponent(publicKeyHex, isDirectory: true)

    do {
      // swiftlint:disable trailing_comma
      for directory in [
        applicationSupportDirectory,
        productRoot,
        userRoot,
        ownerRoot,
      ] {
        try createOrValidateDirectory(directory, fileManager: fileManager)
      }
      // swiftlint:enable trailing_comma
      try excludeFromBackup(ownerRoot)
      try applyFileProtection(ownerRoot, fileManager: fileManager)
    } catch let error as RadrootsAppleMobileStoreError {
      throw error
    } catch {
      throw RadrootsAppleMobileStoreError.fileSystemFailure
    }

    return RadrootsAppleMobileStoreConfiguration(
      applicationSupportDirectory: applicationSupportDirectory,
      ownerDirectory: ownerRoot,
      protectedDataAvailability: protectedDataAvailability
    )
  }

  private static func isCanonicalPublicKey(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private static func createOrValidateDirectory(
    _ directory: URL,
    fileManager: FileManager
  ) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
        throw RadrootsAppleMobileStoreError.invalidDirectoryLayout
      }
      return
    }
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: nil
    )
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw RadrootsAppleMobileStoreError.invalidDirectoryLayout
    }
  }

  private static func excludeFromBackup(_ directory: URL) throws {
    var directory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
  }

  private static func applyFileProtection(
    _ directory: URL,
    fileManager: FileManager
  ) throws {
    #if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directory.path
      )
    #endif
  }
}
