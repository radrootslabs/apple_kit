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

@Test func inMemoryPermissionStatusProviderReturnsDefaultsAndOverrides() async throws {
    let provider = RadrootsInMemoryPermissionStatusProvider(
        statuses: [.camera: .denied],
        defaultStatus: .notDetermined,
        observedAt: Date(timeIntervalSince1970: 1)
    )

    #expect(try await provider.snapshot(for: .camera).status == .denied)
    #expect(try await provider.snapshot(for: .location).status == .notDetermined)

    await provider.setStatus(.authorized, for: .location, observedAt: Date(timeIntervalSince1970: 2))

    let location = try await provider.snapshot(for: .location)
    #expect(location.status == .authorized)
    #expect(location.observedAt == Date(timeIntervalSince1970: 2))
}

@Test func fakeLocationServicesTracksRequestsAndResults() async throws {
    let reading = try RadrootsLocationReading(
        coordinate: RadrootsLocationCoordinate(latitude: 49.2827, longitude: -123.1207),
        horizontalAccuracyMeters: 6,
        capturedAt: Date(timeIntervalSince1970: 10)
    )
    let service = RadrootsFakeLocationServices(
        availability: RadrootsLocationServicesAvailability(
            locationServicesEnabled: true,
            authorization: .notDetermined
        ),
        authorizationAfterRequest: .authorizedWhenInUse,
        currentLocationOutcome: .success(reading)
    )

    #expect(await service.currentAvailability().authorization == .notDetermined)
    #expect(try await service.requestWhenInUseAuthorization() == .authorizedWhenInUse)
    #expect(await service.currentAvailability().authorization == .authorizedWhenInUse)

    let result = try await service.currentLocation(try RadrootsCurrentLocationRequest(timeoutSeconds: 2))
    #expect(result.reading == reading)
    #expect(result.authorization == .authorizedWhenInUse)
    #expect(await service.requestAuthorizationCount == 1)
    #expect(await service.currentLocationRequestCount == 1)
}

@Test func fakeLocationServicesCanReturnTypedFailures() async throws {
    let reading = try RadrootsLocationReading(
        coordinate: RadrootsLocationCoordinate(latitude: 49.2827, longitude: -123.1207),
        horizontalAccuracyMeters: 6,
        capturedAt: Date(timeIntervalSince1970: 10)
    )
    let service = RadrootsFakeLocationServices(
        availability: RadrootsLocationServicesAvailability(
            locationServicesEnabled: true,
            authorization: .authorizedWhenInUse
        ),
        currentLocationOutcome: .success(reading)
    )
    await service.setCurrentLocationOutcome(.failure(.timeout("timed out")))

    await #expect(throws: RadrootsLocationServicesError.timeout("timed out")) {
        _ = try await service.currentLocation(try RadrootsCurrentLocationRequest(timeoutSeconds: 2))
    }
}
