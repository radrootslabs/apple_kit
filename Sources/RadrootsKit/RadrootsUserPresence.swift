import Foundation

public enum RadrootsUserPresencePolicy: String, Sendable, Equatable, Hashable, CaseIterable {
    case deviceOwnerAuthentication
    case deviceOwnerAuthenticationWithBiometrics
}

public enum RadrootsUserPresenceSupport: String, Sendable, Equatable, Hashable {
    case none
    case deviceCredential
    case biometricsOrDeviceCredential
}

public enum RadrootsBiometryKind: String, Sendable, Equatable, Hashable {
    case none
    case touchID
    case faceID
    case opticID
    case unknown
}

public struct RadrootsUserPresenceStatus: Sendable, Equatable, Hashable {
    public let support: RadrootsUserPresenceSupport
    public let biometryKind: RadrootsBiometryKind
    public let canEvaluateDeviceCredential: Bool
    public let canEvaluateBiometrics: Bool

    public init(
        support: RadrootsUserPresenceSupport,
        biometryKind: RadrootsBiometryKind,
        canEvaluateDeviceCredential: Bool,
        canEvaluateBiometrics: Bool
    ) {
        self.support = support
        self.biometryKind = biometryKind
        self.canEvaluateDeviceCredential = canEvaluateDeviceCredential
        self.canEvaluateBiometrics = canEvaluateBiometrics
    }

    public static let unavailable = Self(
        support: .none,
        biometryKind: .none,
        canEvaluateDeviceCredential: false,
        canEvaluateBiometrics: false
    )
}

public struct RadrootsUserPresenceRequest: Sendable, Equatable, Hashable {
    public let policy: RadrootsUserPresencePolicy
    public let reason: String

    public init(
        policy: RadrootsUserPresencePolicy = .deviceOwnerAuthentication,
        reason: String
    ) throws {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else {
            throw RadrootsUserPresenceError.invalidRequest("user presence reason cannot be empty")
        }
        self.policy = policy
        self.reason = normalizedReason
    }
}

public struct RadrootsUserPresenceResult: Sendable, Equatable, Hashable {
    public let policy: RadrootsUserPresencePolicy
    public let verified: Bool

    public init(policy: RadrootsUserPresencePolicy, verified: Bool) {
        self.policy = policy
        self.verified = verified
    }
}

public enum RadrootsUserPresenceError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case userCancelled(String)
    case permissionDenied(String)
    case unavailable(String)
    case timeout(String)
    case transientFailure(String)
    case permanentFailure(String)
}

extension RadrootsUserPresenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        case let .userCancelled(message):
            message
        case let .permissionDenied(message):
            message
        case let .unavailable(message):
            message
        case let .timeout(message):
            message
        case let .transientFailure(message):
            message
        case let .permanentFailure(message):
            message
        }
    }
}

public protocol RadrootsUserPresence: Sendable {
    func currentStatus() async throws -> RadrootsUserPresenceStatus
    func verify(_ request: RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult
}
