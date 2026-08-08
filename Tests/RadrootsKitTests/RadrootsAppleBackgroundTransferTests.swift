import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

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

@Test func appleBackgroundTransferRejectsDuplicateIdentifiersBeforeAdapterMutation() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let probe = RadrootsAppleBackgroundTransferProbe()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    let request = try appleTransferRequest(identifier: "field.transfer.duplicate")

    _ = try await transfer.enqueue(request)
    await #expect(throws: RadrootsBackgroundTransferError.invalidRequest("background transfer identifier already exists")) {
        _ = try await transfer.enqueue(request)
    }

    #expect(await probe.enqueuedRequests == [request])
}

@Test func appleBackgroundTransferRecordsFailedSnapshotWhenAdapterRejectsEnqueue() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let probe = RadrootsAppleBackgroundTransferProbe(
        now: Date(timeIntervalSince1970: 200), enqueueOutcome: .failure(.transferFailure("adapter rejected transfer"))
    )
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    let request = try appleTransferRequest(identifier: "field.transfer.failed")

    await #expect(throws: RadrootsBackgroundTransferError.transferFailure("background transfer enqueue failed")) {
        _ = try await transfer.enqueue(request)
    }

    let snapshot = try await transfer.snapshot(for: request.identifier)
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.errorMessage == "background_transfer_enqueue_failed")
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
    let queued = try RadrootsBackgroundTransferSnapshot(request: request, state: .queued, updatedAt: Date(timeIntervalSince1970: 1))
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [queued])
    let probe = RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 400), activeIdentifiers: [request.identifier])
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

    let snapshots = try await transfer.snapshots()

    #expect(snapshots.count == 1)
    #expect(snapshots.first?.state == .running)
    #expect(snapshots.first?.updatedAt == Date(timeIntervalSince1970: 400))
    #expect(try await store.loadSnapshots().first?.state == .running)
}

@Test func appleBackgroundTransferMarksMissingRecoveredUploadInterrupted() async throws {
    let request = try appleUploadRequest(identifier: "field.transfer.interrupted")
    let running = try RadrootsBackgroundTransferSnapshot(
        request: request, state: .running, progress: RadrootsBackgroundTransferProgress(bytesTransferred: 5, totalBytesExpected: 10),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [running])
    let probe = RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 401))
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

    let snapshot = try #require(try await transfer.snapshots().first)

    #expect(snapshot.state == .interrupted)
    #expect(snapshot.errorMessage == "background_transfer_interrupted")
    #expect(snapshot.possibleRemoteOrphan)
    #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 401))
}

@Test func appleBackgroundTransferForwardsBackgroundCompletionHandlers() async {
    let probe = RadrootsAppleBackgroundTransferProbe()
    let transfer = RadrootsAppleBackgroundTransfer(store: RadrootsInMemoryBackgroundTransferStore(), adapters: probe.adapters())
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
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store, fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 500) }
    )
    let request = try appleTransferRequest(identifier: "field.transfer.completed")
    let running = try RadrootsBackgroundTransferSnapshot(request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1))
    try await store.saveSnapshot(running)
    let stagingRoot = roots.temporaryRoot.appendingPathComponent("background-transfer-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let stagedFile = stagingRoot.appendingPathComponent("download.bin")
    let payload = Data("downloaded".utf8)
    try payload.write(to: stagedFile)

    await coordinator.complete(
        identifier: request.identifier, platformError: nil, stagedDownloadResult: .file(stagedFile), httpResult: successfulHTTPResult(),
        bytesTransferred: 0, totalBytesExpected: nil
    )

    let snapshot = try await store.loadSnapshots().first
    let destination = try resolver.resolve(.file(RadrootsFileReference(scope: .cache, relativePath: "field.transfer.completed.json")))
    #expect(snapshot?.state == .completed)
    #expect(snapshot?.progress.bytesTransferred == Int64(payload.count))
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 500))
    #expect(snapshot?.response?.statusCode == 200)
    #expect(try Data(contentsOf: destination) == payload)
    #expect(!FileManager.default.fileExists(atPath: stagedFile.path))
}

@Test func appleBackgroundTransferCoordinatorRecordsFailedDownloadSnapshot() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store, fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 600) }
    )
    let request = try appleTransferRequest(identifier: "field.transfer.download.failed")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1))
    )

    await coordinator.complete(
        identifier: request.identifier, platformError: nil, stagedDownloadResult: .failure, httpResult: successfulHTTPResult(),
        bytesTransferred: 0, totalBytesExpected: nil
    )

    let snapshot = try await store.loadSnapshots().first
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.errorMessage == "background_transfer_download_staging_failure")
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 600))
}

