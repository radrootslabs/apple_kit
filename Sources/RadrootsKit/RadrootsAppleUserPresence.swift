import Foundation

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

public enum RadrootsAppleUserPresencePolicy: Sendable, Equatable {
    case deviceOwnerAuthentication
    case deviceOwnerAuthenticationWithBiometrics
}

public enum RadrootsAppleUserPresenceSupport: Sendable, Equatable {
    case none
    case deviceCredential
    case biometricsOrDeviceCredential
}

public enum RadrootsAppleBiometryKind: Sendable, Equatable {
    case none
    case touchID
    case faceID
    case opticID
    case unknown
}

public struct RadrootsAppleUserPresenceStatus: Sendable, Equatable {
    public let support: RadrootsAppleUserPresenceSupport
    public let biometryKind: RadrootsAppleBiometryKind
    public let canEvaluateDeviceCredential: Bool
    public let canEvaluateBiometrics: Bool

    public init(
        support: RadrootsAppleUserPresenceSupport,
        biometryKind: RadrootsAppleBiometryKind,
        canEvaluateDeviceCredential: Bool,
        canEvaluateBiometrics: Bool
    ) {
        self.support = support
        self.biometryKind = biometryKind
        self.canEvaluateDeviceCredential = canEvaluateDeviceCredential
        self.canEvaluateBiometrics = canEvaluateBiometrics
    }
}

public actor RadrootsAppleUserPresence {
    public init() {}

    public func currentStatus() -> RadrootsAppleUserPresenceStatus {
        #if canImport(LocalAuthentication)
        Self.status(for: LAContext())
        #else
        RadrootsAppleUserPresenceStatus(
            support: .none,
            biometryKind: .none,
            canEvaluateDeviceCredential: false,
            canEvaluateBiometrics: false
        )
        #endif
    }

    public func verify(
        reason: String,
        policy: RadrootsAppleUserPresencePolicy = .deviceOwnerAuthentication
    ) async throws -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(Self.platformPolicy(policy), localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: Self.adapt(error: error))
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
        #else
        throw RadrootsAppleSecurityError.unavailable("local authentication is unavailable")
        #endif
    }

    #if canImport(LocalAuthentication)
    static func platformPolicy(_ policy: RadrootsAppleUserPresencePolicy) -> LAPolicy {
        switch policy {
        case .deviceOwnerAuthentication:
            .deviceOwnerAuthentication
        case .deviceOwnerAuthenticationWithBiometrics:
            .deviceOwnerAuthenticationWithBiometrics
        }
    }

    static func status(for context: LAContext) -> RadrootsAppleUserPresenceStatus {
        var biometricsError: NSError?
        let canEvaluateBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &biometricsError
        )

        var deviceCredentialError: NSError?
        let canEvaluateDeviceCredential = context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &deviceCredentialError
        )

        let support: RadrootsAppleUserPresenceSupport
        if canEvaluateBiometrics {
            support = .biometricsOrDeviceCredential
        } else if canEvaluateDeviceCredential {
            support = .deviceCredential
        } else {
            support = .none
        }

        return RadrootsAppleUserPresenceStatus(
            support: support,
            biometryKind: biometryKind(context.biometryType),
            canEvaluateDeviceCredential: canEvaluateDeviceCredential,
            canEvaluateBiometrics: canEvaluateBiometrics
        )
    }

    static func biometryKind(_ biometryType: LABiometryType) -> RadrootsAppleBiometryKind {
        switch biometryType {
        case .none:
            .none
        case .touchID:
            .touchID
        case .faceID:
            .faceID
        case .opticID:
            .opticID
        @unknown default:
            .unknown
        }
    }

    static func adapt(error: Error) -> RadrootsAppleSecurityError {
        if let error = error as? LAError {
            switch error.code {
            case .userCancel, .userFallback:
                return .userCancelled(error.localizedDescription)
            case .appCancel, .systemCancel, .notInteractive:
                return .transientFailure(error.localizedDescription)
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return .unavailable(error.localizedDescription)
            case .authenticationFailed:
                return .permissionDenied(error.localizedDescription)
            default:
                return .permanentFailure(error.localizedDescription)
            }
        }
        return .permanentFailure(error.localizedDescription)
    }
    #endif
}
