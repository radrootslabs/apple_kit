import Foundation

public struct RadrootsAppleBackgroundTransferAdapters: Sendable {
  public let now: @Sendable () -> Date
  public let enqueue: @Sendable (RadrootsBackgroundTransferRequest) async throws -> Void
  public let cancel: @Sendable (RadrootsBackgroundTransferIdentifier) async throws -> Void
    public let activeTransferIdentifiers: @Sendable () async throws -> Set<RadrootsBackgroundTransferIdentifier>
    public let handleBackgroundEvents: @Sendable (String, @escaping @Sendable () -> Void) async -> Void

  public init(
    now: @escaping @Sendable () -> Date = Date.init,
    enqueue: @escaping @Sendable (RadrootsBackgroundTransferRequest) async throws -> Void,
    cancel: @escaping @Sendable (RadrootsBackgroundTransferIdentifier) async throws -> Void,
    activeTransferIdentifiers:
      @escaping @Sendable () async throws -> Set<RadrootsBackgroundTransferIdentifier>,
    handleBackgroundEvents:
      @escaping @Sendable (String, @escaping @Sendable () -> Void) async -> Void
  ) {
    self.now = now
    self.enqueue = enqueue
    self.cancel = cancel
    self.activeTransferIdentifiers = activeTransferIdentifiers
    self.handleBackgroundEvents = handleBackgroundEvents
  }

  public static let unavailable = Self(
    enqueue: { _ in
            throw RadrootsBackgroundTransferError.unavailable
    },
    cancel: { _ in
            throw RadrootsBackgroundTransferError.unavailable
    },
    activeTransferIdentifiers: {
            throw RadrootsBackgroundTransferError.unavailable
    }, handleBackgroundEvents: { _, completionHandler in completionHandler() }
  )

  public static func live(
    sessionIdentifier: String, store: any RadrootsBackgroundTransferStore,
    fileResolver: any RadrootsBackgroundTransferFileResolver,
    downloadStagingRoot: URL, now: @escaping @Sendable () -> Date = Date.init
  ) throws -> Self {
    #if os(iOS)
      let normalizedSessionIdentifier =
        try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier)
      let session = RadrootsAppleBackgroundURLSession(
        identifier: normalizedSessionIdentifier, store: store, fileResolver: fileResolver,
        downloadStagingRoot: downloadStagingRoot,
        now: now
      )
      #if targetEnvironment(simulator)
        let simulatorSession = RadrootsAppleBackgroundURLSession(
          identifier: normalizedSessionIdentifier, store: store, fileResolver: fileResolver,
          downloadStagingRoot: downloadStagingRoot,
          now: now, usesForegroundSession: true
        )
      #endif
      return Self(
        now: now,
        enqueue: { request in
          #if targetEnvironment(simulator)
            if request.networkPolicy == .simulatorLoopbackHTTP {
              try await simulatorSession.enqueue(request)
              return
            }
          #endif
          try await session.enqueue(request)
        },
        cancel: { identifier in
          #if targetEnvironment(simulator)
            await simulatorSession.cancel(identifier)
          #endif
          await session.cancel(identifier)
        },
        activeTransferIdentifiers: {
          var identifiers = await session.activeTransferIdentifiers()
          #if targetEnvironment(simulator)
            identifiers.formUnion(await simulatorSession.activeTransferIdentifiers())
          #endif
          return identifiers
        },
        handleBackgroundEvents: { identifier, completionHandler in
          await session.handleBackgroundEvents(
            identifier: identifier, completionHandler: completionHandler)
        }
      )
    #else
      return .unavailable
    #endif
  }
}

