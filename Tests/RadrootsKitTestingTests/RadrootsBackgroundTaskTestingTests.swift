import Foundation
import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func fakeBackgroundTaskSchedulerRecordsSubmittedRequestsAndPendingTasks() async throws {
    let scheduler = RadrootsFakeBackgroundTaskScheduler(
        submittedAt: Date(timeIntervalSince1970: 20)
    )
    let request = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.refresh",
        kind: .appRefresh,
        earliestBeginDate: Date(timeIntervalSince1970: 30)
    )

    let snapshot = try await scheduler.submit(request)

    #expect(snapshot.identifier == request.identifier)
    #expect(snapshot.submittedAt == Date(timeIntervalSince1970: 20))
    #expect(await scheduler.submittedRequestCount == 1)
    #expect(await scheduler.submittedRequests == [request])
    #expect(try await scheduler.pendingTasks() == [snapshot])
}

@Test func fakeBackgroundTaskSchedulerCancelsIndividualAndAllTasks() async throws {
    let first = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.processing",
        kind: .processing
    )
    let second = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.refresh",
        kind: .appRefresh
    )
    let scheduler = RadrootsFakeBackgroundTaskScheduler()
    _ = try await scheduler.submit(first)
    _ = try await scheduler.submit(second)

    try await scheduler.cancel(first.identifier)

    #expect(await scheduler.cancelledIdentifiers == [first.identifier])
    #expect(try await scheduler.pendingTasks().map(\.identifier) == [second.identifier])

    try await scheduler.cancelAll()

    #expect(await scheduler.cancelAllCount == 1)
    #expect(try await scheduler.pendingTasks().isEmpty)
}

@Test func fakeBackgroundTaskSchedulerCanReturnSubmitFailures() async throws {
    let scheduler = RadrootsFakeBackgroundTaskScheduler(
        submitOutcome: .failure(.schedulerFailure)
    )
    let request = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.refresh",
        kind: .appRefresh
    )

    await #expect(throws: RadrootsBackgroundTaskError.schedulerFailure) {
        _ = try await scheduler.submit(request)
    }
    #expect(await scheduler.submittedRequests == [request])
    #expect(try await scheduler.pendingTasks().isEmpty)
}
