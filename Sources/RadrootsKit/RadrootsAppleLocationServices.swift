import Foundation

#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif

public struct RadrootsAppleLocationServicesAdapters: Sendable {
    public let now: @Sendable () -> Date
    public let locationServicesEnabled: @Sendable () -> Bool
    public let authorizationStatus: @Sendable () -> RadrootsLocationAuthorization
    public let requestWhenInUseAuthorization: @Sendable (TimeInterval) async throws -> RadrootsLocationAuthorization
    public let requestCurrentLocation: @Sendable (RadrootsCurrentLocationRequest) async throws -> RadrootsLocationReading

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        locationServicesEnabled: @escaping @Sendable () -> Bool,
        authorizationStatus: @escaping @Sendable () -> RadrootsLocationAuthorization,
        requestWhenInUseAuthorization: @escaping @Sendable (TimeInterval) async throws -> RadrootsLocationAuthorization,
        requestCurrentLocation: @escaping @Sendable (RadrootsCurrentLocationRequest) async throws -> RadrootsLocationReading
    ) {
        self.now = now
        self.locationServicesEnabled = locationServicesEnabled
        self.authorizationStatus = authorizationStatus
        self.requestWhenInUseAuthorization = requestWhenInUseAuthorization
        self.requestCurrentLocation = requestCurrentLocation
    }

    public static var live: Self {
        #if canImport(CoreLocation)
        Self(
            locationServicesEnabled: {
                CLLocationManager.locationServicesEnabled()
            },
            authorizationStatus: {
                authorization(
                    for: CLLocationManager().authorizationStatus,
                    locationServicesEnabled: CLLocationManager.locationServicesEnabled()
                )
            },
            requestWhenInUseAuthorization: { timeoutSeconds in
                try await RadrootsCoreLocationAuthorizationSession().start(timeoutSeconds: timeoutSeconds)
            },
            requestCurrentLocation: { request in
                try await RadrootsCoreLocationReadingSession().start(request: request)
            }
        )
        #else
        Self(
            locationServicesEnabled: { false },
            authorizationStatus: { .unsupported },
            requestWhenInUseAuthorization: { _ in
                throw RadrootsLocationServicesError.unavailable("CoreLocation is not available")
            },
            requestCurrentLocation: { _ in
                throw RadrootsLocationServicesError.unavailable("CoreLocation is not available")
            }
        )
        #endif
    }

    #if canImport(CoreLocation)
    public static func authorization(
        for status: CLAuthorizationStatus,
        locationServicesEnabled: Bool
    ) -> RadrootsLocationAuthorization {
        guard locationServicesEnabled else {
            return .unavailable
        }
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorizedAlways:
            return .authorizedAlways
        #if os(iOS)
        case .authorizedWhenInUse:
            return .authorizedWhenInUse
        #endif
        @unknown default:
            return .unavailable
        }
    }
    #endif
}

public final class RadrootsAppleLocationServices: RadrootsLocationServices, Sendable {
    private let adapters: RadrootsAppleLocationServicesAdapters

    public init(adapters: RadrootsAppleLocationServicesAdapters = .live) {
        self.adapters = adapters
    }

    public func currentAvailability() async -> RadrootsLocationServicesAvailability {
        let enabled = adapters.locationServicesEnabled()
        return RadrootsLocationServicesAvailability(
            locationServicesEnabled: enabled,
            authorization: enabled ? adapters.authorizationStatus() : .unavailable
        )
    }

    public func requestWhenInUseAuthorization() async throws -> RadrootsLocationAuthorization {
        let availability = await currentAvailability()
        guard availability.locationServicesEnabled else {
            throw RadrootsLocationServicesError.unavailable("location services are disabled")
        }
        switch availability.authorization {
        case .notDetermined:
            return try await adapters.requestWhenInUseAuthorization(12)
        case .authorizedWhenInUse:
            return .authorizedWhenInUse
        case .authorizedAlways:
            return .authorizedAlways
        case .denied:
            throw RadrootsLocationServicesError.permissionDenied("location permission is denied")
        case .restricted:
            throw RadrootsLocationServicesError.permissionDenied("location permission is restricted")
        case .unavailable:
            throw RadrootsLocationServicesError.unavailable("location services are unavailable")
        case .unsupported:
            throw RadrootsLocationServicesError.unavailable("location services are unsupported")
        }
    }

