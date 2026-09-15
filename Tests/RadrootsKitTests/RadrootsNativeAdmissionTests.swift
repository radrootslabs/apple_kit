import Darwin
import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func nativeAdmissionReservesBeforeAwaitAndPreservesQueuedOwnership() async throws {
    let fixture = try NativeAdmissionFixture()
    defer { fixture.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let gate = NativeAdmissionGate()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: gate.adapters())
    let request = try nativeAdmissionRequest()
    let first = Task { try await transfer.enqueue(request) }
    await gate.waitUntilEntered()
    await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
        _ = try await transfer.enqueue(request)
    }
    let conflicting = try nativeAdmissionRequest(remote: "https://example.org/other")
    await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
        _ = try await transfer.enqueue(conflicting)
    }
    let secondStore = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let secondOwner = RadrootsAppleBackgroundTransfer(store: secondStore, adapters: gate.adapters())
    #expect(try await secondOwner.snapshots().first?.state == .queued)
    await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
        _ = try await secondOwner.enqueue(request)
    }
    let queued = try #require(try await transfer.snapshots().first)
    #expect(queued.state == .queued)
    #expect(queued.request.headers.isEmpty && queued.request.metadata.isEmpty)
    #expect(queued.executionID != nil)
    await gate.finish()
    #expect(try await first.value.identifier == request.identifier)
    #expect(await gate.admittedCount == 1)
    #expect(try await !secondStore.admissionIsActive(for: request.identifier))
    #expect(try await transfer.snapshot(for: request.identifier)?.state == .running)
}

@Test func nativeAdmissionDifferentIdentifiersCanProceedWhileAnotherAwaitIsHeld() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let firstGate = NativeAdmissionGate()
    let secondGate = NativeAdmissionGate()
    let first = RadrootsAppleBackgroundTransfer(store: store, adapters: firstGate.adapters())
    let second = RadrootsAppleBackgroundTransfer(store: store, adapters: secondGate.adapters())
    let original = try nativeAdmissionRequest()
    let other = try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier("native.admission.other"),
        remoteURL: original.remoteURL, method: original.method, operation: original.operation
    )
    let firstTask = Task { try await first.enqueue(original) }
    await firstGate.waitUntilEntered()
    let secondTask = Task { try await second.enqueue(other) }
    await secondGate.waitUntilEntered()
    #expect(try await store.loadSnapshots().count == 2)
    await secondGate.finish()
    #expect(try await secondTask.value.identifier == other.identifier)
    await firstGate.finish()
    #expect(try await firstTask.value.identifier == original.identifier)
    #expect(await firstGate.admittedCount == 1)
    #expect(await secondGate.admittedCount == 1)
}

@Test func nativeAdmissionCancellationWhileEnqueueSuspendsCancelsLateTask() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let gate = NativeAdmissionGate()
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: gate.adapters())
    let request = try nativeAdmissionRequest()
    let pending = Task { try await transfer.enqueue(request) }
    await gate.waitUntilEntered()
    try await transfer.cancel(request.identifier)
    await gate.finish()
    _ = try await pending.value
    #expect(await gate.active.isEmpty)
    let snapshot = try #require(try await store.loadSnapshots().first)
    #expect(snapshot.state == .cancelled && snapshot.possibleRemoteOrphan)
}

