import Darwin
import Foundation

public actor RadrootsAppleBackgroundTransferStore: RadrootsBackgroundTransferStore {
    private static let maximumPersistenceBytes = 1024 * 1024

    private struct Envelope: Codable {
        let schemaVersion: Int
        let snapshots: [RadrootsBackgroundTransferSnapshot]

        init(snapshots: [RadrootsBackgroundTransferSnapshot]) {
            schemaVersion = 1
            self.snapshots = snapshots
        }
    }

    private let roots: RadrootsAppleFileRoots
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let protectedData: RadrootsProtectedDataProvider
    private var admissionScan: RadrootsAdmissionFileScan?

    private struct Admission {
        let descriptor: Int32
        let url: URL
    }

    public init(
        roots: RadrootsAppleFileRoots, fileManager: FileManager = .default,
        protectedData: RadrootsProtectedDataProvider = .available
    ) {
        self.roots = roots
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.protectedData = protectedData
        encoder.outputFormatting = [.sortedKeys]
    }

    public func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        try withStoreLock { try loadSnapshotsSynchronously() }
    }

    public func withAdmission<Result: Sendable>(
        for identifier: RadrootsBackgroundTransferIdentifier,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard let admission = try await acquireAdmission(identifier) else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        // Only this attempt owns the descriptor across awaits. Persistence uses a
        // separate short lock; neither reservation waits for another owner.
        defer { retireAdmission(admission) }
        return try await operation()
    }

    public func admissionIsActive(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> Bool {
        guard let admission = try await acquireAdmission(identifier) else { return true }
        retireAdmission(admission)
        return false
    }

    private func acquireAdmission(_ identifier: RadrootsBackgroundTransferIdentifier) async throws -> Admission? {
        try requireProtectedData()
        let coordination = try await acquireAdmissionCoordination()
        defer { Darwin.close(coordination) }
        do {
            let name = RadrootsAppleFileDigest.sha256(Data(identifier.rawValue.utf8))
            let url = try roots.resolvedURL(for: RadrootsFileReference(
                scope: .data, relativePath: "background_transfers/admissions/\(name).lock"
            ))
            guard let descriptor = try RadrootsAtomicFile.acquireExclusiveLock(at: url) else { return nil }
            return Admission(descriptor: descriptor, url: url)
        } catch RadrootsAppleFileError.transientFailure {
            throw RadrootsBackgroundTransferError.unavailable
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    private func admissionCoordinationURL() throws -> URL {
        try roots.resolvedURL(for: RadrootsFileReference(
            scope: .data, relativePath: "background_transfers/admissions/.coordination.lock"
        ))
    }

    private func acquireAdmissionCoordination() async throws -> Int32 {
        for _ in 0 ..< 16 {
            try Task.checkCancellation()
            try requireProtectedData()
            do {
                if let descriptor = try RadrootsAtomicFile.acquireExclusiveLock(at: admissionCoordinationURL()) {
                    return descriptor
                }
            } catch RadrootsAppleFileError.transientFailure {
                // The leaf was not created within its bounded retry budget.
            } catch { throw RadrootsBackgroundTransferError.persistenceFailure }
            await Task.yield()
        }
        throw RadrootsBackgroundTransferError.unavailable
    }

    private func retireAdmission(_ admission: Admission) {
        do {
            try requireProtectedData()
            guard let coordination = try RadrootsAtomicFile.acquireExclusiveLock(at: admissionCoordinationURL()) else {
                Darwin.close(admission.descriptor)
                return
            }
            // Close the retired inode before releasing the acquisition gate.
            defer { Darwin.close(admission.descriptor); Darwin.close(coordination) }
            _ = try? RadrootsAtomicFile.removeEmptyLockedFile(at: admission.url, descriptor: admission.descriptor)
        } catch {
            // Cleanup failure never rewrites the operation result. A later
            // explicit pass may reconcile the retained inactive inode.
            Darwin.close(admission.descriptor)
        }
    }

    /// Explicit metadata housekeeping. Each call visits at most 64 directory
    /// entries and continues this store's pass. A new pass starts after its end;
    /// restarting the owner starts over. Snapshots and upload leases are untouched.
    public func collectInactiveAdmissions(limit: Int = 64) async throws -> RadrootsAdmissionCleanupResult {
        guard (1 ... 64).contains(limit) else { throw RadrootsBackgroundTransferError.invalidRequest }
        let coordination = try await acquireAdmissionCoordination()
        defer { Darwin.close(coordination) }
        do {
            let directory = try admissionCoordinationURL().deletingLastPathComponent()
            if admissionScan == nil {
                admissionScan = try RadrootsAdmissionFileScan(url: directory)
            }
            guard let admissionScan else { throw RadrootsBackgroundTransferError.persistenceFailure }
            let batch = try admissionScan.next(limit: limit)
            var removed = 0
            for name in batch.names where Self.isAdmissionFilename(name) {
                if try admissionScan.removeInactive(name: name, coordination: coordination) {
                    removed += 1
                }
            }
            if batch.reachedEnd {
                self.admissionScan = nil
            }
            return RadrootsAdmissionCleanupResult(scannedEntries: batch.scanned, removedFiles: removed, reachedEnd: batch.reachedEnd)
        } catch {
            admissionScan = nil
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    private static func isAdmissionFilename(_ name: String) -> Bool {
        name.utf8.count == 69 && name.hasSuffix(".lock")
            && name.utf8.prefix(64).allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    public func compareExchangeSnapshot(
        expected: RadrootsBackgroundTransferSnapshot?, desired: RadrootsBackgroundTransferSnapshot
    ) async throws -> Bool {
        try withStoreLock {
            guard expected == nil || expected?.identifier == desired.identifier else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            var snapshots = try loadSnapshotsSynchronously()
            let current = snapshots.first { $0.identifier == desired.identifier }
            guard try current == (expected?.redactedForPersistence()) else { return false }
            snapshots.removeAll { $0.identifier == desired.identifier }
            try snapshots.append(desired.redactedForPersistence())
            try write(snapshots.sorted { $0.identifier < $1.identifier })
            return true
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try requireProtectedData()
        do {
            let lockURL = try roots.resolvedURL(
                for: RadrootsFileReference(scope: .data, relativePath: "background_transfers/transfers.lock")
            )
            return try RadrootsAtomicFile.withExclusiveLock(at: lockURL, body)
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    private func loadSnapshotsSynchronously() throws -> [RadrootsBackgroundTransferSnapshot] {
        try requireProtectedData()
        do {
            let url = try storeURL()
            let legacyURL = try legacyStoreURL()
            let isLegacy: Bool
            if fileManager.fileExists(atPath: url.path) {
                isLegacy = false
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                isLegacy = true
            } else {
                return []
            }
            let data = try RadrootsGovernedFileReader.read(
                root: roots.root(for: isLegacy ? .cache : .data),
                relativePath: "background_transfers/transfers.json",
                maximumBytes: Self.maximumPersistenceBytes
            )
            let decoded: [RadrootsBackgroundTransferSnapshot]
            let usedLegacyEncoding: Bool
            if let envelope = try? decoder.decode(Envelope.self, from: data) {
                guard envelope.schemaVersion == 1 else {
                    throw RadrootsBackgroundTransferError.persistenceFailure
                }
                decoded = envelope.snapshots
                usedLegacyEncoding = false
            } else {
                decoded = try decoder.decode([RadrootsBackgroundTransferSnapshot].self, from: data)
                usedLegacyEncoding = true
            }
            let snapshots = try decoded.map { try $0.redactedForPersistence() }.sorted { left, right in
                left.identifier < right.identifier
            }
            if isLegacy || usedLegacyEncoding {
                try write(snapshots)
            }
            if fileManager.fileExists(atPath: legacyURL.path) {
                try fileManager.removeItem(at: legacyURL)
            }
            return snapshots
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    public func saveSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws {
        try withStoreLock { try saveSnapshotSynchronously(snapshot) }
    }

    private func saveSnapshotSynchronously(_ snapshot: RadrootsBackgroundTransferSnapshot) throws {
        try requireProtectedData()
        do {
            var snapshots = try loadSnapshotsSynchronously()
            snapshots.removeAll { $0.identifier == snapshot.identifier }
            try snapshots.append(snapshot.redactedForPersistence())
            try write(snapshots.sorted { left, right in left.identifier < right.identifier })
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    public func removeSnapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws {
        try withStoreLock { try removeSnapshotSynchronously(for: identifier) }
    }

    private func removeSnapshotSynchronously(for identifier: RadrootsBackgroundTransferIdentifier) throws {
        try requireProtectedData()
        do {
            var snapshots = try loadSnapshotsSynchronously()
            snapshots.removeAll { $0.identifier == identifier }
            try write(snapshots)
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    public func removeAllSnapshots() async throws {
        try withStoreLock { try removeAllSnapshotsSynchronously() }
    }

    private func removeAllSnapshotsSynchronously() throws {
        try requireProtectedData()
        do {
            for url in try [storeURL(), legacyStoreURL()] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    private func write(_ snapshots: [RadrootsBackgroundTransferSnapshot]) throws {
        let url = try storeURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try encoder.encode(Envelope(snapshots: snapshots))
        guard data.count <= Self.maximumPersistenceBytes else {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
        try RadrootsAtomicFile.install(data, at: url)
        #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
    }

    private func storeURL() throws -> URL {
        try roots.resolvedURL(
            for: RadrootsFileReference(scope: .data, relativePath: "background_transfers/transfers.json")
        )
    }

    private func legacyStoreURL() throws -> URL {
        try roots.resolvedURL(
            for: RadrootsFileReference(scope: .cache, relativePath: "background_transfers/transfers.json")
        )
    }

    private func requireProtectedData() throws {
        guard protectedData.currentState() == .available else {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }
}
