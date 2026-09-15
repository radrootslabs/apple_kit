import Darwin
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
    await #expect(
        throws: RadrootsBackgroundTransferError.invalidRequest
    ) {
        _ = try await transfer.enqueue(request)
    }

    #expect(await probe.enqueuedRequests == [request])
}

@Test func appleBackgroundTransferRecordsFailedSnapshotWhenAdapterRejectsEnqueue() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let probe = RadrootsAppleBackgroundTransferProbe(
        now: Date(timeIntervalSince1970: 200),
        enqueueOutcome: .failure(.transferFailure)
    )
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    let request = try appleTransferRequest(identifier: "field.transfer.failed")

    await #expect(
        throws: RadrootsBackgroundTransferError.transferFailure
    ) {
        _ = try await transfer.enqueue(request)
    }

    let snapshot = try await transfer.snapshot(for: request.identifier)
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.failure == .enqueueFailed)
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
    #expect(
        try await transfer.snapshot(for: request.identifier)?.updatedAt
            == Date(timeIntervalSince1970: 300)
    )
}

@Test func appleBackgroundTransferReconcilesQueuedSnapshotsWithActiveRecoveredTasks() async throws {
    let request = try appleTransferRequest(identifier: "field.transfer.recovered")
    let queued = try RadrootsBackgroundTransferSnapshot(
        request: request, state: .queued, updatedAt: Date(timeIntervalSince1970: 1)
    )
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [queued])
    let probe = RadrootsAppleBackgroundTransferProbe(
        now: Date(timeIntervalSince1970: 400), activeIdentifiers: [request.identifier]
    )
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
        request: request, state: .running,
        progress: RadrootsBackgroundTransferProgress(bytesTransferred: 5, totalBytesExpected: 10),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [running])
    let probe = RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 401))
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

    let snapshot = try #require(try await transfer.snapshots().first)

    #expect(snapshot.state == .interrupted)
    #expect(snapshot.failure == .interrupted)
    #expect(snapshot.possibleRemoteOrphan)
    #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 401))
}

@Test func appleBackgroundTransferForwardsBackgroundCompletionHandlers() async {
    let probe = RadrootsAppleBackgroundTransferProbe()
    let transfer = RadrootsAppleBackgroundTransfer(
        store: RadrootsInMemoryBackgroundTransferStore(), adapters: probe.adapters()
    )
    let completion = RadrootsCompletionProbe()

    await transfer.handleEventsForBackgroundURLSession(
        identifier: "org.radroots.field-ios.background.transfer"
    ) {
        completion.markCompleted()
    }

    #expect(
        await probe.handledBackgroundEventIdentifiers == ["org.radroots.field-ios.background.transfer"]
    )
    #expect(completion.completed)
}

@Test func appleBackgroundTransferCoordinatorMovesCompletedDownloadToDestination() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 500) }
    )
    let request = try appleTransferRequest(identifier: "field.transfer.completed")
    let running = try RadrootsBackgroundTransferSnapshot(
        request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1)
    )
    try await store.saveSnapshot(running)
    let stagingRoot = roots.temporaryRoot.appendingPathComponent(
        "background-transfer-tests", isDirectory: true
    )
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    let stagedFile = stagingRoot.appendingPathComponent("download.bin")
    let payload = Data("downloaded".utf8)
    try payload.write(to: stagedFile)

    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: .file(stagedFile),
            httpResult: RadrootsBackgroundHTTPResult(
                statusCode: 200, mediaType: "image/png", body: nil, bodyExceeded: false
            ),
            bytesTransferred: 0,
            totalBytesExpected: nil
        )
    )

    let snapshot = try await store.loadSnapshots().first
    let destination = try resolver.resolve(
        .file(RadrootsFileReference(scope: .cache, relativePath: "field.transfer.completed.json"))
    )
    #expect(snapshot?.state == .awaitingVerification)
    #expect(snapshot?.progress.bytesTransferred == Int64(payload.count))
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 500))
    #expect(snapshot?.response?.statusCode == 200)
    #expect(snapshot?.downloadedArtifact?.byteSize == UInt64(payload.count))
    #expect(snapshot?.downloadedArtifact?.mediaType == "image/png")
    let downloadedDigest = try RadrootsAppleFileDigest.sha256(at: destination)
    #expect(snapshot?.downloadedArtifact?.sha256 == downloadedDigest)
    #expect(try Data(contentsOf: destination) == payload)
    #expect(!FileManager.default.fileExists(atPath: stagedFile.path))
}

@Test func appleBackgroundTransferCoordinatorRejectsMalformedResponseMediaType() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )
    let request = try appleUploadRequest(identifier: "field.transfer.malformed-media-type")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: request, state: .running)
    )

    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: nil,
            httpResult: RadrootsBackgroundHTTPResult(
                statusCode: 200, mediaType: nil, body: nil, bodyExceeded: false,
                mediaTypeWasMalformed: true
            ),
            bytesTransferred: 10,
            totalBytesExpected: 10
        )
    )

    let snapshot = try #require(try await store.loadSnapshots().first)
    #expect(snapshot.state == .failed)
    #expect(snapshot.failure == .responseMediaType)
    #expect(snapshot.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorRecordsFailedDownloadSnapshot() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 600) }
    )
    let request = try appleTransferRequest(identifier: "field.transfer.download.failed")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(
            request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1)
        )
    )

    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: .failure,
            httpResult: successfulHTTPResult(),
            bytesTransferred: 0,
            totalBytesExpected: nil
        )
    )

    let snapshot = try await store.loadSnapshots().first
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.failure == .downloadStagingFailure)
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 600))
}

@Test func appleBackgroundTransferCoordinatorCompletesUploadWithProgress() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: resolver,
        now: { Date(timeIntervalSince1970: 700) }
    )
    let request = try appleUploadRequest(identifier: "field.transfer.upload.completed")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(
            request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1)
        )
    )

    await coordinator.updateProgress(
        identifier: request.identifier, bytesTransferred: 4, totalBytesExpected: 10
    )
    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: nil,
            httpResult: successfulHTTPResult(),
            bytesTransferred: 10,
            totalBytesExpected: 10
        )
    )

    let snapshot = try await store.loadSnapshots().first
    #expect(snapshot?.state == .awaitingVerification)
    #expect(snapshot?.progress.bytesTransferred == 10)
    #expect(snapshot?.progress.totalBytesExpected == 10)
    #expect(snapshot?.updatedAt == Date(timeIntervalSince1970: 700))
    #expect(snapshot?.response?.statusCode == 200)
}
