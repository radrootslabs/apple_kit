import Foundation
import Testing
@testable import RadrootsKit

@Test func backgroundTaskIdentifierNormalizesAndRejectsUnsafeValues() throws {
    let identifier = try RadrootsBackgroundTaskIdentifier(" ORG.RADROOTS.FIELD-IOS.refresh ")

    #expect(identifier.rawValue == "org.radroots.field-ios.refresh")

    #expect(throws: RadrootsBackgroundTaskError.invalidRequest("background task identifier must not be empty")) {
        _ = try RadrootsBackgroundTaskIdentifier(" ")
    }
    #expect(throws: RadrootsBackgroundTaskError.invalidRequest("background task identifier must use lowercase safe identifier characters")) {
        _ = try RadrootsBackgroundTaskIdentifier(".org.radroots")
    }
    #expect(throws: RadrootsBackgroundTaskError.invalidRequest("background task identifier cannot contain empty path components")) {
        _ = try RadrootsBackgroundTaskIdentifier("org.radroots..refresh")
    }
}

@Test func backgroundTaskRequestValidatesKindSpecificOptions() throws {
    let refresh = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.refresh",
        kind: .appRefresh,
        earliestBeginDate: Date(timeIntervalSince1970: 10)
    )

    #expect(refresh.kind == .appRefresh)
    #expect(refresh.earliestBeginDate == Date(timeIntervalSince1970: 10))
    #expect(!refresh.requiresNetworkConnectivity)

    let processing = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.processing",
        kind: .processing,
        requiresNetworkConnectivity: true,
        requiresExternalPower: true
    )

    #expect(processing.kind == .processing)
    #expect(processing.requiresNetworkConnectivity)
    #expect(processing.requiresExternalPower)

    #expect(throws: RadrootsBackgroundTaskError.invalidRequest("app refresh tasks cannot require network connectivity or external power")) {
        _ = try RadrootsBackgroundTaskRequest(
            identifier: "org.radroots.field-ios.background.refresh",
            kind: .appRefresh,
            requiresNetworkConnectivity: true
        )
    }
    #expect(throws: RadrootsBackgroundTaskError.invalidRequest("background task earliest begin date must be finite")) {
        _ = try RadrootsBackgroundTaskRequest(
            identifier: "org.radroots.field-ios.background.refresh",
            kind: .appRefresh,
            earliestBeginDate: Date(timeIntervalSinceReferenceDate: .infinity)
        )
    }
}

@Test func backgroundTaskSnapshotPreservesRequestValues() throws {
    let request = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.processing",
        kind: .processing,
        earliestBeginDate: Date(timeIntervalSince1970: 5),
        requiresNetworkConnectivity: true
    )
    let snapshot = try RadrootsBackgroundTaskSnapshot(
        request: request,
        submittedAt: Date(timeIntervalSince1970: 7)
    )

    #expect(snapshot.identifier == request.identifier)
    #expect(snapshot.kind == .processing)
    #expect(snapshot.earliestBeginDate == Date(timeIntervalSince1970: 5))
    #expect(snapshot.submittedAt == Date(timeIntervalSince1970: 7))
    #expect(snapshot.requiresNetworkConnectivity)
    #expect(!snapshot.requiresExternalPower)

    #expect(throws: RadrootsBackgroundTaskError.invalidRequest("background task submitted date must be finite")) {
        _ = try RadrootsBackgroundTaskSnapshot(
            request: request,
            submittedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
    }
}

@Test func unavailableBackgroundTaskSchedulerThrowsTypedErrors() async throws {
    let scheduler = RadrootsUnavailableBackgroundTaskScheduler(reason: "missing background support")
    let identifier = try RadrootsBackgroundTaskIdentifier("org.radroots.field-ios.background.refresh")
    let request = try RadrootsBackgroundTaskRequest(identifier: identifier, kind: .appRefresh)

    await #expect(throws: RadrootsBackgroundTaskError.unavailable("missing background support")) {
        _ = try await scheduler.submit(request)
    }
    await #expect(throws: RadrootsBackgroundTaskError.unavailable("missing background support")) {
        try await scheduler.cancel(identifier)
    }
    await #expect(throws: RadrootsBackgroundTaskError.unavailable("missing background support")) {
        try await scheduler.cancelAll()
    }
    await #expect(throws: RadrootsBackgroundTaskError.unavailable("missing background support")) {
        _ = try await scheduler.pendingTasks()
    }
}
