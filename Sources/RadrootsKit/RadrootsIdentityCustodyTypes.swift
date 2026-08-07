import Foundation

public enum RadrootsProtectedDataState: String, Codable, Sendable {
  case available
  case locked
  case unavailable
}

public struct RadrootsProtectedDataProvider: Sendable {
  private let readState: @Sendable () -> RadrootsProtectedDataState

  public init(readState: @escaping @Sendable () -> RadrootsProtectedDataState) {
    self.readState = readState
  }

  public func currentState() -> RadrootsProtectedDataState {
    readState()
  }

  public static let available = Self { .available }
}

public enum RadrootsIdentityMetadataSlot: String, Sendable {
  case activeIdentity
  case transactionJournal
  case quarantinedMetadata
}

public protocol RadrootsIdentityMetadataStore: AnyObject, Sendable {
  func data(for slot: RadrootsIdentityMetadataSlot) throws -> Data?
  func put(_ data: Data, for slot: RadrootsIdentityMetadataSlot) throws
  func delete(_ slot: RadrootsIdentityMetadataSlot) throws
}

public struct RadrootsIdentitySecretMaterial: Sendable, CustomDebugStringConvertible {
  private let bytes: Data

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == 32 else {
      throw RadrootsIdentityCustodyError.invalidSecret
    }
    self.bytes = rawRepresentation
  }

  public init(importText: String) throws {
    let normalized = importText.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.count == 64, let decoded = Self.decodeHex(normalized) {
      try self.init(rawRepresentation: decoded)
      return
    }
    guard let decoded = Self.decodeNsec(normalized) else {
      throw RadrootsIdentityCustodyError.invalidSecret
    }
    try self.init(rawRepresentation: decoded)
  }

  public var debugDescription: String {
    "RadrootsIdentitySecretMaterial(<redacted>)"
  }

  func copyBytes() -> Data {
    bytes
  }

  private static func decodeHex(_ value: String) -> Data? {
    guard
      value.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (65...70).contains($0.value)
          || (97...102).contains($0.value)
      })
    else {
      return nil
    }
    var output = Data(capacity: 32)
    var index = value.startIndex
    for _ in 0..<32 {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else {
        return nil
      }
      output.append(byte)
      index = next
    }
    return output
  }

  private static func decodeNsec(_ value: String) -> Data? {
    guard value == value.lowercased(),
      value.count <= 90,
      let separator = value.lastIndex(of: "1"),
      value[..<separator] == "nsec"
    else {
      return nil
    }
    let payloadStart = value.index(after: separator)
    let encoded = value[payloadStart...]
    guard encoded.count >= 6 else {
      return nil
    }
    let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    let reverse = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })
    var values = [UInt8]()
    values.reserveCapacity(encoded.count)
    for character in encoded {
      guard let value = reverse[character] else {
        return nil
      }
      values.append(value)
    }
    guard bech32Polymod(hrp: "nsec", values: values) == 1 else {
      return nil
    }
    return convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false)
  }

  private static func bech32Polymod(hrp: String, values: [UInt8]) -> UInt32 {
    let generators: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
    let expanded = hrp.utf8.map { $0 >> 5 } + [0] + hrp.utf8.map { $0 & 31 } + values
    var checksum: UInt32 = 1
    for value in expanded {
      let top = checksum >> 25
      checksum = (checksum & 0x01ff_ffff) << 5 ^ UInt32(value)
      for (index, generator) in generators.enumerated() where ((top >> index) & 1) == 1 {
        checksum ^= generator
      }
    }
    return checksum
  }

  private static func convertBits(
    _ values: [UInt8],
    from sourceBits: Int,
    to targetBits: Int,
    pad: Bool
  ) -> Data? {
    var accumulator = 0
    var bitCount = 0
    let maxValue = (1 << targetBits) - 1
    var output = Data()
    for value in values {
      guard Int(value) >> sourceBits == 0 else {
        return nil
      }
      accumulator = (accumulator << sourceBits) | Int(value)
      bitCount += sourceBits
      while bitCount >= targetBits {
        bitCount -= targetBits
        output.append(UInt8((accumulator >> bitCount) & maxValue))
      }
    }
    if pad, bitCount > 0 {
      output.append(UInt8((accumulator << (targetBits - bitCount)) & maxValue))
    } else if bitCount >= sourceBits || ((accumulator << (targetBits - bitCount)) & maxValue) != 0 {
      return nil
    }
    return output.count == 32 ? output : nil
  }
}

