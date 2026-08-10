import Foundation
import RadrootsKitTesting
import Testing

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

@Test func appleBackgroundTransferRejectsDuplicateIdentifiersBeforeAdapterMutation() async throws {
  let store = RadrootsInMemoryBackgroundTransferStore()
  let probe = RadrootsAppleBackgroundTransferProbe()
  let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
  let request = try appleTransferRequest(identifier: "field.transfer.duplicate")

  _ = try await transfer.enqueue(request)
  await #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer identifier already exists")
  ) {
    _ = try await transfer.enqueue(request)
  }

  #expect(await probe.enqueuedRequests == [request])
}

@Test func appleBackgroundTransferRecordsFailedSnapshotWhenAdapterRejectsEnqueue() async throws {
  let store = RadrootsInMemoryBackgroundTransferStore()
  let probe = RadrootsAppleBackgroundTransferProbe(
    now: Date(timeIntervalSince1970: 200),
    enqueueOutcome: .failure(.transferFailure("adapter rejected transfer"))
  )
  let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
  let request = try appleTransferRequest(identifier: "field.transfer.failed")

  await #expect(
    throws: RadrootsBackgroundTransferError.transferFailure("background transfer enqueue failed")
  ) {
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
  #expect(
    try await transfer.snapshot(for: request.identifier)?.updatedAt
      == Date(timeIntervalSince1970: 300))
}

@Test func appleBackgroundTransferReconcilesQueuedSnapshotsWithActiveRecoveredTasks() async throws {
  let request = try appleTransferRequest(identifier: "field.transfer.recovered")
  let queued = try RadrootsBackgroundTransferSnapshot(
    request: request, state: .queued, updatedAt: Date(timeIntervalSince1970: 1))
  let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [queued])
  let probe = RadrootsAppleBackgroundTransferProbe(
    now: Date(timeIntervalSince1970: 400), activeIdentifiers: [request.identifier])
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
  #expect(snapshot.errorMessage == "background_transfer_interrupted")
  #expect(snapshot.possibleRemoteOrphan)
  #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 401))
}

@Test func appleBackgroundTransferForwardsBackgroundCompletionHandlers() async {
  let probe = RadrootsAppleBackgroundTransferProbe()
  let transfer = RadrootsAppleBackgroundTransfer(
    store: RadrootsInMemoryBackgroundTransferStore(), adapters: probe.adapters())
  let completion = RadrootsCompletionProbe()

  await transfer.handleEventsForBackgroundURLSession(
    identifier: "org.radroots.field-ios.background.transfer"
  ) {
    completion.markCompleted()
  }

  #expect(
    await probe.handledBackgroundEventIdentifiers == ["org.radroots.field-ios.background.transfer"])
  #expect(completion.completed)
}