@Test func nativeAdmissionErrorAfterEffectPreservesUnknownOutcomeAndExistingReceipt() async throws {
    let store = RadrootsInMemoryBackgroundTransferStore()
    let request = try nativeAdmissionRequest()
    let adapters = RadrootsAppleBackgroundTransferAdapters(
        enqueue: { _, executionID in
            let existing = try #require(try await store.loadSnapshots().first)
            #expect(existing.executionID == executionID)
            let completed = try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .awaitingVerification,
                response: RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: nil, body: nil),
                executionID: executionID
            )
            #expect(try await store.compareExchangeSnapshot(expected: existing, desired: completed))
            throw RadrootsBackgroundTransferError.transferFailure
        }, cancel: { _ in }, activeTransferIdentifiers: { [] },
        handleBackgroundEvents: { _, completion in completion() }
    )
    let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: adapters)
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) { _ = try await transfer.enqueue(request) }
    #expect(try await store.loadSnapshots().first?.state == .awaitingVerification)
    let lost = try RadrootsBackgroundTransferSnapshot(request: request, state: .queued, executionID: UUID())
    let recoveredStore = RadrootsInMemoryBackgroundTransferStore(snapshots: [lost])
    let recovered = RadrootsAppleBackgroundTransfer(store: recoveredStore, adapters: adapters)
    let interrupted = try #require(try await recovered.snapshots().first)
    #expect(interrupted.state == .interrupted && interrupted.possibleRemoteOrphan)
}

@Test func nativeAdmissionStaleAndDuplicateCallbacksCannotOverwriteNewAttempt() async throws {
    let fixture = try NativeAdmissionFixture()
    defer { fixture.remove() }
    let request = try nativeAdmissionRequest()
    let generation = UUID()
    let running = try RadrootsBackgroundTransferSnapshot(request: request, state: .running, executionID: generation)
    let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [running])
    let coordinator = RadrootsTransferCoordinator(
        sessionIdentifier: "tests", store: store,
        fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: fixture.roots)
    )
    let response = RadrootsBackgroundHTTPResult(statusCode: 200, mediaType: nil, body: nil, bodyExceeded: false)
    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(platformError: nil, stagedDownloadResult: nil, httpResult: response,
                                               bytesTransferred: 3, totalBytesExpected: 3),
        executionID: UUID()
    )
    #expect(try await store.loadSnapshots().first == running)
    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(platformError: nil, stagedDownloadResult: nil, httpResult: response,
                                               bytesTransferred: 3, totalBytesExpected: 3),
        executionID: generation
    )
    let completed = try #require(try await store.loadSnapshots().first)
    #expect(completed.state == .awaitingVerification && completed.executionID == generation)
    await coordinator.updateProgress(identifier: request.identifier, bytesTransferred: 1, totalBytesExpected: 3,
                                     executionID: generation)
    await coordinator.complete(
        identifier: request.identifier,
        completion: RadrootsTransferCompletion(platformError: RadrootsBackgroundTransferError.transferFailure,
                                               stagedDownloadResult: nil, httpResult: response, bytesTransferred: 1,
                                               totalBytesExpected: 3),
        executionID: generation
    )
    #expect(try await store.loadSnapshots().first == completed)
}

@Test func nativeAdmissionPersistsExactLeaseAndGenerationAcrossRestart() async throws {
    let fixture = try NativeAdmissionFixture()
    defer { fixture.remove() }
    let file = RadrootsFileReference(scope: .cache, relativePath: "body")
    let bytes = Data("exact upload bytes".utf8)
    let fileOwner = RadrootsAppleFileAccess(roots: fixture.roots)
    try fileOwner.write(.inline(bytes), to: file)
    let request = try nativeAdmissionRequest(expectedSHA256: RadrootsAppleFileDigest.sha256(bytes))
    let generation = UUID()
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: fixture.roots)
    let lease = try resolver.prepareUploadLease(for: request, executionID: generation, existing: nil)
    let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let queued = try RadrootsBackgroundTransferSnapshot(
        request: request,
        executionID: generation,
        uploadLease: lease.blob
    )
    #expect(try await store.compareExchangeSnapshot(expected: nil, desired: queued))
    try fileOwner.reset(scope: .cache)
    let reopened = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let saved = try #require(try await reopened.loadSnapshots().first)
    #expect(saved.request.headers.isEmpty && saved.request.metadata.isEmpty)
    #expect(saved.executionID == generation && saved.uploadLease == lease.blob)
    let recovered = try resolver.prepareUploadLease(
        for: saved.request,
        executionID: generation,
        existing: saved.uploadLease
    )
    #expect(recovered == lease)
    #expect(try Data(contentsOf: recovered.fileURL) == bytes)
    let descriptor = RadrootsBackgroundURLTaskDescriptor(request: request, executionID: generation)
    #expect(RadrootsBackgroundURLTaskDescriptor(taskDescription: descriptor.taskDescription) == descriptor)
    #expect(RadrootsBackgroundURLTaskDescriptor(taskDescription: "radroots-transfer-v2|bad|0|0|invalid") == nil)
    try resolver.releaseUploadLease(executionID: generation)
    #expect(!FileManager.default.fileExists(atPath: lease.fileURL.path))
}