public struct RadrootsIdentityPassphrase: Sendable, CustomDebugStringConvertible {
  private let bytes: Data

  public init(_ value: String) throws {
    let bytes = Data(value.utf8)
    guard (12...1_024).contains(bytes.count),
      !value.unicodeScalars.contains(where: { $0.value == 0 })
    else {
      throw RadrootsIdentityCustodyError.invalidPassphrase
    }
    self.bytes = bytes
  }

  public var debugDescription: String {
    "RadrootsIdentityPassphrase(<redacted>)"
  }

  func copyBytes() -> Data {
    bytes
  }
}

public struct RadrootsIdentityPublicRecord: Codable, Equatable, Hashable, Sendable {
  public let identityHandle: String
  public let publicKeyHex: String
  public let label: String?
  public let createdAtUnixMilliseconds: UInt64
  public let updatedAtUnixMilliseconds: UInt64

  public init(
    identityHandle: String,
    publicKeyHex: String,
    label: String?,
    createdAtUnixMilliseconds: UInt64,
    updatedAtUnixMilliseconds: UInt64
  ) throws {
    guard Self.validHandle(identityHandle),
      Self.validHex(publicKeyHex, byteCount: 32),
      createdAtUnixMilliseconds > 0,
      updatedAtUnixMilliseconds >= createdAtUnixMilliseconds
    else {
      throw RadrootsIdentityCustodyError.invalidMetadata
    }
    self.identityHandle = identityHandle
    self.publicKeyHex = publicKeyHex
    self.label = try Self.normalizedLabel(label)
    self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
    self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
  }

  static func normalizedLabel(_ value: String?) throws -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.utf8.count <= 128,
      !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw RadrootsIdentityCustodyError.invalidMetadata
    }
    return normalized
  }

  static func validHandle(_ value: String) -> Bool {
    value.hasPrefix("rrid1_") && value.count == 70
      && validHex(String(value.dropFirst(6)), byteCount: 32)
  }

  static func validHex(_ value: String, byteCount: Int) -> Bool {
    value.count == byteCount * 2
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }
  }
}

public enum RadrootsIdentityState: String, Codable, Sendable {
  case absent
  case locked
  case unlocked
  case protectedDataUnavailable
  case recoveryRequired
  case corrupt
}

public struct RadrootsIdentitySnapshot: Equatable, Sendable {
  public let state: RadrootsIdentityState
  public let identity: RadrootsIdentityPublicRecord?
  public let signerHandle: String?
  public let recoveryCode: String?

  public init(
    state: RadrootsIdentityState,
    identity: RadrootsIdentityPublicRecord?,
    signerHandle: String?,
    recoveryCode: String?
  ) {
    self.state = state
    self.identity = identity
    self.signerHandle = signerHandle
    self.recoveryCode = recoveryCode
  }
}

public enum RadrootsOpaqueSignPurpose: String, Codable, Sendable {
  case nostrEvent = "nostr_event"
  case blossomUpload = "blossom_upload"
}

public struct RadrootsOpaqueSignRequest: Sendable, CustomDebugStringConvertible {
  public let operationID: String
  public let signerHandle: String
  public let publicKeyHex: String
  public let digest: Data
  public let purpose: RadrootsOpaqueSignPurpose
  public let deadlineUnixMilliseconds: UInt64

  public init(
    operationID: String,
    signerHandle: String,
    publicKeyHex: String,
    digest: Data,
    purpose: RadrootsOpaqueSignPurpose,
    deadlineUnixMilliseconds: UInt64
  ) throws {
    guard Self.canonicalUUID(operationID),
      Self.canonicalUUID(signerHandle),
      RadrootsIdentityPublicRecord.validHex(publicKeyHex, byteCount: 32),
      digest.count == 32,
      deadlineUnixMilliseconds > 0
    else {
      throw RadrootsIdentityCustodyError.invalidSignRequest
    }
    self.operationID = operationID
    self.signerHandle = signerHandle
    self.publicKeyHex = publicKeyHex
    self.digest = digest
    self.purpose = purpose
    self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
  }

