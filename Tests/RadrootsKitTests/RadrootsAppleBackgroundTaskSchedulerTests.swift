import Foundation
import Testing
@testable import RadrootsKit

@Test func appleBackgroundTaskSchedulerRegistersAndSubmitsThroughAdapters() async throws {
    let probe = RadrootsAppleBackgroundTaskSchedulerProbe(now: Date(timeIntervalSince1970: 100))
    let scheduler = RadrootsAppleBackgroundTaskScheduler(adapters: probe.adapters())
    let identifier = try RadrootsBackgroundTaskIdentifier("org.radroots.field-ios.background.refresh")
    let registration = RadrootsAppleBackgroundTaskRegistration(
        identifier: identifier,
        kind: .appRefresh,
        handler: { true }
    )
    let request = try RadrootsBackgroundTaskRequest(
        identifier: identifier,
        kind: .appRefresh,
        earliestBeginDate: Date(timeIntervalSince1970: 120)
    )

    #expect(try await scheduler.register(registration))
    let snapshot = try await scheduler.submit(request)

    #expect(snapshot.identifier == identifier)
    #expect(snapshot.submittedAt == Date(timeIntervalSince1970: 100))
    #expect(await probe.registeredIdentifiers == [identifier])
    #expect(await probe.submittedRequests == [request])
}

@Test func appleBackgroundTaskSchedulerCancelsAndListsPendingTasksThroughAdapters() async throws {
    let identifier = try RadrootsBackgroundTaskIdentifier("org.radroots.field-ios.background.processing")
    let request = try RadrootsBackgroundTaskRequest(
        identifier: identifier,
        kind: .processing,
        requiresNetworkConnectivity: true
    )
    let pendingSnapshot = try RadrootsBackgroundTaskSnapshot(
        request: request,
        submittedAt: Date(timeIntervalSince1970: 5)
    )
    let probe = RadrootsAppleBackgroundTaskSchedulerProbe(pendingSnapshots: [pendingSnapshot])
    let scheduler = RadrootsAppleBackgroundTaskScheduler(adapters: probe.adapters())

    try await scheduler.cancel(identifier)
    try await scheduler.cancelAll()

    #expect(await probe.cancelledIdentifiers == [identifier])
    #expect(await probe.cancelAllCount == 1)
    #expect(try await scheduler.pendingTasks() == [pendingSnapshot])
}

@Test func appleBackgroundTaskSchedulerMapsAdapterSubmitFailures() async throws {
    let probe = RadrootsAppleBackgroundTaskSchedulerProbe(
        submitOutcome: .failure(.schedulerFailure("submit rejected"))
    )
    let scheduler = RadrootsAppleBackgroundTaskScheduler(adapters: probe.adapters())
    let request = try RadrootsBackgroundTaskRequest(
        identifier: "org.radroots.field-ios.background.refresh",
        kind: .appRefresh
    )

    await #expect(throws: RadrootsBackgroundTaskError.schedulerFailure("submit rejected")) {
        _ = try await scheduler.submit(request)
    }
}

private actor RadrootsAppleBackgroundTaskSchedulerProbe {
    private let nowValue: Date
    private let registerResult: Bool
    private let submitOutcome: Result<Void, RadrootsBackgroundTaskError>
    private var pendingSnapshotsValue: [RadrootsBackgroundTaskSnapshot]
    private var registeredIdentifiersValue: [RadrootsBackgroundTaskIdentifier]
    private var submittedRequestsValue: [RadrootsBackgroundTaskRequest]
    private var cancelledIdentifiersValue: [RadrootsBackgroundTaskIdentifier]
    private var cancelAllCountValue: Int

    init(
        now: Date = Date(timeIntervalSince1970: 0),
        registerResult: Bool = true,
        submitOutcome: Result<Void, RadrootsBackgroundTaskError> = .success(()),
        pendingSnapshots: [RadrootsBackgroundTaskSnapshot] = []
    ) {
        self.nowValue = now
        self.registerResult = registerResult
        self.submitOutcome = submitOutcome
        self.pendingSnapshotsValue = pendingSnapshots
        self.registeredIdentifiersValue = []
        self.submittedRequestsValue = []
        self.cancelledIdentifiersValue = []
        self.cancelAllCountValue = 0
    }

    nonisolated func adapters() -> RadrootsAppleBackgroundTaskSchedulerAdapters {
        RadrootsAppleBackgroundTaskSchedulerAdapters(
            now: {
                self.nowValue
            },
            register: { registration in
                await self.register(registration)
            },
            submit: { request in
                try await self.submit(request)
            },
            cancel: { identifier in
                await self.cancel(identifier)
            },
            cancelAll: {
                await self.cancelAll()
            },
            pendingTasks: {
                await self.pendingSnapshots()
            }
        )
    }

    private func register(_ registration: RadrootsAppleBackgroundTaskRegistration) -> Bool {
        registeredIdentifiersValue.append(registration.identifier)
        return registerResult
    }

    private func submit(_ request: RadrootsBackgroundTaskRequest) throws {
        submittedRequestsValue.append(request)
        switch submitOutcome {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    private func cancel(_ identifier: RadrootsBackgroundTaskIdentifier) {
        cancelledIdentifiersValue.append(identifier)
    }

    private func cancelAll() {
        cancelAllCountValue += 1
    }

    private func pendingSnapshots() -> [RadrootsBackgroundTaskSnapshot] {
        pendingSnapshotsValue
    }

    var registeredIdentifiers: [RadrootsBackgroundTaskIdentifier] {
        registeredIdentifiersValue
    }

    var submittedRequests: [RadrootsBackgroundTaskRequest] {
        submittedRequestsValue
    }

    var cancelledIdentifiers: [RadrootsBackgroundTaskIdentifier] {
        cancelledIdentifiersValue
    }

    var cancelAllCount: Int {
        cancelAllCountValue
    }
}
