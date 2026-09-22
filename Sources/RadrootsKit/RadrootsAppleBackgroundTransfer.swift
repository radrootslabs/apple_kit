import Foundation

public actor RadrootsAppleBackgroundTransfer: RadrootsBackgroundTransfer {
    private let store: any RadrootsBackgroundTransferStore
    private let adapters: RadrootsAppleBackgroundTransferAdapters
    private var admissions: Set<RadrootsBackgroundTransferIdentifier> = []
    private var stoppedAdmissions: [RadrootsBackgroundTransferIdentifier: RadrootsBackgroundTransferState] = [:]
    private struct InactiveExecutionBodyError: Error {
        let underlying: any Error
    }

    public init(store: any RadrootsBackgroundTransferStore, adapters: RadrootsAppleBackgroundTransferAdapters) {
        self.store = store
        self.adapters = adapters
    }

    public init(roots: RadrootsAppleFileRoots, sessionIdentifier: String) throws {
        let store = RadrootsAppleBackgroundTransferStore(roots: roots)
        let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
        let name = try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier)
        let downloadRoot = try roots.resolvedURL(for: RadrootsFileReference(
            scope: .temporary, relativePath: "background_transfers/\(name)/downloads"
        ), allowRootDirectory: true)
        self.store = store
        adapters = try .live(sessionIdentifier: name, store: store, fileResolver: resolver,
                             downloadStagingRoot: downloadRoot)
    }

    public func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws -> RadrootsBackgroundTransferHandle {
        try reserve(request.identifier)
        defer { release(request.identifier) }
        return try await admission(request, retry: false)
    }

    public func retry(_ request: RadrootsBackgroundTransferRequest) async throws -> RadrootsBackgroundTransferHandle {
        try reserve(request.identifier)
        defer { release(request.identifier) }
        return try await admission(request, retry: true)
    }

    public func withInactiveExecution<Result: Sendable>(
        for identifier: RadrootsBackgroundTransferIdentifier,
        operation: @escaping @Sendable (RadrootsBackgroundTransferSnapshot?) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        try reserve(identifier)
        defer { release(identifier) }
        do {
            return try await store.withAdmission(for: identifier) {
                let snapshot = try await self.inactiveSnapshot(identifier)
                try Task.checkCancellation()
                do { return try await operation(snapshot) }
                catch { throw InactiveExecutionBodyError(underlying: error) }
            }
        } catch let error as InactiveExecutionBodyError {
            throw error.underlying
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistence(error)
        }
    }

    private func inactiveSnapshot(
        _ identifier: RadrootsBackgroundTransferIdentifier
    ) async throws -> RadrootsBackgroundTransferSnapshot? {
        guard try await !activeIdentifiers().contains(identifier), stoppedAdmissions[identifier] == nil else {
            throw RadrootsBackgroundTransferError.transferFailure
        }
        let snapshot = try await load(identifier)
        if let snapshot {
            guard [.failed, .interrupted, .cancelled, .expired].contains(snapshot.state),
                  snapshot.response == nil, snapshot.downloadedArtifact == nil
            else { throw RadrootsBackgroundTransferError.transferFailure }
        }
        // Do not rewrite state, drop a receipt or cancel an OS task. Completion
        // callbacks may still persist late evidence while admission is held.
        return snapshot
    }

    private func admission(
        _ request: RadrootsBackgroundTransferRequest, retry: Bool
    ) async throws -> RadrootsBackgroundTransferHandle {
        do {
            return try await store.withAdmission(for: request.identifier) {
                try await self.admitReserved(request, retry: retry)
            }
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistence(error)
        }
    }

    private func admitReserved(
        _ request: RadrootsBackgroundTransferRequest, retry: Bool
    ) async throws -> RadrootsBackgroundTransferHandle {
        let existing = try await load(request.identifier)
        if retry {
            guard let existing, [.failed, .interrupted, .cancelled, .expired].contains(existing.state),
                  try existing.request.redactedForPersistence() == request.redactedForPersistence()
            else { throw RadrootsBackgroundTransferError.invalidRequest }
        } else if existing != nil {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        guard try await !activeIdentifiers().contains(request.identifier) else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        return try await schedule(request, replacing: existing)
    }

    private func reserve(_ identifier: RadrootsBackgroundTransferIdentifier) throws {
        guard admissions.count < 256, admissions.insert(identifier).inserted else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
    }

    private func release(_ identifier: RadrootsBackgroundTransferIdentifier) {
        admissions.remove(identifier)
        stoppedAdmissions.removeValue(forKey: identifier)
    }

    private func schedule(
        _ request: RadrootsBackgroundTransferRequest, replacing existing: RadrootsBackgroundTransferSnapshot?
    ) async throws -> RadrootsBackgroundTransferHandle {
        guard !Task.isCancelled, stoppedAdmissions[request.identifier] == nil else {
            throw RadrootsBackgroundTransferError.transferFailure
        }
        let queued = try RadrootsBackgroundTransferSnapshot(
            request: request.redactedForPersistence(), updatedAt: adapters.now(), executionID: UUID()
        )
        guard try await exchange(existing, queued) else { throw RadrootsBackgroundTransferError.invalidRequest }
        if Task.isCancelled {
            stoppedAdmissions[request.identifier] = .cancelled
        }
        if let state = stoppedAdmissions[request.identifier] {
            _ = try await exchange(queued, queued.transitioned(to: state, at: adapters.now(),
                                                               failure: state == .expired ? .expired : nil,
                                                               possibleRemoteOrphan: request.isUpload))
            throw RadrootsBackgroundTransferError.transferFailure
        }
        do {
            guard let executionID = queued.executionID else { throw RadrootsBackgroundTransferError.invalidRequest }
            try await adapters.enqueue(request, executionID)
        } catch {
            let persistenceFailure = RadrootsBackgroundTransferError.persistence(error)
            if stoppedAdmissions[request.identifier] != nil {
                try? await adapters.cancel(request.identifier)
            }
            if let current = try await load(request.identifier), current.executionID == queued.executionID,
               current.state == .queued || current.state == .running
            {
                _ = try await exchange(current, current.transitioned(to: .failed, at: adapters.now(),
                                                                     failure: .enqueueFailed,
                                                                     possibleRemoteOrphan: request.isUpload))
            }
            if persistenceFailure == .spaceInsufficient || persistenceFailure == .receiptCapacityExceeded {
                throw persistenceFailure
            }
            throw RadrootsBackgroundTransferError.transferFailure
        }
        if stoppedAdmissions[request.identifier] != nil || Task.isCancelled {
            try await stop(request.identifier, state: stoppedAdmissions[request.identifier] ?? .cancelled)
        } else if let current = try await load(request.identifier), current.executionID == queued.executionID,
                  current.state == .queued
        {
            _ = try await exchange(current, current.transitioned(to: .running, at: adapters.now()))
        }
        return RadrootsBackgroundTransferHandle(request: request)
    }

    public func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
        try await stop(identifier, state: .cancelled)
    }

    public func expire(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
        try await stop(identifier, state: .expired)
    }

    private func stop(
        _ identifier: RadrootsBackgroundTransferIdentifier,
        state: RadrootsBackgroundTransferState
    ) async throws {
        if admissions.contains(identifier) {
            stoppedAdmissions[identifier] = state
        }
        if let existing = try await load(identifier) {
            guard [.queued, .running, .interrupted].contains(existing.state) else {
                if admissions.contains(identifier), [.cancelled, .expired].contains(existing.state) {
                    do {
                        try await adapters.cancel(identifier)
                    } catch {
                        throw RadrootsBackgroundTransferError.transferFailure
                    }
                }
                return
            }
            let desired = try existing.transitioned(to: state, at: adapters.now(),
                                                    failure: state == .expired ? .expired : nil,
                                                    possibleRemoteOrphan: existing.request.isUpload)
            guard try await exchange(existing, desired) else {
                throw RadrootsBackgroundTransferError.transferFailure
            }
        }
        do {
            try await adapters.cancel(identifier)
        } catch {
            throw RadrootsBackgroundTransferError.transferFailure
        }
    }

    public func settle(
        _ identifier: RadrootsBackgroundTransferIdentifier, verification: RadrootsBackgroundTransferVerification
    ) async throws {
        guard let existing = try await load(identifier), existing.state == .awaitingVerification else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        let desired: RadrootsBackgroundTransferSnapshot = switch verification {
        case .accepted:
            try existing.transitioned(to: .completed, at: adapters.now())
        case let .rejected(failure):
            try existing.transitioned(to: .failed, at: adapters.now(), failure: failure,
                                      possibleRemoteOrphan: existing.request.isUpload)
        }
        guard try await exchange(existing, desired) else { throw RadrootsBackgroundTransferError.transferFailure }
    }

    public func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
        -> RadrootsBackgroundTransferSnapshot?
    {
        try await snapshots().first { $0.identifier == identifier }
    }

    public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        let active = try await activeIdentifiers()
        let stored = try await loadAll()
        let identifiers = Set(stored.map(\.identifier))
        for orphan in active.subtracting(identifiers) where !admissions.contains(orphan) {
            guard try await !admissionIsActive(orphan) else { continue }
            do {
                try await adapters.cancel(orphan)
            } catch {
                throw RadrootsBackgroundTransferError.transferFailure
            }
        }
        for existing in stored where !admissions.contains(existing.identifier) {
            guard try await !admissionIsActive(existing.identifier) else { continue }
            let desired: RadrootsBackgroundTransferSnapshot
            if active.contains(existing.identifier), [.queued, .interrupted].contains(existing.state) {
                desired = try existing.transitioned(to: .running, at: adapters.now(), failure: existing.failure)
            } else if !active.contains(existing.identifier), [.queued, .running].contains(existing.state) {
                desired = try existing.transitioned(to: .interrupted, at: adapters.now(), failure: .interrupted,
                                                    possibleRemoteOrphan: existing.request.isUpload)
            } else {
                continue
            }
            _ = try await exchange(existing, desired)
        }
        return try await loadAll()
    }

    public func handleEventsForBackgroundURLSession(
        identifier: String, completionHandler: @escaping @Sendable () -> Void
    ) async {
        await adapters.handleBackgroundEvents(identifier, completionHandler)
    }

    private func load(_ identifier: RadrootsBackgroundTransferIdentifier) async throws
        -> RadrootsBackgroundTransferSnapshot?
    {
        try await loadAll().first { $0.identifier == identifier }
    }

    private func loadAll() async throws -> [RadrootsBackgroundTransferSnapshot] {
        do {
            return try await store.loadSnapshots()
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistence(error)
        }
    }

    private func exchange(
        _ expected: RadrootsBackgroundTransferSnapshot?, _ desired: RadrootsBackgroundTransferSnapshot
    ) async throws -> Bool {
        do {
            return try await store.compareExchangeSnapshot(expected: expected, desired: desired)
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistence(error)
        }
    }

    private func activeIdentifiers() async throws -> Set<RadrootsBackgroundTransferIdentifier> {
        do {
            return try await adapters.activeTransferIdentifiers()
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.transferFailure
        }
    }

    private func admissionIsActive(_ identifier: RadrootsBackgroundTransferIdentifier) async throws -> Bool {
        do {
            return try await store.admissionIsActive(for: identifier)
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistence(error)
        }
    }
}