public actor RadrootsAppleBackgroundTransfer: RadrootsBackgroundTransfer {
  private let store: any RadrootsBackgroundTransferStore
  private let adapters: RadrootsAppleBackgroundTransferAdapters

  public init(
    store: any RadrootsBackgroundTransferStore, adapters: RadrootsAppleBackgroundTransferAdapters
  ) {
    self.store = store
    self.adapters = adapters
  }

  public init(roots: RadrootsAppleFileRoots, sessionIdentifier: String) throws {
    let store = RadrootsAppleBackgroundTransferStore(roots: roots)
    let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
    let downloadStagingRoot = try roots.resolvedURL(
      for: RadrootsFileReference(
        scope: .temporary,
        relativePath:
          "background_transfers/\(RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier))/downloads"
      ),
      allowRootDirectory: true
    )
    self.store = store
    adapters = try .live(
      sessionIdentifier: sessionIdentifier, store: store, fileResolver: resolver,
      downloadStagingRoot: downloadStagingRoot
    )
  }

  public func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws
    -> RadrootsBackgroundTransferHandle
  {
    guard
            try await loadStoredSnapshots().contains(where: { $0.identifier == request.identifier })
        == false
    else {
            throw RadrootsBackgroundTransferError.invalidRequest
    }
    return try await schedule(request)
  }

  public func retry(_ request: RadrootsBackgroundTransferRequest) async throws
    -> RadrootsBackgroundTransferHandle
  {
    guard
            let existing = try await loadStoredSnapshots().first(where: {
        $0.identifier == request.identifier
      }),
      existing.state == .failed || existing.state == .interrupted || existing.state == .cancelled
        || existing.state == .expired,
      try existing.request.redactedForPersistence() == request.redactedForPersistence()
    else {
            throw RadrootsBackgroundTransferError.invalidRequest
    }
    do {
      guard try await !adapters.activeTransferIdentifiers().contains(request.identifier) else {
                throw RadrootsBackgroundTransferError.invalidRequest
      }
    } catch let error as RadrootsBackgroundTransferError {
      throw error
    } catch {
            throw RadrootsBackgroundTransferError.transferFailure
    }
    return try await schedule(request)
  }

  private func schedule(_ request: RadrootsBackgroundTransferRequest) async throws
    -> RadrootsBackgroundTransferHandle
  {
        try await saveStoredSnapshot(
      RadrootsBackgroundTransferSnapshot(
        request: request, state: .queued, updatedAt: adapters.now()))
    do { try await adapters.enqueue(request) } catch {
      do {
                try await saveStoredSnapshot(
          RadrootsBackgroundTransferSnapshot(
                        request: request, state: .failed, failure: .enqueueFailed,
            updatedAt: adapters.now()
          )
        )
      } catch {
                throw RadrootsBackgroundTransferError.persistenceFailure
      }
            throw RadrootsBackgroundTransferError.transferFailure
    }
        let current = try await loadStoredSnapshots().first { $0.identifier == request.identifier }
    if current?.state == .queued {
            try await saveStoredSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: request, state: .running, updatedAt: adapters.now())
      )
    }
    return RadrootsBackgroundTransferHandle(request: request)
  }

  public func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
        if let existing = try await loadStoredSnapshots().first(where: { $0.identifier == identifier }) {
      guard
        existing.state == .queued || existing.state == .running || existing.state == .interrupted
      else { return }
            try await saveStoredSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request, state: .cancelled, progress: existing.progress,
          possibleRemoteOrphan: existing.request.isUpload && existing.state == .running,
          updatedAt: adapters.now()
        )
      )
    }
    do { try await adapters.cancel(identifier) } catch {
            throw RadrootsBackgroundTransferError.transferFailure
    }
  }

  public func expire(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
        if let existing = try await loadStoredSnapshots().first(where: { $0.identifier == identifier }) {
      guard
        existing.state == .queued || existing.state == .running || existing.state == .interrupted
      else { return }
            try await saveStoredSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request, state: .expired, progress: existing.progress,
                    failure: .expired,
          possibleRemoteOrphan: existing.request.isUpload && existing.state == .running,
          updatedAt: adapters.now()
        )
      )
    }
    do { try await adapters.cancel(identifier) } catch {
            throw RadrootsBackgroundTransferError.transferFailure
    }
  }

  public func settle(
    _ identifier: RadrootsBackgroundTransferIdentifier,
    verification: RadrootsBackgroundTransferVerification
  ) async throws {
    guard
            let existing = try await loadStoredSnapshots().first(where: { $0.identifier == identifier }),
      existing.state == .awaitingVerification
    else {
            throw RadrootsBackgroundTransferError.invalidRequest
    }
    switch verification {
    case .accepted:
            try await saveStoredSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request, state: .completed, progress: existing.progress,
          response: existing.response,
          downloadedArtifact: existing.downloadedArtifact, updatedAt: adapters.now()
        )
      )
        case .rejected(let failure):
            try await saveStoredSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request, state: .failed, progress: existing.progress,
                    failure: failure,
          possibleRemoteOrphan: existing.request.isUpload, updatedAt: adapters.now()
        )
      )
    }
  }

  public func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
    -> RadrootsBackgroundTransferSnapshot?
  {
    try await snapshots().first { $0.identifier == identifier }
  }

  public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
    let activeIdentifiers: Set<RadrootsBackgroundTransferIdentifier>
    do { activeIdentifiers = try await adapters.activeTransferIdentifiers() } catch {
            throw RadrootsBackgroundTransferError.transferFailure
    }
        let storedSnapshots = try await loadStoredSnapshots()
    let storedIdentifiers = Set(storedSnapshots.map(\.identifier))
    for orphanedIdentifier in activeIdentifiers.subtracting(storedIdentifiers) {
      do { try await adapters.cancel(orphanedIdentifier) } catch {
                throw RadrootsBackgroundTransferError.transferFailure
      }
    }
    var reconciled: [RadrootsBackgroundTransferSnapshot] = []
    for snapshot in storedSnapshots {
      if activeIdentifiers.contains(snapshot.identifier),
        snapshot.state == .queued || snapshot.state == .interrupted
      {
        let runningSnapshot = try RadrootsBackgroundTransferSnapshot(
          request: snapshot.request, state: .running, progress: snapshot.progress,
                    failure: snapshot.failure,
          updatedAt: adapters.now()
        )
                try await saveStoredSnapshot(runningSnapshot)
        reconciled.append(runningSnapshot)
      } else if !activeIdentifiers.contains(snapshot.identifier),
        snapshot.state == .queued || snapshot.state == .running
      {
        let interruptedSnapshot = try RadrootsBackgroundTransferSnapshot(
          request: snapshot.request, state: .interrupted, progress: snapshot.progress,
                    failure: .interrupted,
          possibleRemoteOrphan: snapshot.request.isUpload && snapshot.state == .running,
          updatedAt: adapters.now()
        )
                try await saveStoredSnapshot(interruptedSnapshot)
        reconciled.append(interruptedSnapshot)
      } else {
        reconciled.append(snapshot)
      }
    }
    return reconciled.sorted { left, right in left.identifier < right.identifier }
  }

  public func handleEventsForBackgroundURLSession(
    identifier: String, completionHandler: @escaping @Sendable () -> Void
  ) async {
    await adapters.handleBackgroundEvents(identifier, completionHandler)
  }

    private func loadStoredSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        do {
            return try await store.loadSnapshots()
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }

    private func saveStoredSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws {
        do {
            try await store.saveSnapshot(snapshot)
        } catch let error as RadrootsBackgroundTransferError {
            throw error
        } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure
        }
    }
}

