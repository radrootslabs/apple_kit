import Darwin
import Foundation
@testable import RadrootsKit
import Testing

@Test func nativeAdmissionCleanupRetriesOnlyBoundedCreationAbsence() throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    var attempts = 0
    let path = f.path("creation")
    let descriptor = try #require(try RadrootsAtomicFile.acquireExclusiveLock(at: path, injectedOpenError: { attempt in
        attempts += 1
        return attempt < 2 ? ENOENT : nil
    }))
    #expect(attempts == 3)
    #expect(try RadrootsAtomicFile.acquireExclusiveLock(at: path) == nil)
    Darwin.close(descriptor)
    attempts = 0
    #expect(throws: RadrootsAppleFileError.transientFailure) {
        _ = try RadrootsAtomicFile.acquireExclusiveLock(at: f.path("exhausted"), injectedOpenError: { _ in
            attempts += 1; return ENOENT
        })
    }
    #expect(attempts == 4 && !FileManager.default.fileExists(atPath: f.path("exhausted").path))
    attempts = 0
    #expect(throws: RadrootsAppleFileError.permanentFailure) {
        _ = try RadrootsAtomicFile.acquireExclusiveLock(at: f.path("denied"), injectedOpenError: { _ in
            attempts += 1; return EACCES
        })
    }
    #expect(attempts == 1)
    #expect(try RadrootsAtomicFile.acquireExclusiveLock(at: f.path("missing"), create: false) == nil)
    #expect(!FileManager.default.fileExists(atPath: f.path("missing").path))
}

@Test func nativeAdmissionCleanupCreationRetryRejectsChangedParent() throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    var attempts = 0
    #expect(throws: RadrootsAppleFileError.permanentFailure) {
        _ = try RadrootsAtomicFile.acquireExclusiveLock(at: f.path("changed"), injectedOpenError: { _ in
            attempts += 1
            try FileManager.default.moveItem(at: f.directory, to: f.base.appendingPathComponent("moved"))
            try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
            return ENOENT
        })
    }
    #expect(attempts == 1)
    #expect(!FileManager.default.fileExists(atPath: f.path("changed").path))
}

@Test func nativeAdmissionCleanupConcurrentOwnersNeverSplitOneReservation() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let request = try f.request("contended")
    let probe = AdmissionCleanupProbe()
    let collector = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0 ..< 8 {
            group.addTask {
                let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
                for _ in 0 ..< 20 {
                    do {
                        _ = try await store.withAdmission(for: request.identifier) {
                            await probe.enter()
                            await Task.yield()
                            await probe.leave()
                            return RadrootsBackgroundTransferHandle(request: request)
                        }
                    } catch RadrootsBackgroundTransferError.invalidRequest {
                        // Another owner has this exact reservation.
                    } catch RadrootsBackgroundTransferError.unavailable {
                        // Bounded coordination contention remains transient.
                    }
                }
            }
        }
        group.addTask {
            for _ in 0 ..< 40 {
                do { _ = try await collector.collectInactiveAdmissions(limit: 7) }
                catch RadrootsBackgroundTransferError.unavailable {}
                await Task.yield()
            }
        }
        try await group.waitForAll()
    }
    #expect(await probe.maximum == 1)
    #expect(await probe.active == 0)
    #expect(await probe.completed > 0)
    #expect(try await !collector.admissionIsActive(for: request.identifier))
}

@Test func nativeAdmissionCleanupPreservesNativeReceiptAndUploadLease() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    let request = try f.request("unverified")
    let receipt = try RadrootsBackgroundTransferSnapshot(request: request, state: .awaitingVerification,
                                                         response: RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: "application/json", body: Data("{}".utf8)),
                                                         executionID: UUID())
    try await store.saveSnapshot(receipt)
    let bytes = Data("OS-consumed immutable upload bytes".utf8)
    let lease = try RadrootsAppleFileAccess(roots: f.roots).leaseUploadBytes(bytes, identifier: UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    try Data().write(to: f.path(request.identifier.rawValue))
    #expect(try await store.collectInactiveAdmissions().removedFiles == 1)
    #expect(try await store.loadSnapshots() == [receipt])
    #expect(try Data(contentsOf: lease.fileURL) == bytes)
}