@Test func appleBackgroundTransferCoordinatorMovesCompletedDownloadToDestination() async throws {
  let roots = try appleTransferRoots()
  let store = RadrootsInMemoryBackgroundTransferStore()
  let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: resolver,
    now: { Date(timeIntervalSince1970: 500) }
  )
  let request = try appleTransferRequest(identifier: "field.transfer.completed")
  let running = try RadrootsBackgroundTransferSnapshot(
    request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1))
  try await store.saveSnapshot(running)
  let stagingRoot = roots.temporaryRoot.appendingPathComponent(
    "background-transfer-tests", isDirectory: true)
  try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
  let stagedFile = stagingRoot.appendingPathComponent("download.bin")
  let payload = Data("downloaded".utf8)
  try payload.write(to: stagedFile)

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: .file(stagedFile),
    httpResult: RadrootsBackgroundHTTPResult(
      statusCode: 200, mediaType: "image/png", body: nil, bodyExceeded: false),
    bytesTransferred: 0, totalBytesExpected: nil
  )

  let snapshot = try await store.loadSnapshots().first
  let destination = try resolver.resolve(
    .file(RadrootsFileReference(scope: .cache, relativePath: "field.transfer.completed.json")))
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
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  )
  let request = try appleUploadRequest(identifier: "field.transfer.malformed-media-type")
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: request, state: .running))

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: RadrootsBackgroundHTTPResult(
      statusCode: 200, mediaType: nil, body: nil, bodyExceeded: false,
      mediaTypeWasMalformed: true),
    bytesTransferred: 10, totalBytesExpected: 10
  )

  let snapshot = try #require(try await store.loadSnapshots().first)
  #expect(snapshot.state == .failed)
  #expect(snapshot.errorMessage == "background_transfer_response_media_type")
  #expect(snapshot.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorRecordsFailedDownloadSnapshot() async throws {
  let roots = try appleTransferRoots()
  let store = RadrootsInMemoryBackgroundTransferStore()
  let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: resolver,
    now: { Date(timeIntervalSince1970: 600) }
  )
  let request = try appleTransferRequest(identifier: "field.transfer.download.failed")
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(
      request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1))
  )

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: .failure,
    httpResult: successfulHTTPResult(),
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
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: resolver,
    now: { Date(timeIntervalSince1970: 700) }
  )
  let request = try appleUploadRequest(identifier: "field.transfer.upload.completed")
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(
      request: request, state: .running, updatedAt: Date(timeIntervalSince1970: 1))
  )

  await coordinator.updateProgress(
    identifier: request.identifier, bytesTransferred: 4, totalBytesExpected: 10)
  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: successfulHTTPResult(),
    bytesTransferred: 10, totalBytesExpected: 10
  )

  let snapshot = try await store.loadSnapshots().first
  #expect(snapshot?.state == .awaitingVerification)
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
    fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots),
    now: { Date(timeIntervalSince1970: 710) }
  )
  let body = Data(#"{"url":"https://cdn.radroots.org/a.png"}"#.utf8)
  let request = try appleUploadRequest(
    identifier: "field.transfer.upload.descriptor",
    responsePolicy: .boundedJSON(maximumBodyBytes: 1024)
  )
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: request, state: .running))

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: RadrootsBackgroundHTTPResult(
      statusCode: 200, mediaType: "application/json", body: body, bodyExceeded: false),
    bytesTransferred: 10, totalBytesExpected: 10
  )

  let snapshot = try #require(try await store.loadSnapshots().first)
  #expect(snapshot.state == .awaitingVerification)
  #expect(snapshot.response?.body == body)
  #expect(snapshot.response?.mediaType == "application/json")
  #expect(!snapshot.possibleRemoteOrphan)

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: RadrootsBackgroundHTTPResult(
      statusCode: 500, mediaType: nil, body: nil, bodyExceeded: false), bytesTransferred: 10,
    totalBytesExpected: 10
  )
  #expect(try await store.loadSnapshots().first?.state == .awaitingVerification)
}

@Test func appleBackgroundTransferCoordinatorRejectsEncodedDescriptorResponse() async throws {
  let roots = try appleTransferRoots()
  let store = RadrootsInMemoryBackgroundTransferStore()
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  )
  let request = try appleUploadRequest(
    identifier: "field.transfer.upload.encoded",
    responsePolicy: .boundedJSON(maximumBodyBytes: 1024)
  )
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: request, state: .running))

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: RadrootsBackgroundHTTPResult(
      statusCode: 200, mediaType: "application/json", body: Data("{}".utf8),
      contentEncoding: "gzip", bodyExceeded: false),
    bytesTransferred: 10, totalBytesExpected: 10
  )

  let snapshot = try #require(try await store.loadSnapshots().first)
  #expect(snapshot.state == .failed)
  #expect(snapshot.errorMessage == "background_transfer_response_content_encoding")
  #expect(snapshot.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorRejectsStatusAndOversizedResponse() async throws {
  let roots = try appleTransferRoots()
  let store = RadrootsInMemoryBackgroundTransferStore()
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots),
    now: { Date(timeIntervalSince1970: 720) }
  )
  let statusRequest = try appleUploadRequest(identifier: "field.transfer.upload.status")
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: statusRequest, state: .running))
  await coordinator.complete(
    identifier: statusRequest.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: RadrootsBackgroundHTTPResult(
      statusCode: 503, mediaType: nil, body: nil, bodyExceeded: false), bytesTransferred: 10,
    totalBytesExpected: 10
  )
  #expect(
    try await store.loadSnapshots().first?.errorMessage == "background_transfer_http_status_503")

  let bodyRequest = try appleUploadRequest(
    identifier: "field.transfer.upload.oversized",
    responsePolicy: .boundedJSON(maximumBodyBytes: 32)
  )
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: bodyRequest, state: .running))
  await coordinator.complete(
    identifier: bodyRequest.identifier, platformError: CancellationError(),
    stagedDownloadResult: nil,
    httpResult: RadrootsBackgroundHTTPResult(
      statusCode: 200, mediaType: "application/json", body: nil, bodyExceeded: true),
    bytesTransferred: 10, totalBytesExpected: 10
  )
  let oversized = try #require(
    try await store.loadSnapshots().first { $0.identifier == bodyRequest.identifier })
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
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: request, state: .cancelled))

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: successfulHTTPResult(),
    bytesTransferred: 10, totalBytesExpected: 10
  )

  #expect(try await store.loadSnapshots().first?.state == .cancelled)
}

