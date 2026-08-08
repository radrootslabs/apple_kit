import Foundation
import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func fakeUserPresenceRecordsStatusAndVerificationRequests() async throws {
    let presence = RadrootsFakeUserPresence()
    let status = try await presence.currentStatus()
    let request = try RadrootsUserPresenceRequest(
        policy: .deviceOwnerAuthentication,
        reason: "Unlock local Nostr identity"
    )
    let result = try await presence.verify(request)

    #expect(status.support == .biometricsOrDeviceCredential)
    #expect(result.policy == .deviceOwnerAuthentication)
    #expect(result.verified)
    #expect(await presence.statusRequestCount == 1)
    #expect(await presence.verificationRequestCount == 1)
    #expect(await presence.lastVerificationRequest == request)
    #expect(await presence.verificationRequests == [request])
}

@Test func fakeUserPresenceReturnsConfiguredFailures() async throws {
    let presence = RadrootsFakeUserPresence(
        verificationOutcome: .failure(.userCancelled("verification cancelled"))
    )
    let request = try RadrootsUserPresenceRequest(reason: "Delete local Nostr identity")

    await #expect(throws: RadrootsUserPresenceError.userCancelled("verification cancelled")) {
        try await presence.verify(request)
    }

    #expect(await presence.verificationRequestCount == 1)
    #expect(await presence.lastVerificationRequest == request)
}

@Test func fakeUserPresenceCanUpdateStatusAndOutcome() async throws {
    let presence = RadrootsFakeUserPresence(status: .unavailable, verificationOutcome: .success(false))
    let initialStatus = try await presence.currentStatus()

    await presence.setStatus(
        RadrootsUserPresenceStatus(
            support: .deviceCredential,
            biometryKind: .none,
            canEvaluateDeviceCredential: true,
            canEvaluateBiometrics: false
        )
    )
    await presence.setVerificationOutcome(.success(true))

    let updatedStatus = try await presence.currentStatus()
    let result = try await presence.verify(
        RadrootsUserPresenceRequest(reason: "Import local Nostr identity")
    )

    #expect(initialStatus == .unavailable)
    #expect(updatedStatus.support == .deviceCredential)
    #expect(result.verified)
}
