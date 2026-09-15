import Darwin
import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func appleBackgroundTransferExpirationAndRetryPreserveStableIdentity() async throws {
    let request = try appleUploadRequest(identifier: "field.transfer.expire-retry")
    let store = RadrootsInMemoryBackgroundTransferStore()
    let probe = RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 900))
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

    _ = try await transfer.enqueue(request)
    try await transfer.expire(request.identifier)
    #expect(try await store.loadSnapshots().first?.state == .expired)
    #expect(await probe.cancelledIdentifiers == [request.identifier])

    let retried = try await transfer.retry(request)
    #expect(retried.identifier == request.identifier)
    #expect(try await store.loadSnapshots().first?.state == .running)
    #expect(await probe.enqueuedRequests == [request, request])
}

@Test func appleBackgroundTransferRefusesRetryWhilePlatformTaskIsStillActive() async throws {
    let request = try appleUploadRequest(identifier: "field.transfer.active-retry")
    let store = try RadrootsInMemoryBackgroundTransferStore(
        snapshots: [RadrootsBackgroundTransferSnapshot(request: request, state: .interrupted)]
    )
    let probe = RadrootsAppleBackgroundTransferProbe(activeIdentifiers: [request.identifier])
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

    await #expect(
        throws: RadrootsBackgroundTransferError.invalidRequest
    ) {
        _ = try await transfer.retry(request)
    }
    #expect(await probe.enqueuedRequests.isEmpty)
    #expect(try await store.loadSnapshots().first?.state == .interrupted)
}

@Test func appleBackgroundTransferTerminalCancellationIsIdempotent() async throws {
    let request = try appleUploadRequest(identifier: "field.transfer.terminal-cancel")
    let store = try RadrootsInMemoryBackgroundTransferStore(
        snapshots: [
            RadrootsBackgroundTransferSnapshot(request: request, state: .awaitingVerification)
        ]
    )
    let probe = RadrootsAppleBackgroundTransferProbe()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

    try await transfer.cancel(request.identifier)
    try await transfer.expire(request.identifier)

    #expect(try await store.loadSnapshots().first?.state == .awaitingVerification)
    #expect(await probe.cancelledIdentifiers.isEmpty)
}

@Test func appleBackgroundTransferCoordinatorRejectsTransfersBeyondImmutableBound() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )
    let request = try appleUploadRequest(
        identifier: "field.transfer.too-large", maximumTransferBytes: 5
    )
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: request, state: .running)
    )

    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: nil,
            httpResult: successfulHTTPResult(),
            bytesTransferred: 6,
            totalBytesExpected: 6
        )
    )

    let snapshot = try #require(try await store.loadSnapshots().first)
    #expect(snapshot.state == .failed)
    #expect(snapshot.failure == .transferTooLarge)
    #expect(snapshot.possibleRemoteOrphan)
}

@Test func appleBackgroundURLTaskDescriptorRetainsRelaunchBoundsAndMigratesLegacyIdentity() throws {
    let request = try appleUploadRequest(
        identifier: "field.transfer.task-descriptor",
        responsePolicy: .boundedJSON(maximumBodyBytes: 1024),
        maximumTransferBytes: 4096
    )

    let descriptor = RadrootsBackgroundURLTaskDescriptor(request: request)
    #expect(
        RadrootsBackgroundURLTaskDescriptor(taskDescription: descriptor.taskDescription) == descriptor
    )

    let legacy = try #require(
        RadrootsBackgroundURLTaskDescriptor(taskDescription: request.identifier.rawValue)
    )
    #expect(legacy.identifier == request.identifier)
    #expect(
        legacy.maximumTransferBytes == RadrootsBackgroundTransferRequest.defaultMaximumTransferBytes
    )
    #expect(legacy.maximumResponseBodyBytes == 65536)
    #expect(
        RadrootsBackgroundURLTaskDescriptor(taskDescription: "radroots-transfer-v1|unsafe|0|0") == nil
    )
}

#if os(iOS) && targetEnvironment(simulator)
    @Test func appleBackgroundTransferLiveURLSessionDownloadsIntoRustVerificationBoundary()
        async throws {
        guard let origin = ProcessInfo.processInfo.environment["RADROOTS_URLSESSION_TEST_ORIGIN"],
              let remoteURL = URL(string: origin)?.appendingPathComponent("Package.swift")
        else { return }
        let roots = try appleTransferRoots()
        defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
        let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
        let transfer = try RadrootsAppleBackgroundTransfer(
            roots: roots,
            sessionIdentifier: "org.radroots.tests.background-transfer.\(UUID().uuidString.lowercased())"
        )
        let destination = RadrootsFileReference(
            scope: .cache, relativePath: "live-urlsession/package.swift"
        )
        let request = try RadrootsBackgroundTransferRequest(
            identifier: RadrootsBackgroundTransferIdentifier("field.transfer.live-urlsession"),
            remoteURL: remoteURL,
            method: .get,
            operation: .download(destination: .file(destination)),
            networkPolicy: .simulatorLoopbackHTTP,
            maximumTransferBytes: 64 * 1024
        )

        _ = try await transfer.enqueue(request)
        let deadline = Date().addingTimeInterval(15)
        var snapshot = try await transfer.snapshot(for: request.identifier)
        while snapshot?.state == .queued || snapshot?.state == .running {
            guard Date() < deadline else {
                throw RadrootsBackgroundTransferError.transferFailure
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            snapshot = try await transfer.snapshot(for: request.identifier)
        }

        let completedTransfer = try #require(snapshot)
        #expect(completedTransfer.state == .awaitingVerification)
        let downloadedArtifact = try #require(completedTransfer.downloadedArtifact)
        let destinationURL = try resolver.resolve(.file(destination))
        let downloadedBytes = try Data(contentsOf: destinationURL)
        #expect(!downloadedBytes.isEmpty)
        #expect(downloadedArtifact.byteSize == UInt64(downloadedBytes.count))
        #expect(try downloadedArtifact.sha256 == (RadrootsAppleFileDigest.sha256(at: destinationURL)))
        #expect(downloadedArtifact.mediaType == "application/octet-stream")

        try await transfer.settle(request.identifier, verification: .accepted)
        #expect(try await transfer.snapshot(for: request.identifier)?.state == .completed)
    }
#endif

@Test func appleBackgroundTransferCancelsRecoveredPlatformOrphans() async throws {
    let identifier = try RadrootsBackgroundTransferIdentifier("field.transfer.platform-orphan")
    let probe = RadrootsAppleBackgroundTransferProbe(activeIdentifiers: [identifier])
    let transfer = RadrootsAppleBackgroundTransfer(
        store: RadrootsInMemoryBackgroundTransferStore(), adapters: probe.adapters()
    )

    #expect(try await transfer.snapshots().isEmpty)
    #expect(await probe.cancelledIdentifiers == [identifier])
}
