import Foundation
import Testing
@testable import RadrootsKit

@Test func appleUserPresenceReportsStatusThroughAdapter() async throws {
    let expectedStatus = RadrootsUserPresenceStatus(
        support: .deviceCredential,
        biometryKind: .none,
        canEvaluateDeviceCredential: true,
        canEvaluateBiometrics: false
    )
    let service = RadrootsAppleUserPresence(
        adapters: RadrootsAppleUserPresenceAdapters(
            currentStatus: {
                expectedStatus
            },
            verify: { request in
                RadrootsUserPresenceResult(policy: request.policy, verified: true)
            }
        )
    )

    let status = try await service.currentStatus()

    #expect(status == expectedStatus)
}

@Test func appleUserPresenceVerifiesThroughAdapter() async throws {
    let request = try RadrootsUserPresenceRequest(
        policy: .deviceOwnerAuthenticationWithBiometrics,
        reason: "Unlock local Nostr identity"
    )
    let service = RadrootsAppleUserPresence(
        adapters: RadrootsAppleUserPresenceAdapters(
            currentStatus: {
                .unavailable
            },
            verify: { request in
                RadrootsUserPresenceResult(policy: request.policy, verified: true)
            }
        )
    )

    let result = try await service.verify(request)

    #expect(result.policy == .deviceOwnerAuthenticationWithBiometrics)
    #expect(result.verified)
}

@Test func appleUserPresencePropagatesAdapterFailures() async throws {
    let service = RadrootsAppleUserPresence(
        adapters: RadrootsAppleUserPresenceAdapters(
            currentStatus: {
                .unavailable
            },
            verify: { _ in
                throw RadrootsUserPresenceError.unavailable("user presence unavailable")
            }
        )
    )

    await #expect(throws: RadrootsUserPresenceError.unavailable("user presence unavailable")) {
        try await service.verify(RadrootsUserPresenceRequest(reason: "Delete local Nostr identity"))
    }
}

@Test func appleUserPresenceAsyncSupportTimesOutUnresolvedCallbacks() async {
    await #expect(throws: RadrootsUserPresenceError.timeout("timed out")) {
        let _: Bool = try await RadrootsAppleUserPresenceAsyncSupport.awaitCallback(
            timeout: 0.001,
            timeoutMessage: "timed out"
        ) { _ in }
    }
}

#if canImport(LocalAuthentication)
import LocalAuthentication

@Test func appleUserPresenceMapsLocalAuthenticationPolicies() {
    #expect(
        RadrootsAppleUserPresenceAdapters.platformPolicy(.deviceOwnerAuthentication) ==
            LAPolicy.deviceOwnerAuthentication
    )
    #expect(
        RadrootsAppleUserPresenceAdapters.platformPolicy(.deviceOwnerAuthenticationWithBiometrics) ==
            LAPolicy.deviceOwnerAuthenticationWithBiometrics
    )
}

@Test func appleUserPresenceMapsLocalAuthenticationErrors() {
    assertUserPresenceError(
        RadrootsAppleUserPresenceAdapters.adapt(error: LAError(.userCancel)),
        matches: { if case .userCancelled = $0 { true } else { false } }
    )
    assertUserPresenceError(
        RadrootsAppleUserPresenceAdapters.adapt(error: LAError(.biometryNotAvailable)),
        matches: { if case .unavailable = $0 { true } else { false } }
    )
    assertUserPresenceError(
        RadrootsAppleUserPresenceAdapters.adapt(error: LAError(.authenticationFailed)),
        matches: { if case .permissionDenied = $0 { true } else { false } }
    )
}

private func assertUserPresenceError(
    _ error: RadrootsUserPresenceError,
    matches: (RadrootsUserPresenceError) -> Bool
) {
    #expect(matches(error))
}
#endif