@Test func nativeAdmissionCleanupRetainsHeldReservationAndAllowsIndependentIDs() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let first = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    let second = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    let request = try f.request("held")
    let gate = AdmissionCleanupGate()
    let pending = Task {
        try await first.withAdmission(for: request.identifier) {
            await gate.hold()
            return RadrootsBackgroundTransferHandle(request: request)
        }
    }
    await gate.waitUntilEntered()
    let path = f.path(request.identifier.rawValue)
    #expect(FileManager.default.fileExists(atPath: path.path))
    #expect(try await second.collectInactiveAdmissions().removedFiles == 0)
    #expect(try await second.admissionIsActive(for: request.identifier))
    await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
        _ = try await second.withAdmission(for: request.identifier) { RadrootsBackgroundTransferHandle(request: request) }
    }
    let other = try f.request("independent")
    _ = try await second.withAdmission(for: other.identifier) { RadrootsBackgroundTransferHandle(request: other) }
    #expect(!FileManager.default.fileExists(atPath: f.path(other.identifier.rawValue).path))
    #expect(FileManager.default.fileExists(atPath: path.path))
    await gate.release()
    #expect(try await pending.value.identifier == request.identifier)
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func nativeAdmissionCleanupContinuesBeyondOneThousandEntriesAndRetainsUnknowns() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    for index in 0 ..< 1001 {
        try Data().write(to: f.path("orphan-\(index)"))
    }
    let nonempty = f.path("nonempty")
    let outside = f.base.appendingPathComponent("outside")
    try Data("protected".utf8).write(to: nonempty)
    try Data("external".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: f.path("symlink"), withDestinationURL: outside)
    try FileManager.default.createDirectory(at: f.path("directory"), withIntermediateDirectories: false)
    let unknown = f.directory.appendingPathComponent("unknown.lock")
    try Data().write(to: unknown)
    let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    var removed = 0
    var calls = 0
    while true {
        let result = try await store.collectInactiveAdmissions(limit: 37)
        #expect(result.scannedEntries <= 37 && result.removedFiles <= result.scannedEntries)
        removed += result.removedFiles
        calls += 1
        if result.reachedEnd {
            break
        }
        try #require(calls < 100)
    }
    #expect(calls > 27 && removed == 1001)
    #expect(try Data(contentsOf: nonempty) == Data("protected".utf8))
    #expect(try Data(contentsOf: outside) == Data("external".utf8))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    #expect(try await store.collectInactiveAdmissions().removedFiles == 0)
}

@Test func nativeAdmissionCleanupRetainsInterruptedRetirementThenRecovers() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    let request = try f.request("interrupted")
    let gate = AdmissionCleanupGate()
    let pending = Task {
        try await store.withAdmission(for: request.identifier) {
            await gate.hold()
            return RadrootsBackgroundTransferHandle(request: request)
        }
    }
    await gate.waitUntilEntered()
    let coordination = try #require(try RadrootsAtomicFile.acquireExclusiveLock(at: f.coordination))
    await gate.release()
    #expect(try await pending.value.identifier == request.identifier)
    #expect(FileManager.default.fileExists(atPath: f.path(request.identifier.rawValue).path))
    Darwin.close(coordination)
    #expect(try await store.collectInactiveAdmissions().removedFiles == 1)
    #expect(try await store.collectInactiveAdmissions().removedFiles == 0)
}

@Test func nativeAdmissionCleanupCancellationAndOperationErrorRetireOnlyTheirReservation() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    let request = try f.request("cancelled")
    let gate = AdmissionCleanupGate()
    let pending = Task {
        try await store.withAdmission(for: request.identifier) {
            await gate.hold()
            try Task.checkCancellation()
            return RadrootsBackgroundTransferHandle(request: request)
        }
    }
    await gate.waitUntilEntered()
    pending.cancel()
    #expect(FileManager.default.fileExists(atPath: f.path(request.identifier.rawValue).path))
    await gate.release()
    await #expect(throws: CancellationError.self) { _ = try await pending.value }
    #expect(!FileManager.default.fileExists(atPath: f.path(request.identifier.rawValue).path))
    await #expect(throws: RadrootsBackgroundTransferError.transferFailure) {
        _ = try await store.withAdmission(for: request.identifier) { throw RadrootsBackgroundTransferError.transferFailure }
    }
    #expect(!FileManager.default.fileExists(atPath: f.path(request.identifier.rawValue).path))
}

