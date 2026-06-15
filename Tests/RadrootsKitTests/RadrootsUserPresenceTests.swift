import Foundation
import Testing
import RadrootsKit

@Test func userPresenceRequestNormalizesReason() throws {
    let request = try RadrootsUserPresenceRequest(
        policy: .deviceOwnerAuthenticationWithBiometrics,
        reason: "  Unlock local Nostr identity  "
    )

    #expect(request.policy == .deviceOwnerAuthenticationWithBiometrics)
    #expect(request.reason == "Unlock local Nostr identity")
}

@Test func userPresenceRequestRejectsBlankReason() {
    #expect(throws: RadrootsUserPresenceError.self) {
        _ = try RadrootsUserPresenceRequest(reason: " \n ")
    }
}

@Test func userPresenceStatusCanRepresentUnavailableDevices() {
    #expect(RadrootsUserPresenceStatus.unavailable.support == .none)
    #expect(RadrootsUserPresenceStatus.unavailable.biometryKind == .none)
    #expect(!RadrootsUserPresenceStatus.unavailable.canEvaluateDeviceCredential)
    #expect(!RadrootsUserPresenceStatus.unavailable.canEvaluateBiometrics)
}

@Test func userPresenceErrorsExposeLocalizedMessages() {
    let error = RadrootsUserPresenceError.permissionDenied("presence denied")

    #expect(error.errorDescription == "presence denied")
}
