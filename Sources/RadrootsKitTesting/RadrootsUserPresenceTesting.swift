import Foundation
import RadrootsKit

public actor RadrootsFakeUserPresence: RadrootsUserPresence {
    private var statusValue: RadrootsUserPresenceStatus
    private var verificationOutcome: Result<Bool, RadrootsUserPresenceError>
    private var statusRequestCountValue: Int
    private var verificationRequestsValue: [RadrootsUserPresenceRequest]

    public init(
        status: RadrootsUserPresenceStatus = RadrootsUserPresenceStatus(
            support: .biometricsOrDeviceCredential,
            biometryKind: .faceID,
            canEvaluateDeviceCredential: true,
            canEvaluateBiometrics: true
        ),
        verificationOutcome: Result<Bool, RadrootsUserPresenceError> = .success(true)
    ) {
        statusValue = status
        self.verificationOutcome = verificationOutcome
        statusRequestCountValue = 0
        verificationRequestsValue = []
    }

    public func setStatus(_ status: RadrootsUserPresenceStatus) {
        statusValue = status
    }

    public func setVerificationOutcome(_ outcome: Result<Bool, RadrootsUserPresenceError>) {
        verificationOutcome = outcome
    }

    public func currentStatus() async throws -> RadrootsUserPresenceStatus {
        statusRequestCountValue += 1
        return statusValue
    }

    public func verify(_ request: RadrootsUserPresenceRequest) async throws -> RadrootsUserPresenceResult {
        verificationRequestsValue.append(request)
        switch verificationOutcome {
        case let .success(verified):
            return RadrootsUserPresenceResult(policy: request.policy, verified: verified)
        case let .failure(error):
            throw error
        }
    }

    public var statusRequestCount: Int {
        statusRequestCountValue
    }

    public var verificationRequestCount: Int {
        verificationRequestsValue.count
    }

    public var verificationRequests: [RadrootsUserPresenceRequest] {
        verificationRequestsValue
    }

    public var lastVerificationRequest: RadrootsUserPresenceRequest? {
        verificationRequestsValue.last
    }
}
