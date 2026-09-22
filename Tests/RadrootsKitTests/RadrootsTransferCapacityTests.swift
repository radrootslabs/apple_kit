import Darwin
import Foundation
@testable import RadrootsKit
import Testing

@Test func transferCapacityRetainsPriorOrAmbiguousReceiptWithoutSuccess() async throws {
    for phase in [RadrootsAtomicFile.Phase.beforeInstall, .beforeDirectorySync] {
        let fixture = try CapacityFixture()
        defer { fixture.remove() }
        let live = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
        let request = try appleUploadRequest(identifier: "original")
        let original = try RadrootsBackgroundTransferSnapshot(request: request, state: .running, executionID: UUID())
        try await live.saveSnapshot(original)
        let receipt = try RadrootsBackgroundTransferSnapshot(request: request, state: .awaitingVerification,
            response: RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: nil, body: nil),
            executionID: original.executionID)
        let faulted = RadrootsAppleBackgroundTransferStore(roots: fixture.roots, persistence: capacityPersistence(phase))
        await #expect(throws: RadrootsBackgroundTransferError.spaceInsufficient) {
            _ = try await faulted.compareExchangeSnapshot(expected: original, desired: receipt)
        }
        let reopened = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
        let observed = try #require(try await reopened.loadSnapshots().first)
        #expect(observed == (phase == .beforeDirectorySync ? receipt : original))
        if observed == original {
            #expect(try await reopened.compareExchangeSnapshot(expected: original, desired: receipt))
        } else {
            #expect(try await !reopened.compareExchangeSnapshot(expected: original, desired: receipt))
        }
        #expect(try await reopened.loadSnapshots() == [receipt])
    }
}

@Test func transferCapacityFailureDoesNotEnqueueOrReidentifyOriginalRequest() async throws {
    let fixture = try CapacityFixture()
    defer { fixture.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots, persistence: capacityPersistence(.beforeInstall))
    let probe = RadrootsAppleBackgroundTransferProbe()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    let request = try appleUploadRequest(identifier: "original_request")
    await #expect(throws: RadrootsBackgroundTransferError.spaceInsufficient) { _ = try await transfer.enqueue(request) }
    #expect(await probe.enqueuedRequests.isEmpty)
    #expect(try await store.loadSnapshots().isEmpty)
    let live = RadrootsAppleBackgroundTransfer(store: RadrootsAppleBackgroundTransferStore(roots: fixture.roots),
                                             adapters: probe.adapters())
    let handle = try await live.enqueue(request)
    #expect(handle.identifier == request.identifier)
    #expect(await probe.enqueuedRequests == [request])
}

@Test func transferCapacityFromUploadLeaseReachesCallerAndRetainsAttempt() async throws {
    let fixture = try CapacityFixture()
    defer { fixture.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let adapters = RadrootsAppleBackgroundTransferAdapters(enqueue: { _, _ in
        throw RadrootsAppleFileError.spaceInsufficient
    }, cancel: { _ in }, activeTransferIdentifiers: { [] }, handleBackgroundEvents: { _, done in done() })
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: adapters)
    let request = try appleUploadRequest(identifier: "lease_failure")
    await #expect(throws: RadrootsBackgroundTransferError.spaceInsufficient) { _ = try await transfer.enqueue(request) }
    let retained = try #require(try await store.loadSnapshots().first)
    #expect(retained.identifier == request.identifier)
    #expect(retained.executionID != nil)
    #expect(retained.state == .failed)
    #expect(retained.possibleRemoteOrphan)
}

@Test func transferReceiptQuotaRetainsEveryPriorReceiptAndIsNotDiskCapacity() async throws {
    let fixture = try CapacityFixture()
    defer { fixture.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let body = try JSONSerialization.data(withJSONObject: ["padding": String(repeating: "a", count: 65000)])
    var retained: [RadrootsBackgroundTransferSnapshot] = []
    var refused = false
    for index in 0 ..< 16 {
        let request = try appleUploadRequest(identifier: "receipt_\(index)", responsePolicy: .boundedJSON(maximumBodyBytes: 65536))
        let receipt = try RadrootsBackgroundTransferSnapshot(request: request, state: .awaitingVerification,
            response: RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: "application/json", body: body),
            executionID: UUID())
        do {
            try await store.saveSnapshot(receipt)
            retained.append(receipt)
        } catch let error as RadrootsBackgroundTransferError {
            #expect(error == .receiptCapacityExceeded)
            refused = true
            break
        }
    }
    #expect(refused)
    #expect(!retained.isEmpty)
    let reopened = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    #expect(try await reopened.loadSnapshots() == retained.sorted { $0.identifier < $1.identifier })
    // Cache purge cannot authorize deleting unresolved receipts or claim the
    // envelope quota has become available.
    try RadrootsAppleFileAccess(roots: fixture.roots).reset(scope: .cache)
    #expect(try await reopened.loadSnapshots() == retained.sorted { $0.identifier < $1.identifier })
}

@Test func transferCapacityRetainsPendingCallbackAndDefersAcknowledgement() async throws {
    let fixture = try CapacityFixture()
    defer { fixture.remove() }
    let gate = CapacityFaultGate()
    defer { gate.enabled = false }
    let persistence = RadrootsFilePersistence(install: { bytes, url, mode, readOnly in
        try RadrootsAtomicFile.installForTesting(bytes, at: url, mode: mode, readOnly: readOnly) { phase in
            if phase == .beforeInstall, gate.enabled { throw RadrootsAppleFileError.spaceInsufficient }
        }
    }, synchronize: { try RadrootsAtomicFile.synchronizeExisting(at: $0) })
    let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots, persistence: persistence)
    let request = try appleUploadRequest(identifier: "pending_receipt")
    let original = try RadrootsBackgroundTransferSnapshot(request: request, state: .running)
    try await store.saveSnapshot(original)
    gate.enabled = true
    let coordinator = RadrootsTransferCoordinator(sessionIdentifier: "capacity.test", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: fixture.roots))
    let pending = Task {
        await coordinator.complete(identifier: request.identifier,
            completion: RadrootsTransferCompletion(platformError: nil, stagedDownloadResult: nil,
                httpResult: successfulHTTPResult(), bytesTransferred: 10, totalBytesExpected: 10))
    }
    for _ in 0 ..< 100 {
        if await coordinator.hasPendingReceipts { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await coordinator.hasPendingReceipts)
    let completion = RadrootsCompletionProbe()
    await coordinator.handleBackgroundEvents(identifier: "capacity.test") { completion.markCompleted() }
    await coordinator.finishBackgroundEvents(identifier: "capacity.test")
    #expect(!completion.completed)
    #expect(try await store.loadSnapshots() == [original])
    gate.enabled = false
    await pending.value
    #expect(completion.completionCount == 1)
    let reopened = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let receipt = try #require(try await reopened.loadSnapshots().first)
    #expect(receipt.identifier == request.identifier)
    #expect(receipt.state == .awaitingVerification)
    #expect(receipt.response?.statusCode == 200)
}

/// The test mutates one Boolean across actor calls; every access holds this lock.
private final class CapacityFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