@Test func appleBackgroundTransferRecoversCompletionLostWhileProtectedDataIsLocked() async throws {
  let roots = try appleTransferRoots()
  let protectedData = RadrootsProtectedDataProbe(state: .available)
  let store = RadrootsAppleBackgroundTransferStore(
    roots: roots, protectedData: RadrootsProtectedDataProvider { protectedData.state })
  let request = try appleUploadRequest(identifier: "field.transfer.upload.locked")
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: request, state: .running))
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  )

  protectedData.state = .locked
  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: successfulHTTPResult(),
    bytesTransferred: 10, totalBytesExpected: 10
  )
  protectedData.state = .available

  let transfer = RadrootsAppleBackgroundTransfer(
    store: store, adapters: RadrootsAppleBackgroundTransferProbe().adapters())
  let recovered = try #require(try await transfer.snapshots().first)
  #expect(recovered.state == .interrupted)
  #expect(recovered.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorInvokesStoredCompletionHandlerAfterFinishedEvents()
  async throws
{
  let roots = try appleTransferRoots()
  let store = RadrootsInMemoryBackgroundTransferStore()
  let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: resolver
  )
  let completion = RadrootsCompletionProbe()
  let secondCompletion = RadrootsCompletionProbe()
  let unrelated = RadrootsCompletionProbe()

  await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
  { completion.markCompleted() }
  #expect(!completion.completed)
  await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
  { secondCompletion.markCompleted() }

  await coordinator.handleBackgroundEvents(identifier: "other.session") {
    unrelated.markCompleted()
  }
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
    sessionIdentifier: "org.radroots.field-ios.background.transfer",
    store: RadrootsInMemoryBackgroundTransferStore(),
    fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  )
  let completion = RadrootsCompletionProbe()

  await coordinator.finishBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
  await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
  { completion.markCompleted() }

  #expect(completion.completionCount == 1)
}

@Test func appleBackgroundTransferRequiresExplicitVerificationSettlement() async throws {
  let request = try appleUploadRequest(identifier: "field.transfer.settlement")
  let response = try RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: nil, body: nil)
  let store = RadrootsInMemoryBackgroundTransferStore(
    snapshots: [
      try RadrootsBackgroundTransferSnapshot(
        request: request,
        state: .awaitingVerification,
        response: response
      )
    ]
  )
  let transfer = RadrootsAppleBackgroundTransfer(
    store: store,
    adapters: RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 800)).adapters()
  )

  try await transfer.settle(request.identifier, verification: .accepted)

  #expect(try await store.loadSnapshots().first?.state == .completed)
  #expect(try await store.loadSnapshots().first?.response == response)
  await #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest(
      "background transfer is not awaiting verification")
  ) {
    try await transfer.settle(request.identifier, verification: .accepted)
  }
}

