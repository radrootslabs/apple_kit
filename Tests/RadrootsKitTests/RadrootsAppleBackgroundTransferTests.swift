import Foundation
import Testing
import RadrootsKitTesting
@testable import RadrootsKit

@Test func appleBackgroundTransferPersistsRunningSnapshotAfterEnqueue() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let probe = RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 100))
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    let request = try appleTransferRequest(identifier: "field.transfer.enqueue")

    let handle = try await transfer.enqueue(request)

    #expect(handle.identifier == request.identifier)
    #expect(await probe.enqueuedRequests == [request])
    let snapshot = try await transfer.snapshot(for: request.identifier)
    #expect(snapshot?.state == .running)
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 100))
}

@Test func appleBackgroundTransferRecordsFailedSnapshotWhenAdapterRejectsEnqueue() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let probe = RadrootsAppleBackgroundTransferProbe(
        now: Date(timeIntervalSince1970: 200),
        enqueueOutcome: .failure(.transferFailure("adapter rejected transfer"))
    )
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    let request = try appleTransferRequest(identifier: "field.transfer.failed")

    await #expect(throws: RadrootsBackgroundTransferError.transferFailure("adapter rejected transfer")) {
        _ = try await transfer.enqueue(request)
    }

    let snapshot = try await transfer.snapshot(for: request.identifier)
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.errorMessage == "adapter rejected transfer")
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 200))
}

@Test func appleBackgroundTransferCancelsThroughAdapterAndUpdatesStore() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let probe = RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 300))
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    let request = try appleTransferRequest(identifier: "field.transfer.cancel")

    _ = try await transfer.enqueue(request)
    try await transfer.cancel(request.identifier)

    #expect(await probe.cancelledIdentifiers == [request.identifier])
    #expect(try await transfer.snapshot(for: request.identifier)?.state == .cancelled)
    #expect(try await transfer.snapshot(for: request.identifier)?.updatedAt == Date(timeIntervalSince1970: 300))
}

@Test func appleBackgroundTransferReconcilesQueuedSnapshotsWithActiveRecoveredTasks() async throws {
    let request = try appleTransferRequest(identifier: "field.transfer.recovered")
    let queued = try RadrootsBackgroundTransferSnapshot(
        request: request,
        state: .queued,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [queued])
    let probe = RadrootsAppleBackgroundTransferProbe(
        now: Date(timeIntervalSince1970: 400),
        activeIdentifiers: [request.identifier]
    )
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

    let snapshots = try await transfer.snapshots()

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.state == .running)
    #expect(snapshots.first?.updatedAt == Date(timeIntervalSince1970: 400))
    #expect(try await store.loadSnapshots().first?.state == .running)
}

@Test func appleBackgroundTransferForwardsBackgroundCompletionHandlers() async throws {
    let probe = RadrootsAppleBackgroundTransferProbe()
    let transfer = RadrootsAppleBackgroundTransfer(
        store: RadrootsInMemoryBackgroundTransferStore(),
        adapters: probe.adapters()
    )
    let completion = RadrootsCompletionProbe()

    await transfer.handleEventsForBackgroundURLSession(identifier: "org.radroots.field-ios.background.transfer") {
        completion.markCompleted()
    }

    #expect(await probe.handledBackgroundEventIdentifiers == ["org.radroots.field-ios.background.transfer"])
    #expect(completion.completed)
}

private actor RadrootsAppleBackgroundTransferProbe {
    private let nowValue: Date
    private let enqueueOutcome: Result<Void, RadrootsBackgroundTransferError>
    private var activeIdentifiersValue: Set<RadrootsBackgroundTransferIdentifier>
    private var enqueuedRequestsValue: [RadrootsBackgroundTransferRequest]
    private var cancelledIdentifiersValue: [RadrootsBackgroundTransferIdentifier]
    private var handledBackgroundEventIdentifiersValue: [String]

    init(
        now: Date = Date(timeIntervalSince1970: 0),
        enqueueOutcome: Result<Void, RadrootsBackgroundTransferError> = .success(()),
        activeIdentifiers: Set<RadrootsBackgroundTransferIdentifier> = []
    ) {
        self.nowValue = now
        self.enqueueOutcome = enqueueOutcome
        self.activeIdentifiersValue = activeIdentifiers
        self.enqueuedRequestsValue = []
        self.cancelledIdentifiersValue = []
        self.handledBackgroundEventIdentifiersValue = []
    }

    nonisolated func adapters() -> RadrootsAppleBackgroundTransferAdapters {
        RadrootsAppleBackgroundTransferAdapters(
            now: {
                self.nowValue
            },
            enqueue: { request in
                try await self.enqueue(request)
            },
            cancel: { identifier in
                await self.cancel(identifier)
            },
            activeTransferIdentifiers: {
                await self.activeIdentifiers()
            },
            handleBackgroundEvents: { identifier, completionHandler in
                await self.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
            }
        )
    }

    private func enqueue(_ request: RadrootsBackgroundTransferRequest) throws {
        enqueuedRequestsValue.append(request)
        switch enqueueOutcome {
        case .success:
            activeIdentifiersValue.insert(request.identifier)
        case .failure(let error):
            throw error
        }
    }

    private func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) {
        cancelledIdentifiersValue.append(identifier)
        activeIdentifiersValue.remove(identifier)
    }

    private func activeIdentifiers() -> Set<RadrootsBackgroundTransferIdentifier> {
        activeIdentifiersValue
    }

    private func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        handledBackgroundEventIdentifiersValue.append(identifier)
        completionHandler()
    }

    var enqueuedRequests: [RadrootsBackgroundTransferRequest] {
        enqueuedRequestsValue
    }

    var cancelledIdentifiers: [RadrootsBackgroundTransferIdentifier] {
        cancelledIdentifiersValue
    }

    var handledBackgroundEventIdentifiers: [String] {
        handledBackgroundEventIdentifiersValue
    }
}

private final class RadrootsCompletionProbe: @unchecked Sendable {
    private var completedValue = false

    func markCompleted() {
        completedValue = true
    }

    var completed: Bool {
        completedValue
    }
}

private func appleTransferRequest(identifier: String) throws -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier),
        remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .get,
        operation: .download(
            destination: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))
        )
    )
}
