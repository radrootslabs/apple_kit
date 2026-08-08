import Foundation
@testable import RadrootsKit
import Testing

#if canImport(CoreLocation)
    import CoreLocation
#endif

@Test func appleLocationServicesReportsCurrentAvailability() async {
    let service = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            locationServicesEnabled: { true },
            authorizationStatus: { .authorizedWhenInUse },
            requestWhenInUseAuthorization: { _ in .authorizedWhenInUse },
            requestCurrentLocation: { _ in
                throw RadrootsLocationServicesError.permanentFailure("not used")
            }
        )
    )

    let availability = await service.currentAvailability()

    #expect(availability.locationServicesEnabled)
    #expect(availability.authorization == .authorizedWhenInUse)
    #expect(availability.canRequestCurrentLocation)
}

@Test func appleLocationServicesShortCircuitsAuthorizationRequests() async throws {
    let authorized = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            locationServicesEnabled: { true },
            authorizationStatus: { .authorizedWhenInUse },
            requestWhenInUseAuthorization: { _ in
                throw RadrootsLocationServicesError.permanentFailure("should not request")
            },
            requestCurrentLocation: { _ in
                throw RadrootsLocationServicesError.permanentFailure("not used")
            }
        )
    )

    #expect(try await authorized.requestWhenInUseAuthorization() == .authorizedWhenInUse)

    let denied = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            locationServicesEnabled: { true },
            authorizationStatus: { .denied },
            requestWhenInUseAuthorization: { _ in
                throw RadrootsLocationServicesError.permanentFailure("should not request")
            },
            requestCurrentLocation: { _ in
                throw RadrootsLocationServicesError.permanentFailure("not used")
            }
        )
    )

    await #expect(throws: RadrootsLocationServicesError.permissionDenied("location permission is denied")) {
        _ = try await denied.requestWhenInUseAuthorization()
    }
}

@Test func appleLocationServicesRequestsAuthorizationWhenUndetermined() async throws {
    let service = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            locationServicesEnabled: { true },
            authorizationStatus: { .notDetermined },
            requestWhenInUseAuthorization: { timeoutSeconds in
                #expect(timeoutSeconds == 12)
                return .authorizedWhenInUse
            },
            requestCurrentLocation: { _ in
                throw RadrootsLocationServicesError.permanentFailure("not used")
            }
        )
    )

    #expect(try await service.requestWhenInUseAuthorization() == .authorizedWhenInUse)
}

@Test func appleLocationServicesReturnsCurrentLocationForAuthorizedState() async throws {
    let capturedAt = Date(timeIntervalSince1970: 100)
    let reading = try RadrootsLocationReading(
        coordinate: RadrootsLocationCoordinate(latitude: 49.2827, longitude: -123.1207),
        horizontalAccuracyMeters: 4,
        capturedAt: capturedAt
    )
    let service = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            now: { Date(timeIntervalSince1970: 102) },
            locationServicesEnabled: { true },
            authorizationStatus: { .authorizedWhenInUse },
            requestWhenInUseAuthorization: { _ in .authorizedWhenInUse },
            requestCurrentLocation: { request in
                #expect(request.timeoutSeconds == 3)
                return reading
            }
        )
    )

    let result = try await service.currentLocation(RadrootsCurrentLocationRequest(
        timeoutSeconds: 3,
        maximumCachedReadingAgeSeconds: 5
    ))

    #expect(result.reading == reading)
    #expect(result.authorization == .authorizedWhenInUse)
}

@Test func appleLocationServicesRejectsCurrentLocationForUnauthorizedState() async {
    let service = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            locationServicesEnabled: { true },
            authorizationStatus: { .notDetermined },
            requestWhenInUseAuthorization: { _ in .authorizedWhenInUse },
            requestCurrentLocation: { _ in
                throw RadrootsLocationServicesError.permanentFailure("should not request")
            }
        )
    )

    await #expect(throws: RadrootsLocationServicesError.permissionDenied("location permission has not been requested")) {
        _ = try await service.currentLocation(RadrootsCurrentLocationRequest(timeoutSeconds: 1))
    }
}

@Test func appleLocationServicesRejectsStaleCurrentLocationReadings() async throws {
    let reading = try RadrootsLocationReading(
        coordinate: RadrootsLocationCoordinate(latitude: 49.2827, longitude: -123.1207),
        horizontalAccuracyMeters: 4,
        capturedAt: Date(timeIntervalSince1970: 100)
    )
    let service = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            now: { Date(timeIntervalSince1970: 200) },
            locationServicesEnabled: { true },
            authorizationStatus: { .authorizedWhenInUse },
            requestWhenInUseAuthorization: { _ in .authorizedWhenInUse },
            requestCurrentLocation: { _ in reading }
        )
    )

    await #expect(throws: RadrootsLocationServicesError.transientFailure("location reading is older than the requested maximum age")) {
        _ = try await service.currentLocation(RadrootsCurrentLocationRequest(
            timeoutSeconds: 1,
            maximumCachedReadingAgeSeconds: 5
        ))
    }
}

@Test func appleLocationServicesPropagatesTypedLocationFailures() async {
    let service = RadrootsAppleLocationServices(
        adapters: RadrootsAppleLocationServicesAdapters(
            locationServicesEnabled: { true },
            authorizationStatus: { .authorizedWhenInUse },
            requestWhenInUseAuthorization: { _ in .authorizedWhenInUse },
            requestCurrentLocation: { _ in
                throw RadrootsLocationServicesError.timeout("timed out")
            }
        )
    )

    await #expect(throws: RadrootsLocationServicesError.timeout("timed out")) {
        _ = try await service.currentLocation(RadrootsCurrentLocationRequest(timeoutSeconds: 1))
    }
}

#if canImport(CoreLocation)
    @Test func appleLocationServicesMapsCoreLocationAuthorization() {
        #expect(RadrootsAppleLocationServicesAdapters.authorization(
            for: CLAuthorizationStatus.notDetermined,
            locationServicesEnabled: true
        ) == .notDetermined)
        #expect(RadrootsAppleLocationServicesAdapters.authorization(
            for: CLAuthorizationStatus.denied,
            locationServicesEnabled: true
        ) == .denied)
        #expect(RadrootsAppleLocationServicesAdapters.authorization(
            for: CLAuthorizationStatus.authorizedAlways,
            locationServicesEnabled: true
        ) == .authorizedAlways)
        #expect(RadrootsAppleLocationServicesAdapters.authorization(
            for: CLAuthorizationStatus.authorizedAlways,
            locationServicesEnabled: false
        ) == .unavailable)
        #if os(iOS)
            #expect(RadrootsAppleLocationServicesAdapters.authorization(
                for: CLAuthorizationStatus.authorizedWhenInUse,
                locationServicesEnabled: true
            ) == .authorizedWhenInUse)
        #endif
    }
#endif