@Test func appleBackgroundTransferRejectedVerificationRemainsRecoverableWithoutClaimingSuccess()
  async throws
{
  let request = try appleUploadRequest(identifier: "field.transfer.rejected")
  let store = RadrootsInMemoryBackgroundTransferStore(
    snapshots: [
      try RadrootsBackgroundTransferSnapshot(
        request: request,
        state: .awaitingVerification,
        response: RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: nil, body: nil)
      )
    ]
  )
  let transfer = RadrootsAppleBackgroundTransfer(
    store: store,
    adapters: RadrootsAppleBackgroundTransferProbe(now: Date(timeIntervalSince1970: 850)).adapters()
  )

  try await transfer.settle(
    request.identifier,
    verification: .rejected(code: "background_transfer_rust_verification_failed")
  )

  let snapshot = try #require(try await store.loadSnapshots().first)
  #expect(snapshot.state == .failed)
  #expect(snapshot.errorMessage == "background_transfer_rust_verification_failed")
  #expect(snapshot.possibleRemoteOrphan)
  #expect(snapshot.response == nil)
}

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
  let store = RadrootsInMemoryBackgroundTransferStore(
    snapshots: [try RadrootsBackgroundTransferSnapshot(request: request, state: .interrupted)]
  )
  let probe = RadrootsAppleBackgroundTransferProbe(activeIdentifiers: [request.identifier])
  let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())

  await #expect(
    throws: RadrootsBackgroundTransferError.invalidRequest("background transfer is still active")
  ) {
    _ = try await transfer.retry(request)
  }
  #expect(await probe.enqueuedRequests.isEmpty)
  #expect(try await store.loadSnapshots().first?.state == .interrupted)
}

@Test func appleBackgroundTransferTerminalCancellationIsIdempotent() async throws {
  let request = try appleUploadRequest(identifier: "field.transfer.terminal-cancel")
  let store = RadrootsInMemoryBackgroundTransferStore(
    snapshots: [
      try RadrootsBackgroundTransferSnapshot(request: request, state: .awaitingVerification)
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
  let coordinator = RadrootsAppleBackgroundTransferCoordinator(
    sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
    fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
  )
  let request = try appleUploadRequest(
    identifier: "field.transfer.too-large", maximumTransferBytes: 5)
  try await store.saveSnapshot(
    RadrootsBackgroundTransferSnapshot(request: request, state: .running))

  await coordinator.complete(
    identifier: request.identifier, platformError: nil, stagedDownloadResult: nil,
    httpResult: successfulHTTPResult(),
    bytesTransferred: 6, totalBytesExpected: 6
  )

  let snapshot = try #require(try await store.loadSnapshots().first)
  #expect(snapshot.state == .failed)
  #expect(snapshot.errorMessage == "background_transfer_transfer_too_large")
  #expect(snapshot.possibleRemoteOrphan)
}

@Test func appleBackgroundURLTaskDescriptorRetainsRelaunchBoundsAndMigratesLegacyIdentity() throws {
  let request = try appleUploadRequest(
    identifier: "field.transfer.task-descriptor",
    responsePolicy: .boundedJSON(maximumBodyBytes: 1_024),
    maximumTransferBytes: 4_096
  )

  let descriptor = RadrootsBackgroundURLTaskDescriptor(request: request)
  #expect(
    RadrootsBackgroundURLTaskDescriptor(taskDescription: descriptor.taskDescription) == descriptor)

  let legacy = try #require(
    RadrootsBackgroundURLTaskDescriptor(taskDescription: request.identifier.rawValue))
  #expect(legacy.identifier == request.identifier)
  #expect(
    legacy.maximumTransferBytes == RadrootsBackgroundTransferRequest.defaultMaximumTransferBytes)
  #expect(legacy.maximumResponseBodyBytes == 65_536)
  #expect(
    RadrootsBackgroundURLTaskDescriptor(taskDescription: "radroots-transfer-v1|unsafe|0|0") == nil)
}