enum RadrootsStagedBackgroundDownloadResult: Sendable, Equatable {
  case file(URL)
  case failure
}

struct RadrootsBackgroundHTTPResult: Sendable, Equatable {
  let statusCode: Int?
  let mediaType: String?
  let body: Data?
  let contentEncoding: String?
  let bodyExceeded: Bool
  let mediaTypeWasMalformed: Bool

  init(
    statusCode: Int?, mediaType: String?, body: Data?, contentEncoding: String? = nil,
    bodyExceeded: Bool,
    mediaTypeWasMalformed: Bool = false
  ) {
    self.statusCode = statusCode
    self.mediaType = mediaType
    self.body = body
    self.contentEncoding = contentEncoding
    self.bodyExceeded = bodyExceeded
    self.mediaTypeWasMalformed = mediaTypeWasMalformed
  }
}

actor RadrootsAppleBackgroundTransferCoordinator {
  private let sessionIdentifier: String
  private let store: any RadrootsBackgroundTransferStore
  private let fileResolver: any RadrootsBackgroundTransferFileResolver
  private let now: @Sendable () -> Date
  private let fileManager: FileManager
  private var completionHandlers: [@Sendable () -> Void]
  private var unclaimedFinishedEventCount: Int

  init(
    sessionIdentifier: String, store: any RadrootsBackgroundTransferStore,
    fileResolver: any RadrootsBackgroundTransferFileResolver,
    now: @escaping @Sendable () -> Date = Date.init, fileManager: FileManager = .default
  ) {
    self.sessionIdentifier = sessionIdentifier
    self.store = store
    self.fileResolver = fileResolver
    self.now = now
    self.fileManager = fileManager
    completionHandlers = []
    unclaimedFinishedEventCount = 0
  }

  func updateProgress(
    identifier: RadrootsBackgroundTransferIdentifier, bytesTransferred: Int64,
    totalBytesExpected: Int64?
  ) async {
    guard let existing = try? await snapshot(for: identifier),
      existing.state == .running || existing.state == .queued
    else { return }
    guard
      let progress = Self.progress(
        bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected,
        fallback: existing.progress
      )
    else { return }
    try? await store.saveSnapshot(
      try RadrootsBackgroundTransferSnapshot(
        request: existing.request, state: .running, progress: progress,
                failure: existing.failure,
        response: existing.response, possibleRemoteOrphan: existing.possibleRemoteOrphan,
        updatedAt: now()
      )
    )
  }

  func complete(
    identifier: RadrootsBackgroundTransferIdentifier, platformError: Error?,
    stagedDownloadResult: RadrootsStagedBackgroundDownloadResult?,
    httpResult: RadrootsBackgroundHTTPResult, bytesTransferred: Int64,
    totalBytesExpected: Int64?
  ) async {
    guard let existing = try? await snapshot(for: identifier),
      existing.state == .queued || existing.state == .running || existing.state == .interrupted
    else { return }
    if UInt64(max(bytesTransferred, 0)) > existing.request.maximumTransferBytes
      || totalBytesExpected.map({ UInt64(max($0, 0)) > existing.request.maximumTransferBytes })
        == true
    {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
        existing: existing,
                code: .transferTooLarge,
        possibleRemoteOrphan: existing.request.isUpload && bytesTransferred > 0
      )
      return
    }
    if httpResult.bodyExceeded {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
                existing: existing, code: .responseTooLarge,
        possibleRemoteOrphan: existing.request.isUpload)
      return
    }
    if httpResult.mediaTypeWasMalformed {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
                existing: existing, code: .responseMediaType,
        possibleRemoteOrphan: existing.request.isUpload && bytesTransferred > 0)
      return
    }
    if platformError != nil {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
                existing: existing, code: .platformFailure,
        possibleRemoteOrphan: existing.request.isUpload && bytesTransferred > 0
      )
      return
    }
    guard let statusCode = httpResult.statusCode else {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
                existing: existing, code: .responseMissing,
        possibleRemoteOrphan: existing.request.isUpload && bytesTransferred > 0
      )
      return
    }
    guard (200...299).contains(statusCode) else {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
        existing: existing,
                code: .httpStatus,
        possibleRemoteOrphan: existing.request.isUpload && bytesTransferred > 0
      )
      return
    }
    let response: RadrootsBackgroundTransferResponse
    do {
      response = try Self.validatedResponse(for: existing.request, httpResult: httpResult)
        } catch let validationError as RadrootsBackgroundResponseValidationError {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
                existing: existing, code: validationError.failure,
        possibleRemoteOrphan: existing.request.isUpload)
      return
    } catch {
      Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
      await fail(
                existing: existing, code: .responseInvalid,
        possibleRemoteOrphan: existing.request.isUpload)
      return
    }
    switch existing.request.operation {
    case .download(let destination):
      await completeDownload(
        existing: existing, destination: destination, stagedDownloadResult: stagedDownloadResult,
        response: response, mediaType: httpResult.mediaType,
        bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected
      )
    case .upload:
      await completeUpload(
        existing: existing, response: response, bytesTransferred: bytesTransferred,
        totalBytesExpected: totalBytesExpected
      )
    }
  }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
    guard identifier == sessionIdentifier else {
      completionHandler()
      return
    }
    if unclaimedFinishedEventCount > 0 {
      unclaimedFinishedEventCount -= 1
      completionHandler()
      return
    }
    guard completionHandlers.count < 8 else {
      completionHandler()
      return
    }
    completionHandlers.append(completionHandler)
  }

  func finishBackgroundEvents(identifier: String?) {
    guard identifier == nil || identifier == sessionIdentifier else { return }
    guard !completionHandlers.isEmpty else {
      unclaimedFinishedEventCount = min(unclaimedFinishedEventCount + 1, 8)
      return
    }
    let handlers = completionHandlers
    completionHandlers.removeAll()
    for handler in handlers {
      handler()
    }
  }

  private func completeUpload(
    existing: RadrootsBackgroundTransferSnapshot, response: RadrootsBackgroundTransferResponse,
    bytesTransferred: Int64,
    totalBytesExpected: Int64?
  ) async {
    let progress =
      Self.progress(
        bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected,
        fallback: existing.progress)
      ?? existing.progress
    try? await store.saveSnapshot(
      try RadrootsBackgroundTransferSnapshot(
        request: existing.request, state: .awaitingVerification, progress: progress,
        response: response, updatedAt: now()
      )
    )
  }

  private func completeDownload(
    existing: RadrootsBackgroundTransferSnapshot, destination: RadrootsBackgroundTransferLocalFile,
    stagedDownloadResult: RadrootsStagedBackgroundDownloadResult?,
    response: RadrootsBackgroundTransferResponse, mediaType: String?,
    bytesTransferred: Int64, totalBytesExpected: Int64?
  ) async {
    guard case .file(let stagedFileURL) = stagedDownloadResult else {
            await fail(existing: existing, code: .downloadStagingFailure)
      return
    }
    do {
      guard case .file(let destinationReference) = destination else {
                throw RadrootsBackgroundTransferError.invalidRequest
      }
      let destinationURL = try fileResolver.resolve(destination)
      let fileSize = try Self.fileSize(at: stagedFileURL, fileManager: fileManager)
      guard fileSize > 0, UInt64(fileSize) <= existing.request.maximumTransferBytes else {
                throw RadrootsBackgroundTransferError.transferFailure
      }
      let downloadedArtifact = try RadrootsBackgroundDownloadedArtifact(
        file: destinationReference,
        sha256: RadrootsAppleFileDigest.sha256(at: stagedFileURL),
        byteSize: UInt64(fileSize),
        mediaType: mediaType
      )
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.moveReplacingItem(from: stagedFileURL, to: destinationURL, fileManager: fileManager)
      #if os(iOS)
        try fileManager.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: destinationURL.path
        )
      #endif
      let progress =
        Self.progress(
          bytesTransferred: max(bytesTransferred, fileSize), totalBytesExpected: totalBytesExpected,
          fallback: existing.progress
        )
        ?? existing.progress
      try await store.saveSnapshot(
        RadrootsBackgroundTransferSnapshot(
          request: existing.request, state: .awaitingVerification, progress: progress,
          response: response,
          downloadedArtifact: downloadedArtifact, updatedAt: now()
        )
      )
    } catch {
      Self.removeStagedDownload(.file(stagedFileURL), fileManager: fileManager)
            await fail(existing: existing, code: .destinationFailure)
    }
  }

  private func fail(
        existing: RadrootsBackgroundTransferSnapshot,
        code: RadrootsBackgroundTransferFailure,
        possibleRemoteOrphan: Bool = false
  ) async {
    try? await store.saveSnapshot(
      try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .failed, progress: existing.progress, failure: code,
        possibleRemoteOrphan: possibleRemoteOrphan, updatedAt: now()
      )
    )
  }

  private func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
    -> RadrootsBackgroundTransferSnapshot?
  {
    try await store.loadSnapshots().first { $0.identifier == identifier }
  }

  private static func progress(
    bytesTransferred: Int64, totalBytesExpected: Int64?,
    fallback: RadrootsBackgroundTransferProgress
  )
    -> RadrootsBackgroundTransferProgress?
  {
    let safeBytesTransferred = max(bytesTransferred, fallback.bytesTransferred)
    let safeTotalBytesExpected =
      totalBytesExpected.flatMap { value -> Int64? in value >= safeBytesTransferred ? value : nil }
      ?? fallback.totalBytesExpected.flatMap { value -> Int64? in
        value >= safeBytesTransferred ? value : nil
      }
    return try? RadrootsBackgroundTransferProgress(
      bytesTransferred: safeBytesTransferred, totalBytesExpected: safeTotalBytesExpected)
  }

  private static func fileSize(at url: URL, fileManager _: FileManager) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values.fileSize ?? 0)
  }

  private static func moveReplacingItem(
    from source: URL, to destination: URL, fileManager: FileManager
  ) throws {
    guard fileManager.fileExists(atPath: destination.path) else {
      try fileManager.moveItem(at: source, to: destination)
      return
    }
    let backup = destination.deletingLastPathComponent().appendingPathComponent(
      ".radroots-transfer-backup-\(UUID().uuidString.lowercased())"
    )
    try fileManager.moveItem(at: destination, to: backup)
    do {
      try fileManager.moveItem(at: source, to: destination)
      try fileManager.removeItem(at: backup)
    } catch {
      if fileManager.fileExists(atPath: destination.path) {
        try? fileManager.removeItem(at: destination)
      }
      if fileManager.fileExists(atPath: backup.path) {
        try? fileManager.moveItem(at: backup, to: destination)
      }
      throw error
    }
  }

  private static func validatedResponse(
    for request: RadrootsBackgroundTransferRequest, httpResult: RadrootsBackgroundHTTPResult
  ) throws
    -> RadrootsBackgroundTransferResponse
  {
    guard let statusCode = httpResult.statusCode else {
            throw RadrootsBackgroundResponseValidationError(failure: .responseMissing)
    }
    if request.responsePolicy == .discard {
      return try RadrootsBackgroundTransferResponse(
        statusCode: statusCode, mediaType: nil, contentEncoding: nil, body: nil)
    }
    guard let body = httpResult.body else {
            throw RadrootsBackgroundResponseValidationError(failure: .responseMissing)
    }
    guard let mediaType = httpResult.mediaType,
      request.responsePolicy.acceptedMediaTypes.contains(mediaType)
    else {
            throw RadrootsBackgroundResponseValidationError(failure: .responseMediaType)
    }
    guard body.count <= request.responsePolicy.maximumBodyBytes else {
            throw RadrootsBackgroundResponseValidationError(failure: .responseTooLarge)
    }
    guard httpResult.contentEncoding == nil || httpResult.contentEncoding == "identity" else {
            throw RadrootsBackgroundResponseValidationError(failure: .responseContentEncoding)
    }
    return try RadrootsBackgroundTransferResponse(
      statusCode: statusCode, mediaType: mediaType,
      contentEncoding: httpResult.contentEncoding, body: body)
  }

  private static func removeStagedDownload(
    _ result: RadrootsStagedBackgroundDownloadResult?, fileManager: FileManager
  ) {
    guard case .file(let url) = result, fileManager.fileExists(atPath: url.path) else { return }
    try? fileManager.removeItem(at: url)
  }
}

