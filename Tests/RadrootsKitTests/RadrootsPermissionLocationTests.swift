import Foundation
@testable import RadrootsKit
import Testing

@Test func permissionSnapshotsPreserveKindStatusAndObservationTime() {
    let observedAt = Date(timeIntervalSince1970: 20)
    let snapshot = RadrootsPermissionSnapshot(
        kind: .location,
        status: .authorized,
        observedAt: observedAt
    )

    #expect(snapshot.kind == .location)
    #expect(snapshot.status == .authorized)
    #expect(snapshot.observedAt == observedAt)
}

@Test func locationAvailabilityMapsUsableAuthorizationStates() {
    #expect(RadrootsLocationServicesAvailability(
        locationServicesEnabled: true,
        authorization: .notDetermined
    ).canRequestWhenInUseAuthorization)
    #expect(RadrootsLocationServicesAvailability(
        locationServicesEnabled: true,
        authorization: .authorizedWhenInUse
    ).canRequestCurrentLocation)
    #expect(RadrootsLocationServicesAvailability(
        locationServicesEnabled: true,
        authorization: .authorizedAlways
    ).canRequestCurrentLocation)
    #expect(!RadrootsLocationServicesAvailability(
        locationServicesEnabled: false,
        authorization: .authorizedWhenInUse
    ).canRequestCurrentLocation)
    #expect(RadrootsLocationAuthorization.authorizedWhenInUse.permissionStatus == .authorized)
    #expect(RadrootsLocationAuthorization.restricted.permissionStatus == .restricted)
}

@Test func locationCoordinateValidatesLatitudeAndLongitude() throws {
    let coordinate = try RadrootsLocationCoordinate(latitude: 49.2827, longitude: -123.1207)

    #expect(coordinate.latitude == 49.2827)
    #expect(coordinate.longitude == -123.1207)

    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsLocationCoordinate(latitude: 91, longitude: 0)
    }
    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsLocationCoordinate(latitude: 0, longitude: -181)
    }
    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsLocationCoordinate(latitude: .nan, longitude: 0)
    }
}

@Test func locationReadingValidatesAccuracyCourseSpeedAndFreshness() throws {
    let capturedAt = Date(timeIntervalSince1970: 100)
    let reading = try RadrootsLocationReading(
        coordinate: RadrootsLocationCoordinate(latitude: 10, longitude: 20),
        horizontalAccuracyMeters: 5,
        altitudeMeters: 120,
        verticalAccuracyMeters: 8,
        speedMetersPerSecond: 2,
        courseDegrees: 359.9,
        capturedAt: capturedAt
    )

    #expect(reading.horizontalAccuracyMeters == 5)
    #expect(try reading.age(relativeTo: Date(timeIntervalSince1970: 106)) == 6)
    #expect(try reading.isFresh(relativeTo: Date(timeIntervalSince1970: 106), maximumAgeSeconds: 10))
    #expect(try !(reading.isFresh(relativeTo: Date(timeIntervalSince1970: 120), maximumAgeSeconds: 10)))

    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsLocationReading(
            coordinate: RadrootsLocationCoordinate(latitude: 10, longitude: 20),
            horizontalAccuracyMeters: -1,
            capturedAt: capturedAt
        )
    }
    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsLocationReading(
            coordinate: RadrootsLocationCoordinate(latitude: 10, longitude: 20),
            horizontalAccuracyMeters: 1,
            speedMetersPerSecond: -1,
            capturedAt: capturedAt
        )
    }
    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsLocationReading(
            coordinate: RadrootsLocationCoordinate(latitude: 10, longitude: 20),
            horizontalAccuracyMeters: 1,
            courseDegrees: 360,
            capturedAt: capturedAt
        )
    }
}

@Test func currentLocationRequestAndResultValidateOperationalBounds() throws {
    let request = try RadrootsCurrentLocationRequest(
        timeoutSeconds: 4,
        desiredAccuracyMeters: 10,
        maximumCachedReadingAgeSeconds: 15
    )
    let reading = try RadrootsLocationReading(
        coordinate: RadrootsLocationCoordinate(latitude: 10, longitude: 20),
        horizontalAccuracyMeters: 5,
        capturedAt: Date(timeIntervalSince1970: 100)
    )
    let result = try RadrootsCurrentLocationResult(
        reading: reading,
        authorization: .authorizedWhenInUse,
        servedFromCache: true
    )

    #expect(request.timeoutSeconds == 4)
    #expect(request.desiredAccuracyMeters == 10)
    #expect(request.maximumCachedReadingAgeSeconds == 15)
    #expect(result.reading == reading)
    #expect(result.servedFromCache)

    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsCurrentLocationRequest(timeoutSeconds: 0)
    }
    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsCurrentLocationRequest(timeoutSeconds: .infinity)
    }
    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsCurrentLocationRequest(timeoutSeconds: 1, desiredAccuracyMeters: -.leastNonzeroMagnitude)
    }
    #expect(throws: RadrootsLocationServicesError.self) {
        _ = try RadrootsCurrentLocationResult(reading: reading, authorization: .denied)
    }
}
