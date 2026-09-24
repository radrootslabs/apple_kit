import Foundation

#if canImport(LocalAuthentication)
    @preconcurrency import LocalAuthentication
#endif

public struct RadrootsAppleUserPresenceAdapters: Sendable {
    public let currentStatus: @Sendable () async throws -> RadrootsUserPresenceStatus
    public let verify: @Sendable (RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult

    public init(
        currentStatus: @escaping @Sendable () async throws -> RadrootsUserPresenceStatus,
        verify:
            @escaping @Sendable (RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult
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
                    throw RadrootsUserPresenceError.unavailable
                },
                verify: { _ in
                    throw RadrootsUserPresenceError.unavailable
                }
            )
        #endif
    }
}

public final class RadrootsAppleUserPresence: RadrootsUserPresence, Sendable {
    private let adapters: RadrootsAppleUserPresenceAdapters

    public init(
        adapters: RadrootsAppleUserPresenceAdapters = RadrootsAppleUserPresenceAdapters.live()
    ) {
        self.adapters = adapters
    }

    public func currentStatus() async throws -> RadrootsUserPresenceStatus {
        do {
            return try await adapters.currentStatus()
        } catch {
            throw RadrootsAppleUserPresenceAdapters.adapt(error: error)
        }
    }

    public func verify(_ request: RadrootsUserPresenceRequest) async throws
        -> RadrootsUserPresenceResult
    {
        do {
            return try await adapters.verify(request)
        } catch {
            throw RadrootsAppleUserPresenceAdapters.adapt(error: error)
        }
    }
}

extension RadrootsAppleUserPresenceAdapters {
    static func adapt(error: Error) -> RadrootsUserPresenceError {
        if let error = error as? RadrootsUserPresenceError {
            return error
        }

        #if canImport(LocalAuthentication)
            if let error = error as? LAError {
                switch error.code {
                case .userCancel, .userFallback:
                    return .userCancelled
                case .appCancel, .systemCancel, .notInteractive:
                    return .transientFailure
                case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                    return .unavailable
                case .authenticationFailed:
                    return .permissionDenied
                default:
                    return .permanentFailure
                }
            }
        #endif

        return .permanentFailure
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

            let support: RadrootsUserPresenceSupport =
                if canEvaluateBiometrics {
                .biometricsOrDeviceCredential
            } else if canEvaluateDeviceCredential {
                .deviceCredential
            } else {
                .none
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
                timeoutMessage: "timed out while completing user presence verification",
                invalidate: { context.invalidate() }
            ) { completion in
                context.evaluatePolicy(
                    platformPolicy(request.policy),
                    localizedReason: request.reason
                ) { success, error in
                    if let error {
                        completion(.failure(adapt(error: error)))
                    } else {
                        completion(
                            .success(RadrootsUserPresenceResult(policy: request.policy, verified: success)))
                    }
                }
            }
        }

    }
#endif

enum RadrootsAppleUserPresenceAsyncSupport {
    static func awaitCallback<Value: Sendable>(
        timeout: TimeInterval,
        timeoutMessage: String,
        invalidate: @escaping @Sendable () -> Void = {},
        _ body: @escaping @Sendable (
            @escaping @Sendable (Result<Value, RadrootsUserPresenceError>) -> Void
        ) -> Void
    ) async throws -> Value {
        let nanoseconds = try timeoutNanoseconds(timeout)
        let state = RadrootsAppleUserPresenceAsyncCallbackState<Value>(invalidate: invalidate)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation, timeoutNanoseconds: nanoseconds, body: body)
            }
        } onCancel: {
            state.resume(.failure(.userCancelled))
        }
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) throws -> UInt64 {
        guard timeout.isFinite, timeout > 0 else {
            throw RadrootsUserPresenceError.invalidRequest
        }
        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds >= 1, nanoseconds < Double(UInt64.max) else {
            throw RadrootsUserPresenceError.invalidRequest
        }
        return UInt64(nanoseconds)
    }
}

final class RadrootsAppleUserPresenceAsyncCallbackState<Value: Sendable>:
    @unchecked Sendable
{
    // All mutable state and context start/invalidation run on this serial queue.
    // Cancellation queued before installation cannot launch evaluatePolicy;
    // cancellation after evaluation starts invalidates that same context.
    // Foreign callbacks only enqueue resolution, including synchronous callbacks.
    private let queue = DispatchQueue(label: "org.radroots.user-presence")
    private let invalidate: @Sendable () -> Void
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, RadrootsUserPresenceError>?
    private var timer: Task<Void, Never>?

    init(invalidate: @escaping @Sendable () -> Void) {
        self.invalidate = invalidate
    }

    func install(
        _ continuation: CheckedContinuation<Value, any Error>,
        timeoutNanoseconds: UInt64,
        body: @escaping @Sendable (
            @escaping @Sendable (Result<Value, RadrootsUserPresenceError>) -> Void
        ) -> Void
    ) {
        queue.async {
            if let result = self.result {
                continuation.resume(with: result.mapError { $0 as any Error })
                return
            }
            self.continuation = continuation
            self.timer = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self.resume(.failure(.timeout))
                } catch {
                    // Completed evaluations cancel their timer; no second result.
                }
            }
            body { [weak self] in self?.resume($0) }
        }
    }

    func resume(_ result: Result<Value, RadrootsUserPresenceError>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = result
            self.timer?.cancel()
            self.timer = nil
            self.invalidate()
            let pending = self.continuation
            self.continuation = nil
            pending?.resume(with: result.mapError { $0 as any Error })
        }
    }
}
