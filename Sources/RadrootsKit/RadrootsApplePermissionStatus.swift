import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

#if canImport(CoreLocation)
    import CoreLocation
#endif

#if canImport(Photos)
    import Photos
#endif

#if canImport(UserNotifications)
    import UserNotifications
#endif

public struct RadrootsApplePermissionStatusAdapters: Sendable {
    public let now: @Sendable () -> Date
    public let notificationStatus: @Sendable () async -> RadrootsPermissionStatus
    public let cameraStatus: @Sendable () -> RadrootsPermissionStatus
    public let photosStatus: @Sendable () -> RadrootsPermissionStatus
    public let microphoneStatus: @Sendable () -> RadrootsPermissionStatus
    public let locationStatus: @Sendable () -> RadrootsPermissionStatus

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        notificationStatus: @escaping @Sendable () async -> RadrootsPermissionStatus,
        cameraStatus: @escaping @Sendable () -> RadrootsPermissionStatus,
        photosStatus: @escaping @Sendable () -> RadrootsPermissionStatus,
        microphoneStatus: @escaping @Sendable () -> RadrootsPermissionStatus,
        locationStatus: @escaping @Sendable () -> RadrootsPermissionStatus
    ) {
        self.now = now
        self.notificationStatus = notificationStatus
        self.cameraStatus = cameraStatus
        self.photosStatus = photosStatus
        self.microphoneStatus = microphoneStatus
        self.locationStatus = locationStatus
    }

    public static var live: Self {
        Self(
            notificationStatus: {
                await Self.currentNotificationStatus()
            },
            cameraStatus: {
                Self.currentCameraStatus()
            },
            photosStatus: {
                Self.currentPhotosStatus()
            },
            microphoneStatus: {
                Self.currentMicrophoneStatus()
            },
            locationStatus: {
                Self.currentLocationStatus()
            }
        )
    }

    public static func currentNotificationStatus() async -> RadrootsPermissionStatus {
        #if canImport(UserNotifications)
            return await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    continuation.resume(returning: Self.permissionStatus(for: settings.authorizationStatus))
                }
            }
        #else
            return .unsupported
        #endif
    }

    public static func currentCameraStatus() -> RadrootsPermissionStatus {
        #if canImport(AVFoundation)
            return permissionStatus(for: AVCaptureDevice.authorizationStatus(for: .video))
        #else
            return .unsupported
        #endif
    }

    public static func currentPhotosStatus() -> RadrootsPermissionStatus {
        #if canImport(Photos)
            return permissionStatus(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
        #else
            return .unsupported
        #endif
    }

    public static func currentMicrophoneStatus() -> RadrootsPermissionStatus {
        #if canImport(AVFoundation)
            return permissionStatus(for: AVCaptureDevice.authorizationStatus(for: .audio))
        #else
            return .unsupported
        #endif
    }

    public static func currentLocationStatus() -> RadrootsPermissionStatus {
        #if canImport(CoreLocation)
            guard CLLocationManager.locationServicesEnabled() else {
                return .unavailable
            }
            return permissionStatus(for: CLLocationManager().authorizationStatus)
        #else
            return .unsupported
        #endif
    }

    #if canImport(UserNotifications)
        public static func permissionStatus(for authorizationStatus: UNAuthorizationStatus) -> RadrootsPermissionStatus {
            switch authorizationStatus {
            case .notDetermined:
                .notDetermined
            case .denied:
                .denied
            case .authorized:
                .authorized
            case .provisional:
                .limited
            case .ephemeral:
                .limited
            @unknown default:
                .unavailable
            }
        }
    #endif

    #if canImport(AVFoundation)
        public static func permissionStatus(for authorizationStatus: AVAuthorizationStatus) -> RadrootsPermissionStatus {
            switch authorizationStatus {
            case .notDetermined:
                .notDetermined
            case .restricted:
                .restricted
            case .denied:
                .denied
            case .authorized:
                .authorized
            @unknown default:
                .unavailable
            }
        }
    #endif

    #if canImport(Photos)
        public static func permissionStatus(for authorizationStatus: PHAuthorizationStatus) -> RadrootsPermissionStatus {
            switch authorizationStatus {
            case .notDetermined:
                .notDetermined
            case .restricted:
                .restricted
            case .denied:
                .denied
            case .authorized:
                .authorized
            case .limited:
                .limited
            @unknown default:
                .unavailable
            }
        }
    #endif

    #if canImport(CoreLocation)
        public static func permissionStatus(for authorizationStatus: CLAuthorizationStatus) -> RadrootsPermissionStatus {
            switch authorizationStatus {
            case .notDetermined:
                .notDetermined
            case .restricted:
                .restricted
            case .denied:
                .denied
            case .authorizedAlways:
                .authorized
            #if os(iOS)
                case .authorizedWhenInUse:
                    .authorized
            #endif
            @unknown default:
                .unavailable
            }
        }
    #endif
}

public final class RadrootsApplePermissionStatusProvider: RadrootsPermissionStatusProvider, Sendable {
    private let adapters: RadrootsApplePermissionStatusAdapters

    public init(adapters: RadrootsApplePermissionStatusAdapters = .live) {
        self.adapters = adapters
    }

    public func snapshot(for kind: RadrootsPermissionKind) async throws -> RadrootsPermissionSnapshot {
        let status = switch kind {
        case .notifications:
            await adapters.notificationStatus()
        case .camera:
            adapters.cameraStatus()
        case .photos:
            adapters.photosStatus()
        case .microphone:
            adapters.microphoneStatus()
        case .location:
            adapters.locationStatus()
        }
        return RadrootsPermissionSnapshot(kind: kind, status: status, observedAt: adapters.now())
    }
}