@Test func nativeAdmissionStoreClaimsOnceAndRejectsStaleTransition() async throws {
    let fixture = try NativeAdmissionFixture()
    defer { fixture.remove() }
    let request = try nativeAdmissionRequest()
    let results = await withTaskGroup(of: Bool.self) { group in
        for _ in 0 ..< 8 {
            group.addTask {
                let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
                let desired = try? RadrootsBackgroundTransferSnapshot(request: request, executionID: UUID())
                guard let desired else { return false }
                return await (try? store.compareExchangeSnapshot(expected: nil, desired: desired)) ?? false
            }
        }
        var results: [Bool] = []
        for await result in group {
            results.append(result)
        }
        return results
    }
    #expect(results.filter(\.self).count == 1)
    let store = RadrootsAppleBackgroundTransferStore(roots: fixture.roots)
    let original = try #require(try await store.loadSnapshots().first)
    let cancelled = try original.transitioned(to: .cancelled, at: Date(), possibleRemoteOrphan: true)
    #expect(try await store.compareExchangeSnapshot(expected: original, desired: cancelled))
    #expect(try await !store.compareExchangeSnapshot(expected: original,
                                                     desired: original.transitioned(to: .running, at: Date())))
    #expect(try await store.loadSnapshots().first == cancelled)
}

private actor NativeAdmissionGate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var active: Set<RadrootsBackgroundTransferIdentifier> = []
    private(set) var admittedCount = 0

    nonisolated func adapters() -> RadrootsAppleBackgroundTransferAdapters {
        RadrootsAppleBackgroundTransferAdapters(enqueue: { request, _ in await self.enqueue(request) },
                                                cancel: { identifier in await self.cancel(identifier) },
                                                activeTransferIdentifiers: { await self.active },
                                                handleBackgroundEvents: { _, completion in completion() })
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { observer = $0 }
    }

    func finish() {
        pending?.resume(); pending = nil
    }

    func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) {
        active.remove(identifier)
    }

    private func enqueue(_ request: RadrootsBackgroundTransferRequest) async {
        admittedCount += 1
        entered = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { pending = $0 }
        active.insert(request.identifier)
    }
}

private func nativeAdmissionRequest(
    remote: String = "https://example.org/upload", expectedSHA256: String? = nil
) throws -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(identifier: RadrootsBackgroundTransferIdentifier("native.admission"),
                                          remoteURL: #require(URL(string: remote)), method: .put,
                                          operation: .upload(source: .file(RadrootsFileReference(
                                              scope: .cache,
                                              relativePath: "body"
                                          ))),
                                          headers: ["Authorization": "test-only-authority"],
                                          metadata: ["label": "test-only-private-metadata"],
                                          expectedSourceSHA256: expectedSHA256)
}

private struct NativeAdmissionFixture {
    let base: URL
    let roots: RadrootsAppleFileRoots
    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("native-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let pointer = try #require(raw.path.withCString { Darwin.realpath($0, nil) })
        defer { Darwin.free(pointer) }
        base = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        roots = try RadrootsAppleFileRoots(
            appIdentifier: "org.radroots.tests",
            dataRoot: base.appendingPathComponent("data"),
            cacheRoot: base.appendingPathComponent("cache"),
            temporaryRoot: base.appendingPathComponent("tmp")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