    public func currentLocation(_ request: RadrootsCurrentLocationRequest) async throws -> RadrootsCurrentLocationResult {
        let availability = await currentAvailability()
        guard availability.locationServicesEnabled else {
            throw RadrootsLocationServicesError.unavailable("location services are disabled")
        }
        guard availability.canRequestCurrentLocation else {
            switch availability.authorization {
            case .denied:
                throw RadrootsLocationServicesError.permissionDenied("location permission is denied")
            case .restricted:
                throw RadrootsLocationServicesError.permissionDenied("location permission is restricted")
            case .notDetermined:
                throw RadrootsLocationServicesError.permissionDenied("location permission has not been requested")
            case .unavailable:
                throw RadrootsLocationServicesError.unavailable("location services are unavailable")
            case .unsupported:
                throw RadrootsLocationServicesError.unavailable("location services are unsupported")
            case .authorizedWhenInUse, .authorizedAlways:
                break
            }
            throw RadrootsLocationServicesError.unavailable("location services are unavailable")
        }
        let reading = try await adapters.requestCurrentLocation(request)
        if let maximumAgeSeconds = request.maximumCachedReadingAgeSeconds {
            guard try reading.isFresh(relativeTo: adapters.now(), maximumAgeSeconds: maximumAgeSeconds) else {
                throw RadrootsLocationServicesError.transientFailure("location reading is older than the requested maximum age")
            }
        }
        return try RadrootsCurrentLocationResult(
            reading: reading,
            authorization: availability.authorization
        )
    }
}

#if canImport(CoreLocation)
@MainActor
private final class RadrootsCoreLocationAuthorizationSession: NSObject, @preconcurrency CLLocationManagerDelegate {
    private var continuation: CheckedContinuation<RadrootsLocationAuthorization, any Error>?
    private var manager: CLLocationManager?
    private var timeoutTask: Task<Void, Never>?

    func start(timeoutSeconds: TimeInterval) async throws -> RadrootsLocationAuthorization {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let manager = CLLocationManager()
                self.manager = manager
                manager.delegate = self
                timeoutTask = Task { [weak self] in
                    let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    self?.finish(.failure(.timeout("location authorization timed out")))
                }
                manager.requestWhenInUseAuthorization()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(.cancelled("location authorization was cancelled")))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = RadrootsAppleLocationServicesAdapters.authorization(
            for: manager.authorizationStatus,
            locationServicesEnabled: CLLocationManager.locationServicesEnabled()
        )
        guard authorization != .notDetermined else {
            return
        }
        finish(.success(authorization))
    }

    private func finish(_ result: Result<RadrootsLocationAuthorization, RadrootsLocationServicesError>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.delegate = nil
        manager = nil
        switch result {
        case .success(let authorization):
            continuation.resume(returning: authorization)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
private final class RadrootsCoreLocationReadingSession: NSObject, @preconcurrency CLLocationManagerDelegate {
    private var continuation: CheckedContinuation<RadrootsLocationReading, any Error>?
    private var manager: CLLocationManager?
    private var timeoutTask: Task<Void, Never>?

    func start(request: RadrootsCurrentLocationRequest) async throws -> RadrootsLocationReading {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let manager = CLLocationManager()
                self.manager = manager
                manager.delegate = self
                if let desiredAccuracyMeters = request.desiredAccuracyMeters {
                    manager.desiredAccuracy = desiredAccuracyMeters
                }
                timeoutTask = Task { [weak self] in
                    let nanoseconds = UInt64(request.timeoutSeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    self?.finish(.failure(.timeout("current location request timed out")))
                }
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(.cancelled("current location request was cancelled")))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.sorted(by: { $0.timestamp < $1.timestamp }).last else {
            finish(.failure(.transientFailure("CoreLocation returned no locations")))
            return
        }
        do {
            finish(.success(try Self.reading(from: location)))
        } catch let error as RadrootsLocationServicesError {
            finish(.failure(error))
        } catch {
            finish(.failure(.permanentFailure(error.localizedDescription)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        if let coreLocationError = error as? CLError {
            switch coreLocationError.code {
            case .denied:
                finish(.failure(.permissionDenied("location permission is denied")))
            case .locationUnknown:
                finish(.failure(.transientFailure("current location is temporarily unknown")))
            case .network:
                finish(.failure(.transientFailure("location network lookup failed")))
            default:
                finish(.failure(.permanentFailure(coreLocationError.localizedDescription)))
            }
        } else {
            finish(.failure(.permanentFailure(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<RadrootsLocationReading, RadrootsLocationServicesError>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.delegate = nil
        manager = nil
        switch result {
        case .success(let reading):
            continuation.resume(returning: reading)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static func reading(from location: CLLocation) throws -> RadrootsLocationReading {
        try RadrootsLocationReading(
            coordinate: RadrootsLocationCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            horizontalAccuracyMeters: location.horizontalAccuracy,
            altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
            verticalAccuracyMeters: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
            courseDegrees: location.course >= 0 ? location.course : nil,
            capturedAt: location.timestamp
        )
    }
}
#endif
