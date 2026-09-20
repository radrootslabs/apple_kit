import Darwin
import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func receiptBarrierRetriesProgressConflictAndStoreFailureBeforeAcknowledgement() async throws {
    let roots = try appleTransferRoots()
    defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
    let request = try appleUploadRequest(identifier: "receipt.barrier", responsePolicy: .boundedJSON())
    let generation = UUID()
    let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: .running, executionID: generation)
    let store = ReceiptBarrierStore(snapshot: snapshot)
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let coordinator = RadrootsTransferCoordinator(sessionIdentifier: "receipt.tests", store: store,
                                                  fileResolver: resolver)
    let callbacks = RadrootsTransferCallbackQueue()
    let acknowledgement = RadrootsCompletionProbe()
    let body = Data(#"{"url":"https://example.org/blob"}"#.utf8)
    callbacks.enqueue(receipt: request.identifier) {
        await coordinator.complete(identifier: request.identifier,
                                   completion: RadrootsTransferCompletion(
                                       platformError: nil,
                                       stagedDownloadResult: nil,
                                       httpResult: RadrootsBackgroundHTTPResult(statusCode: 200,
                                                                                mediaType: "application/json",
                                                                                body: body,
                                                                                bodyExceeded: false),
                                       bytesTransferred: 10,
                                       totalBytesExpected: 10
                                   ), executionID: generation)
    }
    try await store.waitUntilEntered()
    #expect(await store.entered)
    #expect(callbacks.pendingIdentifiers == [request.identifier])
    for _ in 0 ..< 10 {
        await coordinator.handleBackgroundEvents(identifier: "receipt.tests") { acknowledgement.markCompleted() }
    }
    callbacks.enqueue { await coordinator.finishBackgroundEvents(identifier: "receipt.tests") }
    #expect(!acknowledgement.completed)
    await store.release()
    for _ in 0 ..< 500 {
        if acknowledgement.completionCount == 10 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(acknowledgement.completionCount == 10)
    #expect(await store.terminalAttempts == 4)
    #expect(callbacks.pendingIdentifiers.isEmpty)
    let receipt = try #require(try await store.loadSnapshots().first)
    #expect(receipt.state == .awaitingVerification && receipt.executionID == generation)
    #expect(receipt.response?.body == body && receipt.progress.bytesTransferred == 10)
}

@Test func receiptBarrierSurvivesActualStoreLockAndRecoversAfterPersistence() async throws {
    let roots = try appleTransferRoots()
    defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
    let store = RadrootsAppleBackgroundTransferStore(roots: roots)
    let request = try appleUploadRequest(identifier: "receipt.lock")
    try await store.saveSnapshot(RadrootsBackgroundTransferSnapshot(request: request, state: .running))
    let lockURL = try roots.resolvedURL(for: RadrootsFileReference(scope: .data,
                                                                   relativePath: "background_transfers/transfers.lock"))
    let descriptor = try #require(try RadrootsAtomicFile.acquireExclusiveLock(at: lockURL))
    let coordinator = RadrootsTransferCoordinator(sessionIdentifier: "locked.receipt", store: store,
                                                  fileResolver: RadrootsAppleBackgroundTransferFileResolver(
                                                      roots: roots
                                                  ))
    let pending = Task { await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(platformError: nil, stagedDownloadResult: nil,
                                               httpResult: successfulHTTPResult(),
                                               bytesTransferred: 10,
                                               totalBytesExpected: 10)
    ) }
    for _ in 0 ..< 100 {
        if await coordinator.hasPendingReceipts {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let acknowledgement = RadrootsCompletionProbe()
    await coordinator.handleBackgroundEvents(identifier: "locked.receipt") { acknowledgement.markCompleted() }
    await coordinator.finishBackgroundEvents(identifier: "locked.receipt")
    #expect(!acknowledgement.completed)
    pending.cancel()
    Darwin.close(descriptor)
    await pending.value
    #expect(acknowledgement.completed)
    let restarted = RadrootsAppleBackgroundTransferStore(roots: roots)
    #expect(try await restarted.loadSnapshots().first?.state == .awaitingVerification)
}

private actor ReceiptBarrierStore: RadrootsBackgroundTransferStore {
    private let storage: RadrootsInMemoryBackgroundTransferStore
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var terminalAttempts = 0

    func waitUntilEntered() async throws {
        for _ in 0 ..< 100 {
            if entered {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RadrootsBackgroundTransferError.transferFailure
    }

    init(snapshot: RadrootsBackgroundTransferSnapshot) {
        storage = .init(snapshots: [snapshot])
    }

    func release() {
        gate?.resume(); gate = nil
    }

    func compareExchangeSnapshot(expected: RadrootsBackgroundTransferSnapshot?,
                                 desired: RadrootsBackgroundTransferSnapshot) async throws -> Bool
    {
        if desired.state == .awaitingVerification {
            terminalAttempts += 1
            if terminalAttempts == 1 {
                entered = true
                await withCheckedContinuation { gate = $0 }
                let current = try #require(expected)
                let progress = try RadrootsBackgroundTransferSnapshot(request: current.request, state: .running,
                                                                      progress: RadrootsBackgroundTransferProgress(
                                                                          bytesTransferred: 5,
                                                                          totalBytesExpected: 10
                                                                      ),
                                                                      executionID: current.executionID)
                try await storage.saveSnapshot(progress)
            } else if terminalAttempts <= 3 {
                throw RadrootsBackgroundTransferError.persistenceFailure
            }
        }
        let exchanged = try await storage.compareExchangeSnapshot(expected: expected, desired: desired)
        if desired.state == .awaitingVerification, terminalAttempts == 4, exchanged {
            // The write took effect, but its caller lost the successful return.
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
        return exchanged
    }

    func withAdmission<Result: Sendable>(for identifier: RadrootsBackgroundTransferIdentifier,
                                         operation: @escaping @Sendable () async throws -> Result)
        async throws -> Result
    {
        try await storage.withAdmission(for: identifier, operation: operation)
    }

    func admissionIsActive(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> Bool {
        try await storage.admissionIsActive(for: identifier)
    }

    func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        try await storage.loadSnapshots()
    }

    func saveSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws {
        try await storage.saveSnapshot(snapshot)
    }

    func removeSnapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws {
        try await storage.removeSnapshot(for: identifier)
    }

    func removeAllSnapshots() async throws {
        try await storage.removeAllSnapshots()
    }
}
