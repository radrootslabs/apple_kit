import Foundation

public enum RadrootsPermissionKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case notifications
    case camera
    case photos
    case microphone
    case location
}

public enum RadrootsPermissionStatus: String, Sendable, Equatable, Hashable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case limited
    case unavailable
    case unsupported
}

public struct RadrootsPermissionSnapshot: Sendable, Equatable, Hashable {
    public let kind: RadrootsPermissionKind
    public let status: RadrootsPermissionStatus
    public let observedAt: Date

    public init(kind: RadrootsPermissionKind, status: RadrootsPermissionStatus, observedAt: Date) {
        self.kind = kind
        self.status = status
        self.observedAt = observedAt
    }
}

public protocol RadrootsPermissionStatusProvider: Sendable {
    func snapshot(for kind: RadrootsPermissionKind) async throws -> RadrootsPermissionSnapshot
    func snapshots(for kinds: [RadrootsPermissionKind]) async throws -> [RadrootsPermissionSnapshot]
}

extension RadrootsPermissionStatusProvider {
    public func snapshots(for kinds: [RadrootsPermissionKind]) async throws
        -> [RadrootsPermissionSnapshot]
    {
        var snapshots: [RadrootsPermissionSnapshot] = []
        snapshots.reserveCapacity(kinds.count)
        for kind in kinds {
            try await snapshots.append(snapshot(for: kind))
        }
        return snapshots
    }
}

public enum RadrootsLocationAuthorization: String, Sendable, Equatable, Hashable {
    case notDetermined
    case authorizedWhenInUse
    case authorizedAlways
    case denied
    case restricted
    case unavailable
    case unsupported

    public var permissionStatus: RadrootsPermissionStatus {
        switch self {
        case .notDetermined:
            .notDetermined
        case .authorizedWhenInUse:
            .authorized
        case .authorizedAlways:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .unavailable:
            .unavailable
        case .unsupported:
            .unsupported
        }
    }
}

public struct RadrootsLocationServicesAvailability: Sendable, Equatable, Hashable {
    public let locationServicesEnabled: Bool
    public let authorization: RadrootsLocationAuthorization

    public init(locationServicesEnabled: Bool, authorization: RadrootsLocationAuthorization) {
        self.locationServicesEnabled = locationServicesEnabled
        self.authorization = authorization
    }

    public var canRequestWhenInUseAuthorization: Bool {
        locationServicesEnabled && authorization == .notDetermined
    }

    public var canRequestCurrentLocation: Bool {
        locationServicesEnabled
            && (authorization == .authorizedWhenInUse || authorization == .authorizedAlways)
    }
}

public struct RadrootsLocationCoordinate: Sendable, Equatable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90.0 ... 90.0).contains(latitude) else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        guard longitude.isFinite, (-180.0 ... 180.0).contains(longitude) else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct RadrootsLocationReading: Sendable, Equatable, Hashable {
    public let coordinate: RadrootsLocationCoordinate
    public let horizontalAccuracyMeters: Double
    public let altitudeMeters: Double?
    public let verticalAccuracyMeters: Double?
    public let speedMetersPerSecond: Double?
    public let courseDegrees: Double?
    public let capturedAt: Date

    public init(
        coordinate: RadrootsLocationCoordinate,
        horizontalAccuracyMeters: Double,
        altitudeMeters: Double? = nil,
        verticalAccuracyMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        capturedAt: Date
    ) throws {
        self.coordinate = coordinate
        self.horizontalAccuracyMeters = try Self.normalizedNonNegativeFinite(
            horizontalAccuracyMeters,
            field: "horizontal accuracy"
        )
        self.altitudeMeters = try Self.normalizedOptionalFinite(altitudeMeters, field: "altitude")
        self.verticalAccuracyMeters = try Self.normalizedOptionalNonNegativeFinite(
            verticalAccuracyMeters,
            field: "vertical accuracy"
        )
        self.speedMetersPerSecond = try Self.normalizedOptionalNonNegativeFinite(
            speedMetersPerSecond,
            field: "speed"
        )
        self.courseDegrees = try Self.normalizedOptionalCourse(courseDegrees)
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        self.capturedAt = capturedAt
    }