@Test func appleBackgroundTransferCoordinatorCompletesUploadWithProgress() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store, fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 700) }
    )
    let request = try appleUploadRequest(identifier: "field.transfer.upload.completed")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1))
    )

    await coordinator.updateProgress(identifier: request.identifier, bytesTransferred: 4, totalBytesExpected: 10)
    await coordinator.complete(
        identifier: request.identifier, platformError: nil, stagedDownloadResult: nil, httpResult: successfulHTTPResult(),
        bytesTransferred: 10, totalBytesExpected: 10
    )

    let snapshot = try await store.loadSnapshots().first
    #expect(snapshot?.state == .completed)
    #expect(snapshot?.progress.bytesTransferred == 10)
    #expect(snapshot?.progress.totalBytesExpected == 10)
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 700))
    #expect(snapshot?.response?.statusCode == 200)
}

@Test func appleBackgroundTransferCoordinatorPersistsBoundedDescriptorResponse() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots), now: { Date(timeIntervalSince1970: 710) }
    )
    let body = Data(#"{"url":"https://cdn.radroots.org/a.png"}"#.utf8)
    let request = try appleUploadRequest(
        identifier: "field.transfer.upload.descriptor", responsePolicy: .boundedJSON(maximumBodyBytes: 1024)
    )
    try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: request, state: .running))

    await coordinator.complete(
        identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
        httpResult: RadrootsBackgroundHTTPResult(statusCode: 200, mediaType: "application/json", body: body, bodyExceeded: false),
        bytesTransferred: 10, totalBytesExpected: 10
    )

    let snapshot = try #require(try await store.loadSnapshots().first)
    #expect(snapshot.state == .completed)
    #expect(snapshot.response?.body == body)
    #expect(snapshot.response?.mediaType == "application/json")
    #expect(!snapshot.possibleRemoteOrphan)

    await coordinator.complete(
        identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
        httpResult: RadrootsBackgroundHTTPResult(statusCode: 500, mediaType: nil, body: nil, bodyExceeded: false), bytesTransferred: 10,
        totalBytesExpected: 10
    )
    #expect(try await store.loadSnapshots().first?.state == .completed)
}

@Test func appleBackgroundTransferCoordinatorRejectsStatusAndOversizedResponse() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots), now: { Date(timeIntervalSince1970: 720) }
    )
    let statusRequest = try appleUploadRequest(identifier: "field.transfer.upload.status")
    try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: statusRequest, state: .running))
    await coordinator.complete(
        identifier: statusRequest.identifier, platformError: nil, stagedDownloadResult: nil,
        httpResult: RadrootsBackgroundHTTPResult(statusCode: 503, mediaType: nil, body: nil, bodyExceeded: false), bytesTransferred: 10,
        totalBytesExpected: 10
    )
    #expect(try await store.loadSnapshots().first?.errorMessage == "background_transfer_http_status_503")

    let bodyRequest = try appleUploadRequest(
        identifier: "field.transfer.upload.oversized", responsePolicy: .boundedJSON(maximumBodyBytes: 32)
    )
    try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: bodyRequest, state: .running))
    await coordinator.complete(
        identifier: bodyRequest.identifier, platformError: CancellationError(), stagedDownloadResult: nil,
        httpResult: RadrootsBackgroundHTTPResult(statusCode: 200, mediaType: "application/json", body: nil, bodyExceeded: true),
        bytesTransferred: 10, totalBytesExpected: 10
    )
    let oversized = try #require(try await store.loadSnapshots().first { $0.identifier == bodyRequest.identifier })
    #expect(oversized.state == .failed)
    #expect(oversized.errorMessage == "background_transfer_response_too_large")
    #expect(oversized.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorDoesNotResurrectCancelledTransfer() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )
    let request = try appleUploadRequest(identifier: "field.transfer.upload.cancelled")
    try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: request, state: .cancelled))

    await coordinator.complete(
        identifier: request.identifier, platformError: nil, stagedDownloadResult: nil, httpResult: successfulHTTPResult(),
        bytesTransferred: 10, totalBytesExpected: 10
    )

    #expect(try await store.loadSnapshots().first?.state == .cancelled)
}