struct RadrootsBackgroundURLTaskDescriptor: Sendable, Equatable {
  private static let prefix = "radroots-transfer-v1"

  let identifier: RadrootsBackgroundTransferIdentifier
  let maximumTransferBytes: UInt64
  let maximumResponseBodyBytes: Int

  init(request: RadrootsBackgroundTransferRequest) {
    identifier = request.identifier
    maximumTransferBytes = request.maximumTransferBytes
    maximumResponseBodyBytes = request.responsePolicy.maximumBodyBytes
  }

  init?(taskDescription: String?) {
    guard let taskDescription else { return nil }
    let components = taskDescription.split(separator: "|", omittingEmptySubsequences: false)
    if components.count == 4,
      components[0] == Substring(Self.prefix),
      let identifier = try? RadrootsBackgroundTransferIdentifier(String(components[1])),
      let maximumTransferBytes = UInt64(components[2]),
      let maximumResponseBodyBytes = Int(components[3]),
      maximumTransferBytes > 0,
      maximumTransferBytes <= RadrootsBackgroundTransferRequest.absoluteMaximumTransferBytes,
      (0...65_536).contains(maximumResponseBodyBytes)
    {
      self.identifier = identifier
      self.maximumTransferBytes = maximumTransferBytes
      self.maximumResponseBodyBytes = maximumResponseBodyBytes
      return
    }
    guard let legacyIdentifier = try? RadrootsBackgroundTransferIdentifier(taskDescription) else {
      return nil
    }
    identifier = legacyIdentifier
    maximumTransferBytes = RadrootsBackgroundTransferRequest.defaultMaximumTransferBytes
    maximumResponseBodyBytes = 65_536
  }