    public func age(relativeTo now: Date) throws -> TimeInterval {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        return now.timeIntervalSince(capturedAt)
    }

    public func isFresh(relativeTo now: Date, maximumAgeSeconds: TimeInterval) throws -> Bool {
        let normalizedMaximumAge = try Self.normalizedNonNegativeFinite(
            maximumAgeSeconds, field: "maximum age")
        let currentAge = try age(relativeTo: now)
        return currentAge >= 0 && currentAge <= normalizedMaximumAge
    }

    public static func normalizedNonNegativeFinite(_ value: Double, field: String) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        return value
    }

    public static func normalizedOptionalFinite(_ value: Double?, field: String) throws -> Double? {
        guard let value else {
            return nil
        }
        guard value.isFinite else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        return value
    }

    public static func normalizedOptionalNonNegativeFinite(_ value: Double?, field: String) throws
        -> Double?
    {
        guard let value else {
            return nil
        }
        return try normalizedNonNegativeFinite(value, field: field)
    }

    public static func normalizedOptionalCourse(_ value: Double?) throws -> Double? {
        guard let value else {
            return nil
        }
        guard value.isFinite, (0.0 ..< 360.0).contains(value) else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        return value
    }
}

public struct RadrootsCurrentLocationRequest: Sendable, Equatable, Hashable {
    public let timeoutSeconds: TimeInterval
    public let desiredAccuracyMeters: Double?
    public let maximumCachedReadingAgeSeconds: TimeInterval?

    public init(
        timeoutSeconds: TimeInterval = 12,
        desiredAccuracyMeters: Double? = nil,
        maximumCachedReadingAgeSeconds: TimeInterval? = nil
    ) throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        self.timeoutSeconds = timeoutSeconds
        self.desiredAccuracyMeters = try RadrootsLocationReading.normalizedOptionalNonNegativeFinite(
            desiredAccuracyMeters,
            field: "desired accuracy"
        )
        self.maximumCachedReadingAgeSeconds =
            try RadrootsLocationReading.normalizedOptionalNonNegativeFinite(
            maximumCachedReadingAgeSeconds,
            field: "maximum cached reading age"
        )
    }
}

public struct RadrootsCurrentLocationResult: Sendable, Equatable, Hashable {
    public let reading: RadrootsLocationReading
    public let authorization: RadrootsLocationAuthorization
    public let servedFromCache: Bool

    public init(
        reading: RadrootsLocationReading,
        authorization: RadrootsLocationAuthorization,
        servedFromCache: Bool = false
    ) throws {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            throw RadrootsLocationServicesError.invalidRequest
        }
        self.reading = reading
        self.authorization = authorization
        self.servedFromCache = servedFromCache
    }
}

public enum RadrootsLocationServicesError: Error, Equatable, Sendable {
    case invalidRequest
    case permissionDenied
    case unavailable
    case timeout
    case cancelled
    case transientFailure
    case permanentFailure
}

extension RadrootsLocationServicesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The location request is invalid."
        case .permissionDenied: "Location permission was denied."
        case .unavailable: "Location services are unavailable."
        case .timeout: "The location request timed out."
        case .cancelled: "The location request was cancelled."
        case .transientFailure: "Location could not be determined temporarily."
        case .permanentFailure: "Location could not be determined."
        }
    }
}

public protocol RadrootsLocationServices: Sendable {
    func currentAvailability() async -> RadrootsLocationServicesAvailability
    func requestWhenInUseAuthorization() async throws -> RadrootsLocationAuthorization
    func currentLocation(_ request: RadrootsCurrentLocationRequest) async throws
        -> RadrootsCurrentLocationResult
}