@Test func appleBackgroundTransferRecoversCompletionLostWhileProtectedDataIsLocked() async throws {
    let roots = try appleTransferRoots()
    let protectedData = RadrootsProtectedDataProbe(state: .available)
    let store = RadrootsAppleBackgroundTransferStore(roots: roots, protectedData: RadrootsProtectedDataProvider { protectedData.state })
    let request = try appleUploadRequest(identifier: "field.transfer.upload.locked")
    try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: request, state: .running))
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )

    protectedData.state = .locked
    await coordinator.complete(
        identifier: request.identifier, platformError: nil, stagedDownloadResult: nil, httpResult: successfulHTTPResult(),
        bytesTransferred: 10, totalBytesExpected: 10
    )
    protectedData.state = .available

    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: RadrootsAppleBackgroundTransferProbe().adapters())
    let recovered = try #require(try await transfer.snapshots().first)
    #expect(recovered.state == .interrupted)
    #expect(recovered.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorInvokesStoredCompletionHandlerAfterFinishedEvents() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store, fileResolver: resolver
    )
    let completion = RadrootsCompletionProbe()
    let secondCompletion = RadrootsCompletionProbe()
    let unrelated = RadrootsCompletionProbe()

    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") { completion.markCompleted() }
    #expect(!completion.completed)
    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") { secondCompletion.markCompleted() }

    await coordinator.handleBackgroundEvents(identifier: "other.session") { unrelated.markCompleted() }
    #expect(unrelated.completed)

    await coordinator.finishBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
    #expect(completion.completed)
    #expect(secondCompletion.completed)
    await coordinator.finishBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
    #expect(completion.completionCount == 1)
    #expect(secondCompletion.completionCount == 1)
}

@Test func appleBackgroundTransferCoordinatorClaimsFinishBeforeHandlerExactlyOnce() async throws {
    let roots = try appleTransferRoots()
    let coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: RadrootsInMemoryBackgroundTransferStore(),
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )
    let completion = RadrootsCompletionProbe()

    await coordinator.finishBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") { completion.markCompleted() }

    #expect(completion.completionCount == 1)
}

private actor RadrootsAppleBackgroundTransferProbe {
    private let nowValue: Date
    private let enqueueOutcome: Result<Void, RadrootsBackgroundTransferError>
    private var activeIdentifiersValue: Set<RadrootsBackgroundTransferIdentifier>
    private var enqueuedRequestsValue: [RadrootsBackgroundTransferRequest]
    private var cancelledIdentifiersValue: [RadrootsBackgroundTransferIdentifier]
    private var handledBackgroundEventIdentifiersValue: [String]

    init(
        now: Date = Date(timeIntervalSince1970: 0), enqueueOutcome: Result<Void, RadrootsBackgroundTransferError> = .success(()),
        activeIdentifiers: Set<RadrootsBackgroundTransferIdentifier> = []
    ) {
        nowValue = now
        self.enqueueOutcome = enqueueOutcome
        activeIdentifiersValue = activeIdentifiers
        enqueuedRequestsValue = []
        cancelledIdentifiersValue = []
        handledBackgroundEventIdentifiersValue = []
    }

    nonisolated func adapters() -> RadrootsAppleBackgroundTransferAdapters {
        RadrootsAppleBackgroundTransferAdapters(
            now: { self.nowValue }, enqueue: { request in try await self.enqueue(request) },
            cancel: { identifier in await self.cancel(identifier) }, activeTransferIdentifiers: { await self.activeIdentifiers() },
            handleBackgroundEvents: { identifier, completionHandler in
                await self.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
            }
        )
    }

    private func enqueue(_ request: RadrootsBackgroundTransferRequest) throws {
        enqueuedRequestsValue.append(request)
        switch enqueueOutcome {
        case .success: activeIdentifiersValue.insert(request.identifier)
        case let .failure(error): throw error
        }
    }

    private func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) {
        cancelledIdentifiersValue.append(identifier)
        activeIdentifiersValue.remove(identifier)
    }

    private func activeIdentifiers() -> Set<RadrootsBackgroundTransferIdentifier> {
        activeIdentifiersValue
    }

    private func handleBackgroundEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
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
    private let lock = NSLock()
    private var completionCountValue = 0

    func markCompleted() {
        lock.lock()
        completionCountValue += 1
        lock.unlock()
    }

    var completed: Bool {
        completionCount > 0
    }

    var completionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completionCountValue
    }
}

private final class RadrootsProtectedDataProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stateValue: RadrootsProtectedDataState

    init(state: RadrootsProtectedDataState) {
        stateValue = state
    }

    var state: RadrootsProtectedDataState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stateValue
        }
        set {
            lock.lock()
            stateValue = newValue
            lock.unlock()
        }
    }
}

private func appleTransferRequest(identifier: String) throws -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier), remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .get, operation: .download(destination: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json")))
    )
}

private func appleUploadRequest(identifier: String, responsePolicy: RadrootsBackgroundTransferResponsePolicy = .discard) throws
    -> RadrootsBackgroundTransferRequest
{
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier), remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .put, operation: .upload(source: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))),
        responsePolicy: responsePolicy
    )
}

private func successfulHTTPResult() -> RadrootsBackgroundHTTPResult {
    RadrootsBackgroundHTTPResult(statusCode: 200, mediaType: nil, body: nil, bodyExceeded: false)
}

private func appleTransferRoots() throws -> RadrootsAppleFileRoots {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "radroots-apple-background-transfer-\(UUID().uuidString)", isDirectory: true
    )
    return try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests", dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
}
