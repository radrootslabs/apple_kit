import Foundation
import Testing
import RadrootsKit
import RadrootsKitTesting

@Test func inMemoryBackgroundTransferStorePersistsSnapshotsInIdentifierOrder() async throws {
    let first = try RadrootsBackgroundTransferSnapshot(
        request: testTransferRequest(identifier: "field.transfer.b")
    )
    let second = try RadrootsBackgroundTransferSnapshot(
        request: testTransferRequest(identifier: "field.transfer.a")
    )
    let store = RadrootsInMemoryBackgroundTransferStore()

    try await store.saveSnapshot(first)
    try await store.saveSnapshot(second)

    #expect(try await store.loadSnapshots().map(\.identifier.rawValue) == [
        "field.transfer.a",
        "field.transfer.b"
    ])

    try await store.removeSnapshot(for: second.identifier)
    #expect(try await store.loadSnapshots() == [first])

    try await store.removeAllSnapshots()
    #expect(try await store.loadSnapshots().isEmpty)
}

@Test func fakeBackgroundTransferEnqueuesSnapshotsAndHandlesCancellation() async throws {
    let transfer = RadrootsFakeBackgroundTransfer(
        updatedAt: Date(timeIntervalSince1970: 42)
    )
    let request = try testTransferRequest(identifier: "field.transfer.enqueue")

    let handle = try await transfer.enqueue(request)

    #expect(handle.identifier == request.identifier)
    #expect(await transfer.enqueuedRequests == [request])
    #expect(try await transfer.snapshot(for: request.identifier)?.state == .queued)
    #expect(try await transfer.snapshot(for: request.identifier)?.updatedAt == Date(timeIntervalSince1970: 42))

    try await transfer.cancel(request.identifier)

    #expect(await transfer.cancelledIdentifiers == [request.identifier])
    #expect(try await transfer.snapshot(for: request.identifier)?.state == .cancelled)
}

@Test func fakeBackgroundTransferCanCompleteAndFailSnapshots() async throws {
    let transfer = RadrootsFakeBackgroundTransfer()
    let completed = try testTransferRequest(identifier: "field.transfer.completed")
    let failed = try testTransferRequest(identifier: "field.transfer.failed")

    _ = try await transfer.enqueue(completed)
    _ = try await transfer.enqueue(failed)
    try await transfer.complete(completed.identifier)
    try await transfer.fail(failed.identifier, message: "network unavailable")

    #expect(try await transfer.snapshot(for: completed.identifier)?.state == .completed)
    let failedSnapshot = try await transfer.snapshot(for: failed.identifier)
    #expect(failedSnapshot?.state == .failed)
    #expect(failedSnapshot?.errorMessage == "network unavailable")
}

@Test func fakeBackgroundTransferCanReturnEnqueueFailures() async throws {
    let transfer = RadrootsFakeBackgroundTransfer(
        enqueueOutcome: .failure(.transferFailure("queue unavailable"))
    )
    let request = try testTransferRequest(identifier: "field.transfer.failure")

    await #expect(throws: RadrootsBackgroundTransferError.transferFailure("queue unavailable")) {
        _ = try await transfer.enqueue(request)
    }
    #expect(await transfer.enqueuedRequests == [request])
    #expect(try await transfer.snapshots().isEmpty)
}

private func testTransferRequest(identifier: String) throws -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier),
        remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .get,
        operation: .download(
            destination: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))
        )
    )
}
