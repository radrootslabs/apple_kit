import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func backgroundTaskQueryReturnsFirstReplyAndIgnoresDuplicates() async throws {
    let value: Int = try await RadrootsBackgroundTaskQuery.read { reply in
        reply(7)
        reply(9)
    }
    #expect(value == 7)
}

@Test func backgroundTaskQueryLostCallbackTimesOutAndIgnoresLateReply() async {
    let probe = BackgroundTaskQueryProbe()
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) {
        let _: Int = try await RadrootsBackgroundTaskQuery.read(timeoutNanoseconds: 10_000_000) {
            probe.install($0)
        }
    }
    probe.reply(8)
    probe.reply(9)
}

@Test func backgroundTaskQueryCancellationReleasesWaitAndIgnoresLateReply() async {
    let probe = BackgroundTaskQueryProbe()
    let task = Task {
        try await RadrootsBackgroundTaskQuery.read { probe.install($0) }
    }
    var registered = probe.registered.makeAsyncIterator()
    _ = await registered.next()
    task.cancel()
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) { try await task.value }
    probe.reply(8)
    probe.reply(9)
}

@Test func backgroundTaskQueryAlreadyCancelledDoesNotStartQuery() async {
    let probe = BackgroundTaskQueryProbe()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let _: Int = try await RadrootsBackgroundTaskQuery.read { probe.install($0) }
    }
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) { try await task.value }
    #expect(!probe.wasInstalled)
}

@Test func backgroundTaskQueryRejectsInvalidBudgetsBeforeQuery() async {
    for budget: UInt64 in [0, 5_000_000_001, .max] {
        let probe = BackgroundTaskQueryProbe()
        await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
            let _: Int = try await RadrootsBackgroundTaskQuery.read(timeoutNanoseconds: budget) { probe.install($0) }
        }
        #expect(!probe.wasInstalled)
    }
}

@Test func backgroundTaskQueryReplyCancellationRaceIsSingleResolution() async throws {
    for _ in 0 ..< 100 {
        let probe = BackgroundTaskQueryProbe()
        let task = Task { try await RadrootsBackgroundTaskQuery.read { probe.install($0) } }
        var registered = probe.registered.makeAsyncIterator()
        _ = await registered.next()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { probe.reply(7) }
            group.addTask { task.cancel() }
            group.addTask { probe.reply(7) }
        }
        do { #expect(try await task.value == 7) } catch {
            #expect(error as? RadrootsBackgroundTransferError == .transferFailure)
        }
    }
}

@Test func backgroundTaskQueryValidatesEveryOwnedTaskBeforeInferringAbsence() throws {
    let request = try appleUploadRequest(identifier: "inventory.valid")
    let descriptor = RadrootsBackgroundURLTaskDescriptor(request: request, executionID: UUID())
    #expect(try RadrootsBackgroundTaskQuery.descriptors([descriptor.taskDescription]) == [descriptor])
    #expect(try RadrootsBackgroundTaskQuery.descriptors([request.identifier.rawValue]).first?.identifier
        == request.identifier)
    #expect(try RadrootsBackgroundTaskQuery.descriptors([]).isEmpty)
    #expect(try RadrootsBackgroundTaskQuery.descriptors(Array(repeating: descriptor.taskDescription, count: 4096))
        .count == 4096)
    for descriptions: [String?] in [
        [nil], ["radroots-transfer-v2|invalid"], [String(repeating: "a", count: 257)],
        [descriptor.taskDescription, nil], Array(repeating: descriptor.taskDescription, count: 4097),
    ] {
        #expect(throws: RadrootsBackgroundTransferError.transferFailure) {
            try RadrootsBackgroundTaskQuery.descriptors(descriptions)
        }
    }
}

@Test func backgroundTaskQueryUnknownInventoryPreservesReceiptsAndRefusesRetry() async throws {
    for state: RadrootsBackgroundTransferState in [.queued, .running, .interrupted, .expired] {
        let request = try appleUploadRequest(identifier: "inventory.unknown")
        let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: state, executionID: UUID())
        let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [snapshot])
        let probe = RadrootsAppleBackgroundTransferProbe()
        let original = probe.adapters()
        let adapters = RadrootsAppleBackgroundTransferAdapters(
            enqueue: original.enqueue, cancel: original.cancel,
            activeTransferIdentifiers: {
                try await RadrootsBackgroundTaskQuery.read(timeoutNanoseconds: 1_000_000) { _ in }
            }, handleBackgroundEvents: original.handleBackgroundEvents
        )
        let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: adapters)
        await #expect(throws: RadrootsBackgroundTransferError.transferFailure) { try await transfer.snapshots() }
        if state == .interrupted || state == .expired {
            await #expect(throws: RadrootsBackgroundTransferError.transferFailure) { try await transfer.retry(request) }
        }
        #expect(try await store.loadSnapshots() == [snapshot])
        #expect(await probe.enqueuedRequests.isEmpty)
        #expect(await probe.cancelledIdentifiers.isEmpty)
    }
}

/// All mutable callback state is synchronized; invoking the callback is outside
/// the lock so the query's own resolution/cancellation can run independently.
private final class BackgroundTaskQueryProbe: @unchecked Sendable {
    let registered: AsyncStream<Void>
    private let registration: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var callback: (@Sendable (Int) -> Void)?

    init() {
        (registered, registration) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var wasInstalled: Bool {
        lock.withLock { callback != nil }
    }

    func install(_ callback: @escaping @Sendable (Int) -> Void) {
        lock.withLock { self.callback = callback }
        registration.yield(())
        registration.finish()
    }

    func reply(_ value: Int) {
        let pending = lock.withLock { callback }
        pending?(value)
    }
}