#if os(iOS) && targetEnvironment(simulator)
  @Test func appleBackgroundTransferLiveURLSessionDownloadsIntoRustVerificationBoundary()
    async throws
  {
    guard let origin = ProcessInfo.processInfo.environment["RADROOTS_URLSESSION_TEST_ORIGIN"],
      let remoteURL = URL(string: origin)?.appendingPathComponent("Package.swift")
    else { return }
    let roots = try appleTransferRoots()
    defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let stagingRoot = roots.temporaryRoot.appendingPathComponent(
      "live-urlsession", isDirectory: true)
    let adapters = try RadrootsAppleBackgroundTransferAdapters.simulatorForegroundIntegration(
      sessionIdentifier: "org.radroots.tests.background-transfer.\(UUID().uuidString.lowercased())",
      store: store,
      fileResolver: resolver,
      downloadStagingRoot: stagingRoot
    )
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: adapters)
    let destination = RadrootsFileReference(
      scope: .cache, relativePath: "live-urlsession/package.swift")
    let request = try RadrootsBackgroundTransferRequest(
      identifier: RadrootsBackgroundTransferIdentifier("field.transfer.live-urlsession"),
      remoteURL: remoteURL,
      method: .get,
      operation: .download(destination: .file(destination)),
      networkPolicy: .simulatorLoopbackHTTP,
      maximumTransferBytes: 64 * 1_024
    )

    _ = try await transfer.enqueue(request)
    let deadline = Date().addingTimeInterval(15)
    var snapshot = try await transfer.snapshot(for: request.identifier)
    while snapshot?.state == .queued || snapshot?.state == .running {
      guard Date() < deadline else {
        throw RadrootsBackgroundTransferError.transferFailure(
          "background_transfer_live_test_timed_out")
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
    #expect(downloadedArtifact.sha256 == (try RadrootsAppleFileDigest.sha256(at: destinationURL)))
    #expect(downloadedArtifact.mediaType == "application/octet-stream")

    try await transfer.settle(request.identifier, verification: .accepted)
    #expect(try await transfer.snapshot(for: request.identifier)?.state == .completed)
  }
#endif

@Test func appleBackgroundTransferCancelsRecoveredPlatformOrphans() async throws {
  let identifier = try RadrootsBackgroundTransferIdentifier("field.transfer.platform-orphan")
  let probe = RadrootsAppleBackgroundTransferProbe(activeIdentifiers: [identifier])
  let transfer = RadrootsAppleBackgroundTransfer(
    store: RadrootsInMemoryBackgroundTransferStore(), adapters: probe.adapters())

  #expect(try await transfer.snapshots().isEmpty)
  #expect(await probe.cancelledIdentifiers == [identifier])
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
      cancel: { identifier in await self.cancel(identifier) },
      activeTransferIdentifiers: { await self.activeIdentifiers() },
      handleBackgroundEvents: { identifier, completionHandler in
        await self.handleBackgroundEvents(
          identifier: identifier, completionHandler: completionHandler)
      }
    )
  }

  private func enqueue(_ request: RadrootsBackgroundTransferRequest) throws {
    enqueuedRequestsValue.append(request)
    switch enqueueOutcome {
    case .success: activeIdentifiersValue.insert(request.identifier)
    case .failure(let error): throw error
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
    identifier: String, completionHandler: @escaping @Sendable () -> Void
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
    identifier: RadrootsBackgroundTransferIdentifier(identifier),
    remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
    method: .get,
    operation: .download(
      destination: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json")))
  )
}

private func appleUploadRequest(
  identifier: String,
  responsePolicy: RadrootsBackgroundTransferResponsePolicy = .discard,
  maximumTransferBytes: UInt64 = RadrootsBackgroundTransferRequest.defaultMaximumTransferBytes
) throws
  -> RadrootsBackgroundTransferRequest
{
  try RadrootsBackgroundTransferRequest(
    identifier: RadrootsBackgroundTransferIdentifier(identifier),
    remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
    method: .put,
    operation: .upload(
      source: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))),
    responsePolicy: responsePolicy, maximumTransferBytes: maximumTransferBytes
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
    appIdentifier: "org.radroots.tests",
    dataRoot: root.appendingPathComponent("data", isDirectory: true),
    cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
    temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
  )
}
