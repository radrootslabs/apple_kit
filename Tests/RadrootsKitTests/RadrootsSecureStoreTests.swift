import Foundation
import Security
import Testing
@testable import RadrootsKit

@Test func secureStoreKeyBuildsServiceName() throws {
    let key = RadrootsSecureStoreKey(namespace: "session", name: "token")
    #expect(try key.serviceName(servicePrefix: "org.radroots.test") == "org.radroots.test.session")
}

@Test func secureStoreKeyRejectsBlankNamespace() throws {
    let key = RadrootsSecureStoreKey(namespace: " ", name: "token")
    #expect(throws: RadrootsAppleSecurityError.self) {
        _ = try key.serviceName(servicePrefix: "org.radroots.test")
    }
}

@Test func keychainStoreRoundTripsLocalSecret() throws {
    let store = RadrootsAppleKeychainSecureStore(
        servicePrefix: "org.radroots.tests.\(UUID().uuidString)"
    )
    let key = RadrootsSecureStoreKey(namespace: "roundtrip", name: "token")
    let data = Data("secret-token".utf8)

    try store.put(data, for: key)
    #expect(try store.get(key) == data)

    try store.delete(key)
    #expect(try store.get(key) == nil)
}

@Test func keychainStoreChecksPresenceWithoutReturningSecret() throws {
    let store = RadrootsAppleKeychainSecureStore(
        servicePrefix: "org.radroots.tests.\(UUID().uuidString)"
    )
    let key = RadrootsSecureStoreKey(namespace: "presence", name: "token")

    #expect(try store.contains(key) == false)

    try store.put(Data("secret-token".utf8), for: key)
    #expect(try store.contains(key) == true)

    try store.delete(key)
    #expect(try store.contains(key) == false)
}

@Test func secureLocalSecretMapsToDeviceLocalWhenUnlockedKeychainPolicy() {
    let store = RadrootsAppleKeychainSecureStore()
    let mapping = store.keychainPolicyMapping(for: .secureLocalSecret)

    #expect(String(mapping.accessibilityConstant) == String(kSecAttrAccessibleWhenUnlockedThisDeviceOnly))
    #expect(mapping.usesAccessControl == false)
    #expect(mapping.accessControlFlags.isEmpty)
}

@Test func userPresenceLocalSecretMapsToDeviceLocalWhenUnlockedAccessControl() throws {
    let store = RadrootsAppleKeychainSecureStore()
    let mapping = store.keychainPolicyMapping(for: .userPresenceLocalSecret)

    #expect(String(mapping.accessibilityConstant) == String(kSecAttrAccessibleWhenUnlockedThisDeviceOnly))
    #expect(mapping.usesAccessControl == true)
    #expect(mapping.accessControlFlags == .userPresence)
    _ = try store.accessControl(for: mapping)
}

@Test func afterFirstUnlockPolicyCanRemainDeviceLocal() {
    let store = RadrootsAppleKeychainSecureStore()
    let mapping = store.keychainPolicyMapping(
        for: RadrootsSecretAccessPolicy(
            accessibility: .afterFirstUnlock,
            deviceLocalOnly: true,
            userPresenceRequired: false
        )
    )

    #expect(String(mapping.accessibilityConstant) == String(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly))
    #expect(mapping.usesAccessControl == false)
    #expect(mapping.accessControlFlags.isEmpty)
}

@Test func resetAllowsMissingState() throws {
    let request = RadrootsAppLocalStateResetRequest(
        appIdentifier: "org.radroots.tests.\(UUID().uuidString)",
        keychainServiceNames: ["org.radroots.tests.\(UUID().uuidString)"]
    )

    try RadrootsAppLocalStateReset.reset(request)
}

@Test func resetClearsNamedKeychainService() throws {
    let servicePrefix = "org.radroots.tests.\(UUID().uuidString)"
    let store = RadrootsAppleKeychainSecureStore(servicePrefix: servicePrefix)
    let key = RadrootsSecureStoreKey(namespace: "reset", name: "secret")
    let serviceName = try key.serviceName(servicePrefix: servicePrefix)

    try store.put(Data("secret".utf8), for: key)
    #expect(try store.get(key) == Data("secret".utf8))

    try RadrootsAppLocalStateReset.reset(
        RadrootsAppLocalStateResetRequest(
            appIdentifier: "org.radroots.tests.\(UUID().uuidString)",
            keychainServiceNames: [serviceName]
        )
    )

    #expect(try store.get(key) == nil)
}

@Test func userPresenceStatusIsInspectable() async {
    let userPresence = RadrootsAppleUserPresence()
    let status = await userPresence.currentStatus()
    switch status.support {
    case .none, .deviceCredential, .biometricsOrDeviceCredential:
        break
    }
}
