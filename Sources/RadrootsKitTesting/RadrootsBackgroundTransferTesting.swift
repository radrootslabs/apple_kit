import Foundation
import RadrootsKit

public actor RadrootsInMemoryBackgroundTransferStore: RadrootsBackgroundTransferStore {
    private var snapshotsByIdentifier: [RadrootsBackgroundTransferIdentifier: RadrootsBackgroundTransferSnapshot]

  public init(snapshots: [RadrootsBackgroundTransferSnapshot] = []) {
    snapshotsByIdentifier = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identifier, $0) })
  }

  public func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
    snapshotsByIdentifier.values.sorted { left, right in
      left.identifier < right.identifier
    }
  }

  public func saveSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws {
    snapshotsByIdentifier[snapshot.identifier] = snapshot
  }

  public func removeSnapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws {
    snapshotsByIdentifier.removeValue(forKey: identifier)
  }

  public func removeAllSnapshots() async throws {
    snapshotsByIdentifier.removeAll()
  }
}

public actor RadrootsFakeBackgroundTransfer: RadrootsBackgroundTransfer {
  private let store: any RadrootsBackgroundTransferStore
  private var enqueueOutcome: Result<Void, RadrootsBackgroundTransferError>
  private var enqueuedRequestsValue: [RadrootsBackgroundTransferRequest]
  private var cancelledIdentifiersValue: [RadrootsBackgroundTransferIdentifier]
  private var handledBackgroundEventIdentifiersValue: [String]
  private let updatedAt: Date

  public init(
    store: any RadrootsBackgroundTransferStore = RadrootsInMemoryBackgroundTransferStore(),
    enqueueOutcome: Result<Void, RadrootsBackgroundTransferError> = .success(()),
    updatedAt: Date = Date(timeIntervalSince1970: 0)
  ) {
    self.store = store
    self.enqueueOutcome = enqueueOutcome
    enqueuedRequestsValue = []
    cancelledIdentifiersValue = []
    handledBackgroundEventIdentifiersValue = []
    self.updatedAt = updatedAt
  }

  public func setEnqueueOutcome(_ outcome: Result<Void, RadrootsBackgroundTransferError>) {
    enqueueOutcome = outcome
  }

  public func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws
    -> RadrootsBackgroundTransferHandle
  {
    enqueuedRequestsValue.append(request)
    switch enqueueOutcome {
    case .success:
      let snapshot = try RadrootsBackgroundTransferSnapshot(
        request: request,
        state: .queued,
        updatedAt: updatedAt
      )
      try await store.saveSnapshot(snapshot)
      return RadrootsBackgroundTransferHandle(request: request)
    case .failure(let error):
      throw error
    }
  }

  public func retry(_ request: RadrootsBackgroundTransferRequest) async throws
    -> RadrootsBackgroundTransferHandle
  {
    try await enqueue(request)
  }

  public func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
    cancelledIdentifiersValue.append(identifier)
        if let existing = try await store.loadSnapshots().first(where: { $0.identifier == identifier }) {
      let snapshot = try RadrootsBackgroundTransferSnapshot(
        request: existing.request,
        state: .cancelled,
        progress: existing.progress,
        updatedAt: updatedAt
      )
      try await store.saveSnapshot(snapshot)
    }
  }

  public func expire(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
    cancelledIdentifiersValue.append(identifier)
        if let existing = try await store.loadSnapshots().first(where: { $0.identifier == identifier }) {
      try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request,
          state: .expired,
          progress: existing.progress,
                    failure: .expired,
          updatedAt: updatedAt
        )
      )
    }
  }

  public func settle(
    _ identifier: RadrootsBackgroundTransferIdentifier,
    verification: RadrootsBackgroundTransferVerification
  ) async throws {
    guard
      let existing = try await store.loadSnapshots().first(where: { $0.identifier == identifier })
    else {
            throw RadrootsBackgroundTransferError.transferFailure
    }
    switch verification {
    case .accepted:
      try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request,
          state: .completed,
          progress: existing.progress,
          response: existing.response,
          downloadedArtifact: existing.downloadedArtifact,
          updatedAt: updatedAt
        )
      )
        case .rejected(let failure):
      try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request,
          state: .failed,
          progress: existing.progress,
                    failure: failure,
          updatedAt: updatedAt
        )
      )
    }
  }

  public func complete(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
    guard
      let existing = try await store.loadSnapshots().first(where: { $0.identifier == identifier })
    else {
            throw RadrootsBackgroundTransferError.transferFailure
    }
    let snapshot = try RadrootsBackgroundTransferSnapshot(
      request: existing.request,
      state: .completed,
      progress: existing.progress,
      updatedAt: updatedAt
    )
    try await store.saveSnapshot(snapshot)
  }

    public func fail(
        _ identifier: RadrootsBackgroundTransferIdentifier,
        failure: RadrootsBackgroundTransferFailure
    ) async throws {
    guard
      let existing = try await store.loadSnapshots().first(where: { $0.identifier == identifier })
    else {
            throw RadrootsBackgroundTransferError.transferFailure
    }
    let snapshot = try RadrootsBackgroundTransferSnapshot(
      request: existing.request,
      state: .failed,
      progress: existing.progress,
            failure: failure,
      updatedAt: updatedAt
    )
    try await store.saveSnapshot(snapshot)
  }

  public func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
    -> RadrootsBackgroundTransferSnapshot?
  {
    try await store.loadSnapshots().first { $0.identifier == identifier }
  }

  public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
    try await store.loadSnapshots()
  }

  public func handleEventsForBackgroundURLSession(
    identifier: String,
    completionHandler: @escaping @Sendable () -> Void
  ) async {
    handledBackgroundEventIdentifiersValue.append(identifier)
    completionHandler()
  }

  public var enqueuedRequests: [RadrootsBackgroundTransferRequest] {
    enqueuedRequestsValue
  }

  public var cancelledIdentifiers: [RadrootsBackgroundTransferIdentifier] {
    cancelledIdentifiersValue
  }

  public var handledBackgroundEventIdentifiers: [String] {
    handledBackgroundEventIdentifiersValue
  }
}
