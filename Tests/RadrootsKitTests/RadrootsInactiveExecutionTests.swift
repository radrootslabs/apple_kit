import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func inactiveExecutionRefusesActiveTerminalSnapshots() async throws {
    let request = try appleUploadRequest(identifier: "renewal.active")
    for state: RadrootsBackgroundTransferState in [.failed, .expired, .cancelled, .interrupted] {
        let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: state, executionID: UUID())
        let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [snapshot])
        let probe = RadrootsAppleBackgroundTransferProbe(activeIdentifiers: [request.identifier])
        let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
        let called = RadrootsCompletionProbe()
        await #expect(throws: RadrootsBackgroundTransferError.transferFailure) {
            try await transfer.withInactiveExecution(for: request.identifier) { _ in called.markCompleted() }
        }
        #expect(!called.completed)
        #expect(try await store.loadSnapshots() == [snapshot])
        #expect(await probe.enqueuedRequests.isEmpty)
        #expect(await probe.cancelledIdentifiers.isEmpty)
        #expect(try await !store.admissionIsActive(for: request.identifier))
    }
}

@Test func inactiveExecutionRefusesUnreconciledOrReceiptedSnapshots() async throws {
    let request = try appleUploadRequest(identifier: "renewal.receipt")
    for state: RadrootsBackgroundTransferState in [.queued, .running, .awaitingVerification, .completed] {
        let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: state)
        let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [snapshot])
        let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: RadrootsAppleBackgroundTransferProbe().adapters())
        let called = RadrootsCompletionProbe()
        await #expect(throws: RadrootsBackgroundTransferError.transferFailure) {
            try await transfer.withInactiveExecution(for: request.identifier) { _ in called.markCompleted() }
        }
        #expect(!called.completed)
        #expect(try await store.loadSnapshots() == [snapshot])
    }
}

@Test func inactiveExecutionUnknownInventoryPreservesEvidence() async throws {
    let request = try appleUploadRequest(identifier: "renewal.unknown")
    let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: .expired)
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [snapshot])
    let called = RadrootsCompletionProbe()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: .unavailable)
    await #expect(throws: RadrootsBackgroundTransferError.unavailable) {
        try await transfer.withInactiveExecution(for: request.identifier) { _ in called.markCompleted() }
    }
    #expect(!called.completed)
    #expect(try await store.loadSnapshots() == [snapshot])
    #expect(try await !store.admissionIsActive(for: request.identifier))
}

@Test func inactiveExecutionSuppliesExactRedactedSnapshotOrAbsenceThroughExistential() async throws {
    let request = try appleUploadRequest(identifier: "renewal.inactive")
    let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: .expired, executionID: UUID())
    for snapshots in [[], [snapshot]] {
        let store = RadrootsInMemoryBackgroundTransferStore(snapshots: snapshots)
        let probe = RadrootsAppleBackgroundTransferProbe()
        let transfer: any RadrootsBackgroundTransfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
        let result = try await transfer.withInactiveExecution(for: request.identifier) { observed in
            #expect(observed == snapshots.first)
            let reserved = try await store.admissionIsActive(for: request.identifier)
            #expect(reserved)
            return "caller-result"
        }
        #expect(result == "caller-result")
        #expect(try await store.loadSnapshots() == snapshots)
        #expect(await probe.enqueuedRequests.isEmpty)
        #expect(await probe.cancelledIdentifiers.isEmpty)
        #expect(try await !store.admissionIsActive(for: request.identifier))
    }
}

@Test func inactiveExecutionFencesIndependentOwnersAndRetainsLateReceipt() async throws {
    let roots = try appleTransferRoots()
    defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
    let request = try appleUploadRequest(identifier: "renewal.exclusive")
    let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: .interrupted, executionID: UUID())
    let late = try snapshot.transitioned(to: .awaitingVerification, at: Date())
    let firstStore = RadrootsAppleBackgroundTransferStore(roots: roots)
    let otherStore = RadrootsAppleBackgroundTransferStore(roots: roots)
    try await firstStore.saveSnapshot(snapshot)
    let probe = RadrootsAppleBackgroundTransferProbe()
    let first = RadrootsAppleBackgroundTransfer(store: firstStore, adapters: probe.adapters())
    let other = RadrootsAppleBackgroundTransfer(store: otherStore, adapters: probe.adapters())
    let result = try await first.withInactiveExecution(for: request.identifier) { observed in
        #expect(observed == snapshot)
        await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) { _ = try await other.retry(request) }
        await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
            try await other.withInactiveExecution(for: request.identifier) { _ in Issue.record("Competing renewal admitted") }
        }
        await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) { _ = try await first.retry(request) }
        // Delegate persistence remains available during the long reservation.
        let retained = try await otherStore.compareExchangeSnapshot(expected: snapshot, desired: late)
        #expect(retained)
        return 42
    }
    #expect(result == 42)
    #expect(try await otherStore.loadSnapshots() == [late])
    #expect(try await !otherStore.admissionIsActive(for: request.identifier))
    #expect(await probe.enqueuedRequests.isEmpty)
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) {
        try await other.withInactiveExecution(for: request.identifier) { _ in Issue.record("Receipt discarded") }
    }
}

@Test func inactiveExecutionCallerDenialReleasesAdmissionAndPreservesError() async throws {
    let request = try appleUploadRequest(identifier: "renewal.denied")
    let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: .expired)
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [snapshot])
    let probe = RadrootsAppleBackgroundTransferProbe()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: probe.adapters())
    await #expect(throws: RenewalTestDenial.denied) {
        try await transfer.withInactiveExecution(for: request.identifier) { _ in throw RenewalTestDenial.denied }
    }
    #expect(try await store.loadSnapshots() == [snapshot])
    #expect(try await !store.admissionIsActive(for: request.identifier))
    _ = try await transfer.retry(request)
    #expect(await probe.enqueuedRequests == [request])
}

@Test func inactiveExecutionCancellationDuringQueryNeverCallsBody() async throws {
    let request = try appleUploadRequest(identifier: "renewal.cancelled-query")
    let store = RadrootsInMemoryBackgroundTransferStore()
    let called = RadrootsCompletionProbe()
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: RadrootsAppleBackgroundTransferAdapters(
        enqueue: { _, _ in Issue.record("Unexpected enqueue") }, cancel: { _ in Issue.record("Unexpected cancel") },
        activeTransferIdentifiers: {
            try await RadrootsBackgroundTaskQuery.read { _ in signal.yield(); signal.finish() }
        }, handleBackgroundEvents: { _, completion in completion() }
    ))
    let task = Task { try await transfer.withInactiveExecution(for: request.identifier) { _ in called.markCompleted() } }
    for await _ in entered {
        break
    }
    task.cancel()
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) { try await task.value }
    #expect(!called.completed)
    #expect(try await !store.admissionIsActive(for: request.identifier))
    #expect(try await store.loadSnapshots().isEmpty)
}

private enum RenewalTestDenial: Error, Equatable { case denied }
