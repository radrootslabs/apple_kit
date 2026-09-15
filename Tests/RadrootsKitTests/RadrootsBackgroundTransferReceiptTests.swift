import Darwin
import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func appleBackgroundTransferCoordinatorPersistsBoundedDescriptorResponse() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsTransferCoordinator(
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
        RadrootsBackgroundTransferSnapshot(request: request, state: .running)
    )

    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: nil,
            httpResult: RadrootsBackgroundHTTPResult(
                statusCode: 200, mediaType: "application/json", body: body, bodyExceeded: false
            ),
            bytesTransferred: 10,
            totalBytesExpected: 10
        )
    )

    let snapshot = try #require(try await store.loadSnapshots().first)
    #expect(snapshot.state == .awaitingVerification)
    #expect(snapshot.response?.body == body)
    #expect(snapshot.response?.mediaType == "application/json")
    #expect(!snapshot.possibleRemoteOrphan)

    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: nil,
            httpResult: RadrootsBackgroundHTTPResult(
                statusCode: 500, mediaType: nil, body: nil, bodyExceeded: false
            ),
            bytesTransferred: 10,
            totalBytesExpected: 10
        )
    )
    #expect(try await store.loadSnapshots().first?.state == .awaitingVerification)
}

@Test func appleBackgroundTransferCoordinatorRejectsEncodedDescriptorResponse() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )
    let request = try appleUploadRequest(
        identifier: "field.transfer.upload.encoded",
        responsePolicy: .boundedJSON(maximumBodyBytes: 1024)
    )
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: request, state: .running)
    )

    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: nil,
            httpResult: RadrootsBackgroundHTTPResult(
                statusCode: 200, mediaType: "application/json", body: Data("{}".utf8),
                contentEncoding: "gzip", bodyExceeded: false
            ),
            bytesTransferred: 10,
            totalBytesExpected: 10
        )
    )

    let snapshot = try #require(try await store.loadSnapshots().first)
    #expect(snapshot.state == .failed)
    #expect(snapshot.failure == .responseContentEncoding)
    #expect(snapshot.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorRejectsStatusAndOversizedResponse() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots),
        now: { Date(timeIntervalSince1970: 720) }
    )
    let statusRequest = try appleUploadRequest(identifier: "field.transfer.upload.status")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: statusRequest, state: .running)
    )
    await coordinator.complete(
        identifier: statusRequest.identifier,
        completion: RadrootsTransferCompletion(
            platformError: nil,
            stagedDownloadResult: nil,
            httpResult: RadrootsBackgroundHTTPResult(
                statusCode: 503, mediaType: nil, body: nil, bodyExceeded: false
            ),
            bytesTransferred: 10,
            totalBytesExpected: 10
        )
    )
    #expect(try await store.loadSnapshots().first?.failure == .httpStatus)

    let bodyRequest = try appleUploadRequest(
        identifier: "field.transfer.upload.oversized",
        responsePolicy: .boundedJSON(maximumBodyBytes: 32)
    )
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: bodyRequest, state: .running)
    )
    await coordinator.complete(
        identifier: bodyRequest.identifier,
        completion: RadrootsTransferCompletion(
            platformError: CancellationError(),
            stagedDownloadResult: nil,
            httpResult: RadrootsBackgroundHTTPResult(
                statusCode: 200, mediaType: "application/json", body: nil, bodyExceeded: true
            ),
            bytesTransferred: 10,
            totalBytesExpected: 10
        )
    )
    let oversized = try #require(
        try await store.loadSnapshots().first { $0.identifier == bodyRequest.identifier }
    )
    #expect(oversized.state == .failed)
    #expect(oversized.failure == .responseTooLarge)
    #expect(oversized.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorDoesNotResurrectCancelledTransfer() async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )
    let request = try appleUploadRequest(identifier: "field.transfer.upload.cancelled")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: request, state: .cancelled)
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

    #expect(try await store.loadSnapshots().first?.state == .cancelled)
}

@Test func appleBackgroundTransferRetainsReceiptWhileProtectedDataIsLocked() async throws {
    let roots = try appleTransferRoots()
    let protectedData = RadrootsProtectedDataProbe(state: .available)
    let store = RadrootsAppleBackgroundTransferStore(
        roots: roots, protectedData: RadrootsProtectedDataProvider { protectedData.state }
    )
    let request = try appleUploadRequest(identifier: "field.transfer.upload.locked")
    try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(request: request, state: .running)
    )
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )

    protectedData.state = .locked
    let pending = Task {
        await coordinator.complete(
            identifier: request.identifier,
            completion: RadrootsTransferCompletion(platformError: nil, stagedDownloadResult: nil,
                                                   httpResult: successfulHTTPResult(), bytesTransferred: 10,
                                                   totalBytesExpected: 10)
        )
    }
    for _ in 0 ..< 100 {
        if await coordinator.hasPendingReceipts {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await coordinator.hasPendingReceipts)
    let completion = RadrootsCompletionProbe()
    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") {
        completion.markCompleted()
    }
    await coordinator.finishBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
    #expect(!completion.completed)
    protectedData.state = .available
    await pending.value
    #expect(completion.completed)
    let reopened = RadrootsAppleBackgroundTransferStore(roots: roots)
    let recovered = try #require(try await reopened.loadSnapshots().first)
    #expect(recovered.state == .awaitingVerification)
    #expect(recovered.response?.statusCode == 200)
    #expect(!recovered.possibleRemoteOrphan)
}

@Test func appleBackgroundTransferCoordinatorInvokesStoredCompletionHandlerAfterFinishedEvents()
    async throws {
    let roots = try appleTransferRoots()
    let store = RadrootsInMemoryBackgroundTransferStore()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer", store: store,
        fileResolver: resolver
    )
    let completion = RadrootsCompletionProbe()
    let secondCompletion = RadrootsCompletionProbe()
    let unrelated = RadrootsCompletionProbe()

    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") {
        completion.markCompleted()
    }
    #expect(!completion.completed)
    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") {
        secondCompletion.markCompleted()
    }

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
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "org.radroots.field-ios.background.transfer",
        store: RadrootsInMemoryBackgroundTransferStore(),
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    )
    let completion = RadrootsCompletionProbe()

    await coordinator.finishBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer")
    await coordinator.handleBackgroundEvents(identifier: "org.radroots.field-ios.background.transfer") {
        completion.markCompleted()
    }

    #expect(completion.completionCount == 1)
}

@Test func appleBackgroundTransferRequiresExplicitVerificationSettlement() async throws {
    let request = try appleUploadRequest(identifier: "field.transfer.settlement")
    let response = try RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: nil, body: nil)
    let store = try RadrootsInMemoryBackgroundTransferStore(
        snapshots: [
            RadrootsBackgroundTransferSnapshot(
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
        throws: RadrootsBackgroundTransferError.invalidRequest
    ) {
        try await transfer.settle(request.identifier, verification: .accepted)
    }
}

@Test func appleBackgroundTransferRejectedVerificationRemainsRecoverableWithoutClaimingSuccess()
    async throws {
    let request = try appleUploadRequest(identifier: "field.transfer.rejected")
    let store = try RadrootsInMemoryBackgroundTransferStore(
        snapshots: [
            RadrootsBackgroundTransferSnapshot(
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
        verification: .rejected(failure: .verificationRejected)
    )

    let snapshot = try #require(try await store.loadSnapshots().first)
    #expect(snapshot.state == .failed)
    #expect(snapshot.failure == .verificationRejected)
    #expect(snapshot.possibleRemoteOrphan)
    #expect(snapshot.response == nil)
}