  var taskDescription: String {
    "\(Self.prefix)|\(identifier.rawValue)|\(maximumTransferBytes)|\(maximumResponseBodyBytes)"
  }
}

#if os(iOS)
  private actor RadrootsAppleBackgroundURLSession {
    private let identifier: String
    private let fileResolver: any RadrootsBackgroundTransferFileResolver
    private let downloadStagingRoot: URL
    private let coordinator: RadrootsAppleBackgroundTransferCoordinator
    private let fileManager: FileManager
    private let usesForegroundSession: Bool
    private var session: URLSession?
    private var sessionDelegate: RadrootsAppleBackgroundURLSessionDelegate?
    private var sessionDelegateQueue: OperationQueue?

    init(
      identifier: String, store: any RadrootsBackgroundTransferStore,
      fileResolver: any RadrootsBackgroundTransferFileResolver,
      downloadStagingRoot: URL, now: @escaping @Sendable () -> Date,
      usesForegroundSession: Bool = false
    ) {
      self.identifier = identifier
      self.fileResolver = fileResolver
      self.downloadStagingRoot = downloadStagingRoot
      fileManager = .default
      self.usesForegroundSession = usesForegroundSession
      coordinator = RadrootsAppleBackgroundTransferCoordinator(
        sessionIdentifier: identifier, store: store, fileResolver: fileResolver, now: now
      )
    }

    func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws {
      let session = backgroundSession()
      var urlRequest = URLRequest(url: request.remoteURL)
      urlRequest.httpMethod = request.method.rawValue
      for (key, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: key)
      }
      let task: URLSessionTask
      switch request.operation {
      case .download: task = session.downloadTask(with: urlRequest)
      case .upload(let source):
        let sourceURL = try fileResolver.resolve(source)
        let sourceData = try fileResolver.read(
          source,
          maximumBytes: Int(request.maximumTransferBytes)
        )
        if let expectedDigest = request.expectedSourceSHA256,
          RadrootsAppleFileDigest.sha256(sourceData) != expectedDigest
        {
                    throw RadrootsBackgroundTransferError.invalidRequest
        }
        task = session.uploadTask(with: urlRequest, fromFile: sourceURL)
      }
      task.taskDescription = RadrootsBackgroundURLTaskDescriptor(request: request).taskDescription
      sessionDelegate?.registerResponseBodyLimit(
        request.responsePolicy.maximumBodyBytes, taskIdentifier: task.taskIdentifier)
      task.resume()
    }

    func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async {
      let tasks = await allTasks()
      for task in tasks
      where RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.identifier
        == identifier
      {
        task.cancel()
      }
    }

    func activeTransferIdentifiers() async -> Set<RadrootsBackgroundTransferIdentifier> {
      let tasks = await allTasks()
      let identifiers = tasks.compactMap { task -> RadrootsBackgroundTransferIdentifier? in
        RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.identifier
      }
      return Set(identifiers)
    }

    func handleBackgroundEvents(
      identifier: String, completionHandler: @escaping @Sendable () -> Void
    ) async {
      _ = backgroundSession()
      await coordinator.handleBackgroundEvents(
        identifier: identifier, completionHandler: completionHandler)
    }

    private func allTasks() async -> [URLSessionTask] {
      await withCheckedContinuation { continuation in
        backgroundSession().getAllTasks { tasks in continuation.resume(returning: tasks) }
      }
    }

    private func backgroundSession() -> URLSession {
      if let session {
        return session
      }
      removeOrphanedDownloadStagingFiles()
      let configuration: URLSessionConfiguration
      if usesForegroundSession {
        configuration = .ephemeral
      } else {
        configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
      }
      let delegateQueue = OperationQueue()
      delegateQueue.name = "org.radroots.background-transfer.\(identifier)"
      delegateQueue.maxConcurrentOperationCount = 1
      let delegate = RadrootsAppleBackgroundURLSessionDelegate(
        coordinator: coordinator, downloadStagingRoot: downloadStagingRoot, fileManager: fileManager
      )
      let session = URLSession(
        configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
      self.session = session
      sessionDelegate = delegate
      sessionDelegateQueue = delegateQueue
      return session
    }

    private func removeOrphanedDownloadStagingFiles() {
      guard
        let urls = try? fileManager.contentsOfDirectory(
          at: downloadStagingRoot, includingPropertiesForKeys: nil)
      else { return }
      for url in urls where url.pathExtension == "download" {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  private final class RadrootsAppleBackgroundURLSessionDelegate: NSObject,
    URLSessionDownloadDelegate, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
  {
    private static let absoluteMaximumResponseBodyBytes = 65536
    private let coordinator: RadrootsAppleBackgroundTransferCoordinator
    private let downloadStagingRoot: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var stagedDownloadResultsByTaskIdentifier: [Int: RadrootsStagedBackgroundDownloadResult]
    private var responseBodyLimitsByTaskIdentifier: [Int: Int]
    private var responseBodiesByTaskIdentifier: [Int: Data]
    private var exceededResponseBodyTaskIdentifiers: Set<Int>

    init(
      coordinator: RadrootsAppleBackgroundTransferCoordinator, downloadStagingRoot: URL,
      fileManager: FileManager
    ) {
      self.coordinator = coordinator
      self.downloadStagingRoot = downloadStagingRoot
      self.fileManager = fileManager
      stagedDownloadResultsByTaskIdentifier = [:]
      responseBodyLimitsByTaskIdentifier = [:]
      responseBodiesByTaskIdentifier = [:]
      exceededResponseBodyTaskIdentifiers = []
    }

    func urlSession(
      _: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
      guard let identifier = transferIdentifier(from: downloadTask) else { return }
      let result: RadrootsStagedBackgroundDownloadResult
      do {
        guard
          let descriptor = RadrootsBackgroundURLTaskDescriptor(
            taskDescription: downloadTask.taskDescription),
          let fileSize = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          fileSize >= 0,
          UInt64(fileSize) <= descriptor.maximumTransferBytes
        else {
                    throw RadrootsBackgroundTransferError.transferFailure
        }
        try fileManager.createDirectory(at: downloadStagingRoot, withIntermediateDirectories: true)
        let destination = downloadStagingRoot.appendingPathComponent(
          "\(identifier.rawValue)-\(downloadTask.taskIdentifier).download"
        ).standardizedFileURL
        if fileManager.fileExists(atPath: destination.path) {
          try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: location, to: destination)
        try fileManager.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: destination.path
        )
        result = .file(destination)
      } catch { result = .failure }
      recordDownloadResult(result, taskIdentifier: downloadTask.taskIdentifier)
    }

    func urlSession(
      _: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
      totalBytesWritten: Int64,
      totalBytesExpectedToWrite: Int64
    ) {
      guard let identifier = transferIdentifier(from: downloadTask) else { return }
      if exceedsTransferLimit(
        task: downloadTask,
        bytesTransferred: totalBytesWritten,
        totalBytesExpected: totalBytesExpectedToWrite
      ) {
        downloadTask.cancel()
        return
      }
      Task {
        await coordinator.updateProgress(
          identifier: identifier, bytesTransferred: totalBytesWritten,
          totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToWrite)
        )
      }
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let shouldCancel = appendResponseBody(data, task: dataTask)
      if shouldCancel {
        dataTask.cancel()
      }
    }

    func urlSession(
      _: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64,
      totalBytesExpectedToSend: Int64
    ) {
      guard let identifier = transferIdentifier(from: task) else { return }
      if exceedsTransferLimit(
        task: task, bytesTransferred: totalBytesSent, totalBytesExpected: totalBytesExpectedToSend)
      {
        task.cancel()
        return
      }
      Task {
        await coordinator.updateProgress(
          identifier: identifier, bytesTransferred: totalBytesSent,
          totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToSend)
        )
      }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      let bytesTransferred = max(max(task.countOfBytesReceived, task.countOfBytesSent), 0)
      let expected = Self.expectedByteCount(
        max(task.countOfBytesExpectedToReceive, task.countOfBytesExpectedToSend))
      let stagedDownloadResult = takeDownloadResult(taskIdentifier: task.taskIdentifier)
      let httpResult = takeHTTPResult(for: task)
      guard let identifier = transferIdentifier(from: task) else {
        if case .file(let url) = stagedDownloadResult {
          try? fileManager.removeItem(at: url)
        }
        return
      }
      Task {
        await coordinator.complete(
          identifier: identifier, platformError: error, stagedDownloadResult: stagedDownloadResult,
          httpResult: httpResult,
          bytesTransferred: bytesTransferred, totalBytesExpected: expected
        )
      }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
      Task {
        await coordinator.finishBackgroundEvents(identifier: session.configuration.identifier)
      }
    }

    func urlSession(
      _: URLSession,
      task _: URLSessionTask,
      willPerformHTTPRedirection _: HTTPURLResponse,
      newRequest _: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }

    private func recordDownloadResult(
      _ result: RadrootsStagedBackgroundDownloadResult, taskIdentifier: Int
    ) {
      lock.lock()
      defer { lock.unlock() }
      stagedDownloadResultsByTaskIdentifier[taskIdentifier] = result
    }

        private func takeDownloadResult(taskIdentifier: Int) -> RadrootsStagedBackgroundDownloadResult? {
      lock.lock()
      defer { lock.unlock() }
      return stagedDownloadResultsByTaskIdentifier.removeValue(forKey: taskIdentifier)
    }

    func registerResponseBodyLimit(_ limit: Int, taskIdentifier: Int) {
      lock.lock()
      defer { lock.unlock() }
      responseBodyLimitsByTaskIdentifier[taskIdentifier] = min(
        max(limit, 0), Self.absoluteMaximumResponseBodyBytes)
    }

    private func appendResponseBody(_ data: Data, task: URLSessionDataTask) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      let taskIdentifier = task.taskIdentifier
      guard !exceededResponseBodyTaskIdentifiers.contains(taskIdentifier) else { return false }
      let limit =
        responseBodyLimitsByTaskIdentifier[taskIdentifier]
        ?? RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?
        .maximumResponseBodyBytes
        ?? Self.absoluteMaximumResponseBodyBytes
      guard limit > 0 else { return false }
      let currentCount = responseBodiesByTaskIdentifier[taskIdentifier]?.count ?? 0
      guard data.count <= limit - currentCount else {
        responseBodiesByTaskIdentifier.removeValue(forKey: taskIdentifier)
        exceededResponseBodyTaskIdentifiers.insert(taskIdentifier)
        return true
      }
      responseBodiesByTaskIdentifier[taskIdentifier, default: Data()].append(data)
      return false
    }

    private func takeHTTPResult(for task: URLSessionTask) -> RadrootsBackgroundHTTPResult {
      lock.lock()
      let body = responseBodiesByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
      responseBodyLimitsByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
      let exceeded = exceededResponseBodyTaskIdentifiers.remove(task.taskIdentifier) != nil
      lock.unlock()

      guard let response = task.response as? HTTPURLResponse else {
        return RadrootsBackgroundHTTPResult(
          statusCode: nil, mediaType: nil, body: body, bodyExceeded: exceeded)
      }
      let rawMediaType = response.value(forHTTPHeaderField: "Content-Type")
      let mediaType = rawMediaType.flatMap {
        try? RadrootsBackgroundTransferValidation.normalizedMediaType($0)
      }
      let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return RadrootsBackgroundHTTPResult(
        statusCode: response.statusCode, mediaType: mediaType, body: body,
        contentEncoding: contentEncoding, bodyExceeded: exceeded,
        mediaTypeWasMalformed: rawMediaType != nil && mediaType == nil)
    }

    private func transferIdentifier(from task: URLSessionTask)
      -> RadrootsBackgroundTransferIdentifier?
    {
      RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.identifier
    }

    private func exceedsTransferLimit(
      task: URLSessionTask, bytesTransferred: Int64, totalBytesExpected: Int64
    ) -> Bool {
      guard
        let descriptor = RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)
      else { return true }
      return bytesTransferred > 0 && UInt64(bytesTransferred) > descriptor.maximumTransferBytes
        || totalBytesExpected > 0 && UInt64(totalBytesExpected) > descriptor.maximumTransferBytes
    }

    private static func expectedByteCount(_ value: Int64) -> Int64? {
      value >= 0 ? value : nil
    }
  }
#endif

extension RadrootsBackgroundTransferRequest {
  fileprivate var isUpload: Bool {
    if case .upload = operation {
      return true
    }
    return false
  }
}

private struct RadrootsBackgroundResponseValidationError: Error {
    let failure: RadrootsBackgroundTransferFailure
}
