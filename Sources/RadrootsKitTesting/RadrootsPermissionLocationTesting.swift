import Foundation
import RadrootsKit

public actor RadrootsInMemoryPermissionStatusProvider: RadrootsPermissionStatusProvider {
    private var statuses: [RadrootsPermissionKind: RadrootsPermissionStatus]
    private var observedAt: Date
    private let defaultStatus: RadrootsPermissionStatus

    public init(
        statuses: [RadrootsPermissionKind: RadrootsPermissionStatus] = [:],
        defaultStatus: RadrootsPermissionStatus = .notDetermined,
        observedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.statuses = statuses
        self.defaultStatus = defaultStatus
        self.observedAt = observedAt
    }

    public func setStatus(_ status: RadrootsPermissionStatus, for kind: RadrootsPermissionKind, observedAt: Date? = nil) {
        statuses[kind] = status
        if let observedAt {
            self.observedAt = observedAt
        }
    }

    public func snapshot(for kind: RadrootsPermissionKind) async throws -> RadrootsPermissionSnapshot {
        RadrootsPermissionSnapshot(
            kind: kind,
            status: statuses[kind] ?? defaultStatus,
            observedAt: observedAt
        )
    }
}

public actor RadrootsFakeLocationServices: RadrootsLocationServices {
    private var availability: RadrootsLocationServicesAvailability
    private var authorizationAfterRequest: RadrootsLocationAuthorization
    private var currentLocationOutcome: Result<RadrootsLocationReading, RadrootsLocationServicesError>
    private var requestAuthorizationCountValue: Int
    private var currentLocationRequestCountValue: Int

    public init(
        availability: RadrootsLocationServicesAvailability = RadrootsLocationServicesAvailability(
            locationServicesEnabled: true,
            authorization: .notDetermined
        ),
        authorizationAfterRequest: RadrootsLocationAuthorization = .authorizedWhenInUse,
        currentLocationOutcome: Result<RadrootsLocationReading, RadrootsLocationServicesError>
    ) {
        self.availability = availability
        self.authorizationAfterRequest = authorizationAfterRequest
        self.currentLocationOutcome = currentLocationOutcome
        requestAuthorizationCountValue = 0
        currentLocationRequestCountValue = 0
    }

    public func setAvailability(_ availability: RadrootsLocationServicesAvailability) {
        self.availability = availability
    }

    public func setAuthorizationAfterRequest(_ authorization: RadrootsLocationAuthorization) {
        authorizationAfterRequest = authorization
    }

    public func setCurrentLocationOutcome(_ outcome: Result<RadrootsLocationReading, RadrootsLocationServicesError>) {
        currentLocationOutcome = outcome
    }

    public func currentAvailability() async -> RadrootsLocationServicesAvailability {
        availability
    }

    public func requestWhenInUseAuthorization() async throws -> RadrootsLocationAuthorization {
        requestAuthorizationCountValue += 1
        availability = RadrootsLocationServicesAvailability(
            locationServicesEnabled: availability.locationServicesEnabled,
            authorization: authorizationAfterRequest
        )
        return authorizationAfterRequest
    }

    public func currentLocation(_: RadrootsCurrentLocationRequest) async throws -> RadrootsCurrentLocationResult {
        currentLocationRequestCountValue += 1
        switch currentLocationOutcome {
        case let .success(reading):
            return try RadrootsCurrentLocationResult(
                reading: reading,
                authorization: availability.authorization
            )
        case let .failure(error):
            throw error
        }
    }

    public var requestAuthorizationCount: Int {
        requestAuthorizationCountValue
    }

    public var currentLocationRequestCount: Int {
        currentLocationRequestCountValue
    }
}
