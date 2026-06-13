import Foundation
import Testing
import RadrootsKit
import RadrootsKitTesting

@Test func deterministicLaunchConfigurationAddsStableLocaleArguments() {
    let config = RadrootsUITestLaunchConfiguration.deterministic(
        environment: ["RADROOTS_TEST": "true"],
        arguments: ["--radroots-test"]
    )

    #expect(config.environment["RADROOTS_TEST"] == "true")
    #expect(config.arguments == [
        "--radroots-test",
        "-AppleLanguages",
        "(en)",
        "-AppleLocale",
        "en_US_POSIX"
    ])
}

@Test func launchConfigurationMergesEnvironmentOverBaseValues() {
    let config = RadrootsUITestLaunchConfiguration(
        environment: ["A": "override", "B": "new"],
        arguments: []
    )

    #expect(config.mergedEnvironment(over: ["A": "old", "C": "keep"]) == [
        "A": "override",
        "B": "new",
        "C": "keep"
    ])
}

@Test func inMemorySecureStoreRoundTripsAndNormalizesKeys() throws {
    let store = RadrootsInMemorySecureStore()
    let key = RadrootsSecureStoreKey(namespace: " identity ", name: " selected ")

    try store.put(Data("secret".utf8), for: key)

    #expect(try store.contains(RadrootsSecureStoreKey(namespace: "identity", name: "selected")))
    #expect(try store.get(key) == Data("secret".utf8))
    #expect(store.keys() == [RadrootsSecureStoreKey(namespace: "identity", name: "selected")])
}

@Test func inMemorySecureStoreRecordsPolicyWithoutReturningSecret() throws {
    let store = RadrootsInMemorySecureStore()
    let key = RadrootsSecureStoreKey(namespace: "identity", name: "selected")

    try store.put(
        Data("secret".utf8),
        for: key,
        policy: .userPresenceLocalSecret
    )

    #expect(try store.policy(for: key) == .userPresenceLocalSecret)
    #expect(try store.contains(key))
}

@Test func inMemorySecureStoreDeletesNamespace() throws {
    let store = RadrootsInMemorySecureStore()
    let selected = RadrootsSecureStoreKey(namespace: " identity ", name: "selected")
    let relay = RadrootsSecureStoreKey(namespace: "relay", name: "selected")

    try store.put(Data("secret".utf8), for: selected)
    try store.put(Data("relay".utf8), for: relay)
    try store.deleteNamespace(" identity ")

    #expect(try store.get(selected) == nil)
    #expect(try store.get(relay) == Data("relay".utf8))
}
