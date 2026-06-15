import Foundation

#if canImport(LocalAuthentication)
@preconcurrency import LocalAuthentication
#endif

public struct RadrootsAppleUserPresenceAdapters: Sendable {
    public let currentStatus: @Sendable () async throws -> RadrootsUserPresenceStatus
    public let verify: @Sendable (RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult

    public init(
        currentStatus: @escaping @Sendable () async throws -> RadrootsUserPresenceStatus,
        verify: @escaping @Sendable (RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult
    ) {
        self.currentStatus = currentStatus
        self.verify = verify
    }

    public static func live(callbackTimeout: TimeInterval = 30) -> Self {
        #if canImport(LocalAuthentication)
        Self(
            currentStatus: {
                Self.status(for: LAContext())
            },
            verify: { request in
                let context = LAContext()
                return try await Self.verify(
                    request,
                    context: context,
                    callbackTimeout: callbackTimeout
                )
            }
        )
        #else
        Self(
            currentStatus: {
                throw RadrootsUserPresenceError.unavailable("user presence is unavailable")
            },
            verify: { _ in
                throw RadrootsUserPresenceError.unavailable("user presence is unavailable")
            }
        )
        #endif
    }
}

public final class RadrootsAppleUserPresence: RadrootsUserPresence, Sendable {
    private let adapters: RadrootsAppleUserPresenceAdapters

    public init(adapters: RadrootsAppleUserPresenceAdapters = RadrootsAppleUserPresenceAdapters.live()) {
        self.adapters = adapters
    }

    public func currentStatus() async throws -> RadrootsUserPresenceStatus {
        try await adapters.currentStatus()
    }

    public func verify(_ request: RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult {
        try await adapters.verify(request)
    }
}

#if canImport(LocalAuthentication)
extension RadrootsAppleUserPresenceAdapters {
    static func platformPolicy(_ policy: RadrootsUserPresencePolicy) -> LAPolicy {
        switch policy {
        case .deviceOwnerAuthentication:
            .deviceOwnerAuthentication
        case .deviceOwnerAuthenticationWithBiometrics:
            .deviceOwnerAuthenticationWithBiometrics
        }
    }

    static func status(for context: LAContext) -> RadrootsUserPresenceStatus {
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

        let support: RadrootsUserPresenceSupport
        if canEvaluateBiometrics {
            support = .biometricsOrDeviceCredential
        } else if canEvaluateDeviceCredential {
            support = .deviceCredential
        } else {
            support = .none
        }

        return RadrootsUserPresenceStatus(
            support: support,
            biometryKind: biometryKind(context.biometryType),
            canEvaluateDeviceCredential: canEvaluateDeviceCredential,
            canEvaluateBiometrics: canEvaluateBiometrics
        )
    }

    static func biometryKind(_ biometryType: LABiometryType) -> RadrootsBiometryKind {
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

    static func verify(
        _ request: RadrootsUserPresenceRequest,
        context: LAContext,
        callbackTimeout: TimeInterval
    ) async throws -> RadrootsUserPresenceResult {
        try await RadrootsAppleUserPresenceAsyncSupport.awaitCallback(
            timeout: callbackTimeout,
            timeoutMessage: "timed out while completing user presence verification"
        ) { completion in
            context.evaluatePolicy(
                platformPolicy(request.policy),
                localizedReason: request.reason
            ) { success, error in
                if let error {
                    completion(.failure(adapt(error: error)))
                } else {
                    completion(.success(RadrootsUserPresenceResult(policy: request.policy, verified: success)))
                }
            }
        }
    }

    static func adapt(error: Error) -> RadrootsUserPresenceError {
        if let error = error as? RadrootsUserPresenceError {
            return error
        }

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
}
#endif

enum RadrootsAppleUserPresenceAsyncSupport {
    static func awaitCallback<Value: Sendable>(
        timeout: TimeInterval,
        timeoutMessage: String,
        _ body: (@escaping @Sendable (Result<Value, RadrootsUserPresenceError>) -> Void) -> Void
    ) async throws -> Value {
        let state = RadrootsAppleUserPresenceAsyncCallbackState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                body { result in
                    state.resume(result)
                }
                Task {
                    try? await Task.sleep(nanoseconds: try Self.timeoutNanoseconds(timeout))
                    state.resume(.failure(.timeout(timeoutMessage)))
                }
            }
        } onCancel: {
            state.resume(.failure(.userCancelled("user presence verification was cancelled")))
        }
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) throws -> UInt64 {
        guard timeout.isFinite, timeout > 0 else {
            throw RadrootsUserPresenceError.invalidRequest("user presence timeout must be finite and greater than zero")
        }
        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds <= Double(UInt64.max) else {
            throw RadrootsUserPresenceError.invalidRequest("user presence timeout is too large")
        }
        return UInt64(nanoseconds)
    }
}

private final class RadrootsAppleUserPresenceAsyncCallbackState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var didResolve = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResolve else {
            continuation.resume(throwing: RadrootsUserPresenceError.transientFailure("user presence verification already resolved"))
            return
        }
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, RadrootsUserPresenceError>) {
        let pending: CheckedContinuation<Value, any Error>?
        lock.lock()
        if didResolve {
            lock.unlock()
            return
        }
        didResolve = true
        pending = continuation
        continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            pending?.resume(returning: value)
        case .failure(let error):
            pending?.resume(throwing: error)
        }
    }
}
