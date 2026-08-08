import Foundation
@testable import RadrootsKit
import Testing

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

@Test func applePermissionStatusProviderUsesAdaptersForEachPermissionKind() async throws {
    let observedAt = Date(timeIntervalSince1970: 42)
    let provider = RadrootsApplePermissionStatusProvider(
        adapters: RadrootsApplePermissionStatusAdapters(
            now: { observedAt },
            notificationStatus: { .limited },
            cameraStatus: { .authorized },
            photosStatus: { .denied },
            microphoneStatus: { .restricted },
            locationStatus: { .unavailable }
        )
    )

    let snapshots = try await provider.snapshots(for: [
        .notifications,
        .camera,
        .photos,
        .microphone,
        .location,
    ])

    #expect(snapshots.map(\.kind) == [.notifications, .camera, .photos, .microphone, .location])
    #expect(snapshots.map(\.status) == [.limited, .authorized, .denied, .restricted, .unavailable])
    #expect(snapshots.allSatisfy { $0.observedAt == observedAt })
}

@Test func applePermissionStatusProviderReturnsSingleSnapshot() async throws {
    let provider = RadrootsApplePermissionStatusProvider(
        adapters: RadrootsApplePermissionStatusAdapters(
            now: { Date(timeIntervalSince1970: 5) },
            notificationStatus: { .unsupported },
            cameraStatus: { .authorized },
            photosStatus: { .authorized },
            microphoneStatus: { .authorized },
            locationStatus: { .denied }
        )
    )

    let snapshot = try await provider.snapshot(for: .location)

    #expect(snapshot.kind == .location)
    #expect(snapshot.status == .denied)
    #expect(snapshot.observedAt == Date(timeIntervalSince1970: 5))
}

#if canImport(UserNotifications)
    @Test func applePermissionStatusMapsNotificationStatuses() {
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: UNAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: UNAuthorizationStatus.denied) == .denied)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: UNAuthorizationStatus.authorized) == .authorized)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: UNAuthorizationStatus.provisional) == .limited)
    }
#endif

#if canImport(AVFoundation)
    @Test func applePermissionStatusMapsCaptureStatuses() {
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: AVAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: AVAuthorizationStatus.restricted) == .restricted)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: AVAuthorizationStatus.denied) == .denied)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: AVAuthorizationStatus.authorized) == .authorized)
    }
#endif

#if canImport(Photos)
    @Test func applePermissionStatusMapsPhotoStatuses() {
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: PHAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: PHAuthorizationStatus.restricted) == .restricted)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: PHAuthorizationStatus.denied) == .denied)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: PHAuthorizationStatus.authorized) == .authorized)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: PHAuthorizationStatus.limited) == .limited)
    }
#endif

#if canImport(CoreLocation)
    @Test func applePermissionStatusMapsLocationStatuses() {
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: CLAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: CLAuthorizationStatus.restricted) == .restricted)
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: CLAuthorizationStatus.denied) == .denied)
        #if os(iOS)
            #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: CLAuthorizationStatus.authorizedWhenInUse) == .authorized)
        #endif
        #expect(RadrootsApplePermissionStatusAdapters.permissionStatus(for: CLAuthorizationStatus.authorizedAlways) == .authorized)
    }
#endif