  public var debugDescription: String {
    "RadrootsOpaqueSignRequest(operationID: \(operationID), purpose: \(purpose.rawValue), payload: <redacted>)"
  }

  static func canonicalUUID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
  }
}

public struct RadrootsOpaqueSignature: Equatable, Sendable, CustomDebugStringConvertible {
  public let operationID: String
  public let publicKeyHex: String
  public let signature: Data
  public let purpose: RadrootsOpaqueSignPurpose

  public init(
    operationID: String,
    publicKeyHex: String,
    signature: Data,
    purpose: RadrootsOpaqueSignPurpose
  ) throws {
    guard RadrootsOpaqueSignRequest.canonicalUUID(operationID),
      RadrootsIdentityPublicRecord.validHex(publicKeyHex, byteCount: 32),
      signature.count == 64
    else {
      throw RadrootsIdentityCustodyError.invalidSignature
    }
    self.operationID = operationID
    self.publicKeyHex = publicKeyHex
    self.signature = signature
    self.purpose = purpose
  }

  public var debugDescription: String {
    "RadrootsOpaqueSignature(operationID: \(operationID), purpose: \(purpose.rawValue), signature: <redacted>)"
  }
}

public enum RadrootsIdentityCustodyError: String, Error, Sendable {
  case invalidConfiguration = "identity.invalid_configuration"
  case invalidSecret = "identity.invalid_secret"
  case invalidPassphrase = "identity.invalid_passphrase"
  case invalidMetadata = "identity.invalid_metadata"
  case corruptMetadata = "identity.corrupt_metadata"
  case inconsistentState = "identity.inconsistent_state"
  case identityAlreadyExists = "identity.already_exists"
  case identityNotFound = "identity.not_found"
  case identityLocked = "identity.locked"
  case protectedDataUnavailable = "identity.protected_data_unavailable"
  case userPresenceRequired = "identity.user_presence_required"
  case invalidSignRequest = "identity.invalid_sign_request"
  case staleSigner = "identity.stale_signer"
  case duplicateOperation = "identity.duplicate_operation"
  case signingSaturated = "identity.signing_saturated"
  case cancelled = "identity.cancelled"
  case timedOut = "identity.timed_out"
  case invalidSignature = "identity.invalid_signature"
  case recoveryRequired = "identity.recovery_required"
  case unsupportedPortabilityEnvelope = "identity.unsupported_portability_envelope"
  case portabilityAuthenticationFailed = "identity.portability_authentication_failed"
  case storageUnavailable = "identity.storage_unavailable"
  case cryptographyFailed = "identity.cryptography_failed"

  public var code: String {
    rawValue
  }
}

extension RadrootsIdentityCustodyError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "Identity storage configuration is invalid."
    case .invalidSecret: "The identity secret is invalid."
    case .invalidPassphrase: "The portability passphrase is invalid."
    case .invalidMetadata: "Identity metadata is invalid."
    case .corruptMetadata: "Identity metadata is corrupt and requires recovery."
    case .inconsistentState: "Identity storage is inconsistent and requires recovery."
    case .identityAlreadyExists: "A local identity already exists."
    case .identityNotFound: "No local identity is available."
    case .identityLocked: "The local identity is locked."
    case .protectedDataUnavailable: "Protected identity data is unavailable."
    case .userPresenceRequired: "User presence was not verified."
    case .invalidSignRequest: "The signing request is invalid."
    case .staleSigner: "The signer handle is no longer active."
    case .duplicateOperation: "The signing operation is already active."
    case .signingSaturated: "The signer is temporarily at capacity."
    case .cancelled: "The signing operation was cancelled."
    case .timedOut: "The signing operation timed out."
    case .invalidSignature: "The signing result failed verification."
    case .recoveryRequired: "Identity recovery must complete before continuing."
    case .unsupportedPortabilityEnvelope: "The encrypted identity envelope is unsupported."
    case .portabilityAuthenticationFailed:
      "The encrypted identity envelope could not be authenticated."
    case .storageUnavailable: "Identity storage is unavailable."
    case .cryptographyFailed: "The identity cryptography operation failed."
    }
  }
}
