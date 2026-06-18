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

@Test func appleBackgroundTransferCoordinatorMovesCompletedDownloadToDestination() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer",
        store: store,
        fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 500) }
    )
    let request = try appleTransferRequest(identifier: "field.transfer.completed")
    let running = try RadrootsBackgroundTransferSnapshot(
        request: request,
        state: .running,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    try await store.saveSnapshot(running)
    let stagingRoot = roots.temporaryRoot.appendingPathComponent("background-transfer-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let stagedFile = stagingRoot.appendingPathComponent("download.bin")
    let payload = Data("downloaded".utf8)
    try payload.write(to: stagedFile)

    await coordinator.complete(
        identifier: request.identifier,
        platformError: nil,
        stagedDownloadResult: .file(stagedFile),
        bytesTransferred: 0,
        totalBytesExpected: nil
    )

    let snapshot = try await store.loadSnapshots().first
    let destination = try resolver.resolve(.file(RadrootsFileReference(scope: .cache, relativePath: "field.transfer.completed.json")))
    #expect(snapshot?.state == .completed)
    #expect(snapshot?.progress.bytesTransferred == Int64(payload.count))
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 500))
    #expect(try Data(contentsOf: destination) == payload)
    #expect(!FileManager.default.fileExists(atPath: stagedFile.path))
}

@Test func appleBackgroundTransferCoordinatorRecordsFailedDownloadSnapshot() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer",
        store: store,
        fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 600) }
    )
    let request = try appleTransferRequest(identifier: "field.transfer.download.failed")
    try await store.saveSnapshot(
        try RadrootsBackgroundTransferSnapshot(
            request: request,
            state: .running,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    )

    await coordinator.complete(
        identifier: request.identifier,
        platformError: nil,
        stagedDownloadResult: .failure("temporary file unavailable"),
        bytesTransferred: 0,
        totalBytesExpected: nil
    )

    let snapshot = try await store.loadSnapshots().first
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.errorMessage == "temporary file unavailable")
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 600))
}

@Test func appleBackgroundTransferCoordinatorCompletesUploadWithProgress() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer",
        store: store,
        fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 700) }
    )
    let request = try appleUploadRequest(identifier: "field.transfer.upload.completed")
    try await store.saveSnapshot(
        try RadrootsBackgroundTransferSnapshot(
            request: request,
            state: .running,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    )

    await coordinator.updateProgress(
        identifier: request.identifier,
        bytesTransferred: 4,
        totalBytesExpected: 10
    )
    await coordinator.complete(
        identifier: request.identifier,
        platformError: nil,
        stagedDownloadResult: nil,
        bytesTransferred: 10,
        totalBytesExpected: 10
    )

    let snapshot = try await store.loadSnapshots().first
    #expect(snapshot?.state == .completed)
    #expect(snapshot?.progress.bytesTransferred == 10)
    #expect(snapshot?.progress.totalBytesExpected == 10)
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 700))
}

@Test func appleBackgroundTransferCoordinatorInvokesStoredCompletionHandlerAfterFinishedEvents() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer",
        store: store,
        fileResolver: resolver
    )
    let completion = RadrootsCompletionProbe()
    let unrelated = RadrootsCompletionProbe()

    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") {
        completion.markCompleted()
    }
    #expect(!completion.completed)

    await coordinator.handleBackgroundEvents(identifier: "other.session") {
        unrelated.markCompleted()
    }
    #expect(unrelated.completed)

    await coordinator.finishBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
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

private func appleUploadRequest(identifier: String) throws -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier),
        remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .put,
        operation: .upload(
            source: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))
        )
    )
}

private func appleTransferRoots() throws -> RadrootsAppleFileRoots {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-apple-background-transfer-\(UUID().uuidString)", isDirectory: true)
    return try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
}