@Test func nativeAdmissionCleanupBoundsAndCoordinationContentionFailBeforeWork() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    for limit in [0, -1, 65, Int.max] {
        await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
            _ = try await store.collectInactiveAdmissions(limit: limit)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: f.directory.path))
    let coordination = try #require(try RadrootsAtomicFile.acquireExclusiveLock(at: f.coordination))
    defer { Darwin.close(coordination) }
    await #expect(throws: RadrootsBackgroundTransferError.unavailable) {
        _ = try await store.collectInactiveAdmissions()
    }
}

@Test func nativeAdmissionCleanupRejectsReplacedDirectoryAndResumesFreshPass() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    #expect(try await !store.collectInactiveAdmissions(limit: 1).reachedEnd)
    try FileManager.default.moveItem(at: f.directory, to: f.base.appendingPathComponent("retired"))
    try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
    let replacement = f.path("replacement")
    try Data().write(to: replacement)
    await #expect(throws: RadrootsBackgroundTransferError.persistenceFailure) {
        _ = try await store.collectInactiveAdmissions()
    }
    #expect(FileManager.default.fileExists(atPath: replacement.path))
    #expect(try await store.collectInactiveAdmissions().removedFiles == 1)
}

@Test func nativeAdmissionCleanupDoesNotUnlinkReplacedLeafOrFollowRootSymlink() async throws {
    let f = try AdmissionCleanupFixture()
    defer { f.remove() }
    let path = f.path("replaced")
    let descriptor = try #require(try RadrootsAtomicFile.acquireExclusiveLock(at: path))
    defer { Darwin.close(descriptor) }
    try FileManager.default.moveItem(at: path, to: f.base.appendingPathComponent("held-inode"))
    try Data().write(to: path)
    #expect(try !RadrootsAtomicFile.removeEmptyLockedFile(at: path, descriptor: descriptor))
    #expect(FileManager.default.fileExists(atPath: path.path))
    try FileManager.default.moveItem(at: f.directory, to: f.base.appendingPathComponent("original"))
    try FileManager.default.createSymbolicLink(at: f.directory, withDestinationURL: f.base.appendingPathComponent("original"))
    let store = RadrootsAppleBackgroundTransferStore(roots: f.roots)
    await #expect(throws: RadrootsBackgroundTransferError.persistenceFailure) { _ = try await store.collectInactiveAdmissions() }
    #expect(FileManager.default.fileExists(atPath: path.path))
}

private actor AdmissionCleanupProbe {
    var active = 0
    var maximum = 0
    var completed = 0
    func enter() {
        active += 1; maximum = max(maximum, active)
    }

    func leave() {
        active -= 1; completed += 1
    }
}

private actor AdmissionCleanupGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if !entered {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        continuation?.resume(); continuation = nil
    }
}

private struct AdmissionCleanupFixture: Sendable {
    let base: URL
    let roots: RadrootsAppleFileRoots
    var directory: URL {
        roots.dataRoot.appendingPathComponent("background_transfers/admissions", isDirectory: true)
    }

    var coordination: URL {
        directory.appendingPathComponent(".coordination.lock")
    }

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("admission-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let pointer = try #require(raw.path.withCString { Darwin.realpath($0, nil) })
        defer { Darwin.free(pointer) }
        base = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        roots = try RadrootsAppleFileRoots(appIdentifier: "org.radroots.tests", dataRoot: base.appendingPathComponent("data"),
                                           cacheRoot: base.appendingPathComponent("cache"), temporaryRoot: base.appendingPathComponent("tmp"))
    }

    func path(_ identifier: String) -> URL {
        directory.appendingPathComponent(RadrootsAppleFileDigest.sha256(Data(identifier.utf8)) + ".lock")
    }

    func request(_ id: String) throws -> RadrootsBackgroundTransferRequest {
        try RadrootsBackgroundTransferRequest(identifier: RadrootsBackgroundTransferIdentifier(id),
                                              remoteURL: #require(URL(string: "https://example.org/upload")), method: .put,
                                              operation: .upload(source: .file(RadrootsFileReference(scope: .cache, relativePath: "body"))),
                                              responsePolicy: .boundedJSON())
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
