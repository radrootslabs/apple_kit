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
        activeTransferIdentifiers: @escaping @Sendable () async throws -> Set<RadrootsBackgroundTransferIdentifier>,
        handleBackgroundEvents: @escaping @Sendable (String, @escaping @Sendable () -> Void) async -> Void
    ) {
        self.now = now
        self.enqueue = enqueue
        self.cancel = cancel
        self.activeTransferIdentifiers = activeTransferIdentifiers
        self.handleBackgroundEvents = handleBackgroundEvents
    }

    public static let unavailable = Self(
        enqueue: { _ in throw RadrootsBackgroundTransferError.unavailable("background transfer is unavailable on this platform") },
        cancel: { _ in throw RadrootsBackgroundTransferError.unavailable("background transfer is unavailable on this platform") },
        activeTransferIdentifiers: {
            throw RadrootsBackgroundTransferError.unavailable("background transfer is unavailable on this platform")
        }, handleBackgroundEvents: { _, completionHandler in completionHandler() })

    public static func live(
        sessionIdentifier: String, store: any RadrootsBackgroundTransferStore, fileResolver: any RadrootsBackgroundTransferFileResolver,
        downloadStagingRoot: URL, now: @escaping @Sendable () -> Date = Date.init
    ) throws -> Self {
        #if os(iOS)
            let normalizedSessionIdentifier = try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier)
            let session = RadrootsAppleBackgroundURLSession(
                identifier: normalizedSessionIdentifier, store: store, fileResolver: fileResolver, downloadStagingRoot: downloadStagingRoot,
                now: now)
            return Self(
                now: now, enqueue: { request in try await session.enqueue(request) },
                cancel: { identifier in await session.cancel(identifier) },
                activeTransferIdentifiers: { await session.activeTransferIdentifiers() },
                handleBackgroundEvents: { identifier, completionHandler in
                    await session.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
                })
        #else
            return .unavailable
        #endif
    }
}

public actor RadrootsAppleBackgroundTransfer: RadrootsBackgroundTransfer {
    private let store: any RadrootsBackgroundTransferStore
    private let adapters: RadrootsAppleBackgroundTransferAdapters

    public init(store: any RadrootsBackgroundTransferStore, adapters: RadrootsAppleBackgroundTransferAdapters) {
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
                    "background_transfers/\(try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier))/downloads"),
            allowRootDirectory: true)
        self.store = store
        self.adapters = try .live(
            sessionIdentifier: sessionIdentifier, store: store, fileResolver: resolver, downloadStagingRoot: downloadStagingRoot)
    }

    public func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws -> RadrootsBackgroundTransferHandle {
        guard try await store.loadSnapshots().contains(where: { $0.identifier == request.identifier }) == false else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer identifier already exists")
        }
        try await store.saveSnapshot(try RadrootsBackgroundTransferSnapshot(request: request, state: .queued, updatedAt: adapters.now()))
        do { try await adapters.enqueue(request) } catch {
            do {
                try await store.saveSnapshot(
                    try RadrootsBackgroundTransferSnapshot(
                        request: request, state: .failed, errorMessage: "background_transfer_enqueue_failed", updatedAt: adapters.now()))
            } catch {
                throw RadrootsBackgroundTransferError.persistenceFailure("background transfer enqueue failure could not be persisted")
            }
            throw RadrootsBackgroundTransferError.transferFailure("background transfer enqueue failed")
        }
        let current = try await store.loadSnapshots().first { $0.identifier == request.identifier }
        if current?.state == .queued {
            try await store.saveSnapshot(
                try RadrootsBackgroundTransferSnapshot(request: request, state: .running, updatedAt: adapters.now()))
        }
        return RadrootsBackgroundTransferHandle(request: request)
    }

    public func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
        do { try await adapters.cancel(identifier) } catch {
            throw RadrootsBackgroundTransferError.transferFailure("background transfer cancellation failed")
        }
        if let existing = try await store.loadSnapshots().first(where: { $0.identifier == identifier }) {
            try await store.saveSnapshot(
                try RadrootsBackgroundTransferSnapshot(
                    request: existing.request, state: .cancelled, progress: existing.progress, updatedAt: adapters.now()))
        }
    }

    public func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> RadrootsBackgroundTransferSnapshot? {
        try await snapshots().first { $0.identifier == identifier }
    }

    public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        let activeIdentifiers: Set<RadrootsBackgroundTransferIdentifier>
        do { activeIdentifiers = try await adapters.activeTransferIdentifiers() } catch {
            throw RadrootsBackgroundTransferError.transferFailure("background transfer recovery failed")
        }
        let storedSnapshots = try await store.loadSnapshots()
        var reconciled: [RadrootsBackgroundTransferSnapshot] = []
        for snapshot in storedSnapshots {
            if activeIdentifiers.contains(snapshot.identifier), snapshot.state == .queued {
                let runningSnapshot = try RadrootsBackgroundTransferSnapshot(
                    request: snapshot.request, state: .running, progress: snapshot.progress, errorMessage: snapshot.errorMessage,
                    updatedAt: adapters.now())
                try await store.saveSnapshot(runningSnapshot)
                reconciled.append(runningSnapshot)
            } else if !activeIdentifiers.contains(snapshot.identifier), snapshot.state == .queued || snapshot.state == .running {
                let interruptedSnapshot = try RadrootsBackgroundTransferSnapshot(
                    request: snapshot.request, state: .interrupted, progress: snapshot.progress,
                    errorMessage: "background_transfer_interrupted",
                    possibleRemoteOrphan: snapshot.request.isUpload && snapshot.state == .running, updatedAt: adapters.now())
                try await store.saveSnapshot(interruptedSnapshot)
                reconciled.append(interruptedSnapshot)
            } else {
                reconciled.append(snapshot)
            }
        }
        return reconciled.sorted { left, right in left.identifier < right.identifier }
    }

    public func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping @Sendable () -> Void) async {
        await adapters.handleBackgroundEvents(identifier, completionHandler)
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
    let bodyExceeded: Bool
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
        sessionIdentifier: String, store: any RadrootsBackgroundTransferStore, fileResolver: any RadrootsBackgroundTransferFileResolver,
        now: @escaping @Sendable () -> Date = Date.init, fileManager: FileManager = .default
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.store = store
        self.fileResolver = fileResolver
        self.now = now
        self.fileManager = fileManager
        self.completionHandlers = []
        self.unclaimedFinishedEventCount = 0
    }

    func updateProgress(identifier: RadrootsBackgroundTransferIdentifier, bytesTransferred: Int64, totalBytesExpected: Int64?) async {
        guard let existing = try? await snapshot(for: identifier), existing.state == .running || existing.state == .queued else { return }
        guard
            let progress = Self.progress(
                bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected, fallback: existing.progress)
        else { return }
        try? await store.saveSnapshot(
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .running, progress: progress, errorMessage: existing.errorMessage,
                response: existing.response, possibleRemoteOrphan: existing.possibleRemoteOrphan, updatedAt: now()))
    }

    func complete(
        identifier: RadrootsBackgroundTransferIdentifier, platformError: Error?,
        stagedDownloadResult: RadrootsStagedBackgroundDownloadResult?, httpResult: RadrootsBackgroundHTTPResult, bytesTransferred: Int64,
        totalBytesExpected: Int64?
    ) async {
        guard let existing = try? await snapshot(for: identifier),
            existing.state == .queued || existing.state == .running || existing.state == .interrupted
        else { return }
        if httpResult.bodyExceeded {
            Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
            await fail(existing: existing, code: "background_transfer_response_too_large", possibleRemoteOrphan: existing.request.isUpload)
            return
        }
        if platformError != nil {
            Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
            await fail(
                existing: existing, code: "background_transfer_platform_failure",
                possibleRemoteOrphan: existing.request.isUpload && bytesTransferred > 0)
            return
        }
        guard let statusCode = httpResult.statusCode else {
            Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
            await fail(
                existing: existing, code: "background_transfer_response_missing",
                possibleRemoteOrphan: existing.request.isUpload && bytesTransferred > 0)
            return
        }
        guard (200...299).contains(statusCode) else {
            Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
            await fail(existing: existing, code: "background_transfer_http_status_\(statusCode)")
            return
        }
        let response: RadrootsBackgroundTransferResponse
        do { response = try Self.validatedResponse(for: existing.request, httpResult: httpResult) } catch let transferError
            as RadrootsBackgroundTransferError
        {
            Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
            await fail(existing: existing, code: transferError.stableCode, possibleRemoteOrphan: existing.request.isUpload)
            return
        } catch {
            Self.removeStagedDownload(stagedDownloadResult, fileManager: fileManager)
            await fail(existing: existing, code: "background_transfer_response_invalid", possibleRemoteOrphan: existing.request.isUpload)
            return
        }
        switch existing.request.operation {
        case .download(let destination):
            await completeDownload(
                existing: existing, destination: destination, stagedDownloadResult: stagedDownloadResult, response: response,
                bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected)
        case .upload:
            await completeUpload(
                existing: existing, response: response, bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected)
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
        for handler in handlers { handler() }
    }

    private func completeUpload(
        existing: RadrootsBackgroundTransferSnapshot, response: RadrootsBackgroundTransferResponse, bytesTransferred: Int64,
        totalBytesExpected: Int64?
    ) async {
        let progress =
            Self.progress(bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected, fallback: existing.progress)
            ?? existing.progress
        try? await store.saveSnapshot(
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .completed, progress: progress, response: response, updatedAt: now()))
    }

    private func completeDownload(
        existing: RadrootsBackgroundTransferSnapshot, destination: RadrootsBackgroundTransferLocalFile,
        stagedDownloadResult: RadrootsStagedBackgroundDownloadResult?, response: RadrootsBackgroundTransferResponse,
        bytesTransferred: Int64, totalBytesExpected: Int64?
    ) async {
        guard case .file(let stagedFileURL) = stagedDownloadResult else {
            await fail(existing: existing, code: "background_transfer_download_staging_failure")
            return
        }
        do {
            let destinationURL = try fileResolver.resolve(destination)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.moveReplacingItem(from: stagedFileURL, to: destinationURL, fileManager: fileManager)
            #if os(iOS)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destinationURL.path)
            #endif
            let fileSize = try Self.fileSize(at: destinationURL, fileManager: fileManager)
            let progress =
                Self.progress(
                    bytesTransferred: max(bytesTransferred, fileSize), totalBytesExpected: totalBytesExpected, fallback: existing.progress)
                ?? existing.progress
            try await store.saveSnapshot(
                try RadrootsBackgroundTransferSnapshot(
                    request: existing.request, state: .completed, progress: progress, response: response, updatedAt: now()))
        } catch {
            Self.removeStagedDownload(.file(stagedFileURL), fileManager: fileManager)
            await fail(existing: existing, code: "background_transfer_destination_failure")
        }
    }

    private func fail(existing: RadrootsBackgroundTransferSnapshot, code: String, possibleRemoteOrphan: Bool = false) async {
        try? await store.saveSnapshot(
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .failed, progress: existing.progress, errorMessage: code,
                possibleRemoteOrphan: possibleRemoteOrphan, updatedAt: now()))
    }

    private func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> RadrootsBackgroundTransferSnapshot? {
        try await store.loadSnapshots().first { $0.identifier == identifier }
    }

    private static func progress(bytesTransferred: Int64, totalBytesExpected: Int64?, fallback: RadrootsBackgroundTransferProgress)
        -> RadrootsBackgroundTransferProgress?
    {
        let safeBytesTransferred = max(bytesTransferred, fallback.bytesTransferred)
        let safeTotalBytesExpected =
            totalBytesExpected.flatMap { value -> Int64? in value >= safeBytesTransferred ? value : nil }
            ?? fallback.totalBytesExpected.flatMap { value -> Int64? in value >= safeBytesTransferred ? value : nil }
        return try? RadrootsBackgroundTransferProgress(bytesTransferred: safeBytesTransferred, totalBytesExpected: safeTotalBytesExpected)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func moveReplacingItem(from source: URL, to destination: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        let backup = destination.deletingLastPathComponent().appendingPathComponent(
            ".radroots-transfer-backup-\(UUID().uuidString.lowercased())")
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
            if fileManager.fileExists(atPath: backup.path) { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
    }

    private static func validatedResponse(for request: RadrootsBackgroundTransferRequest, httpResult: RadrootsBackgroundHTTPResult) throws
        -> RadrootsBackgroundTransferResponse
    {
        guard let statusCode = httpResult.statusCode else {
            throw RadrootsBackgroundTransferError.transferFailure("background_transfer_response_missing")
        }
        if request.responsePolicy == .discard {
            return try RadrootsBackgroundTransferResponse(statusCode: statusCode, mediaType: nil, body: nil)
        }
        guard let body = httpResult.body else {
            throw RadrootsBackgroundTransferError.transferFailure("background_transfer_response_missing")
        }
        guard let mediaType = httpResult.mediaType, request.responsePolicy.acceptedMediaTypes.contains(mediaType) else {
            throw RadrootsBackgroundTransferError.transferFailure("background_transfer_response_media_type")
        }
        guard body.count <= request.responsePolicy.maximumBodyBytes else {
            throw RadrootsBackgroundTransferError.transferFailure("background_transfer_response_too_large")
        }
        return try RadrootsBackgroundTransferResponse(statusCode: statusCode, mediaType: mediaType, body: body)
    }

    private static func removeStagedDownload(_ result: RadrootsStagedBackgroundDownloadResult?, fileManager: FileManager) {
        guard case .file(let url) = result, fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}

#if os(iOS)
    private actor RadrootsAppleBackgroundURLSession {
        private let identifier: String
        private let fileResolver: any RadrootsBackgroundTransferFileResolver
        private let downloadStagingRoot: URL
        private let coordinator: RadrootsAppleBackgroundTransferCoordinator
        private let fileManager: FileManager
        private var session: URLSession?
        private var sessionDelegate: RadrootsAppleBackgroundURLSessionDelegate?
        private var sessionDelegateQueue: OperationQueue?

        init(
            identifier: String, store: any RadrootsBackgroundTransferStore, fileResolver: any RadrootsBackgroundTransferFileResolver,
            downloadStagingRoot: URL, now: @escaping @Sendable () -> Date
        ) {
            self.identifier = identifier
            self.fileResolver = fileResolver
            self.downloadStagingRoot = downloadStagingRoot
            self.fileManager = .default
            self.coordinator = RadrootsAppleBackgroundTransferCoordinator(
                sessionIdentifier: identifier, store: store, fileResolver: fileResolver, now: now)
        }

        func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws {
            let session = backgroundSession()
            var urlRequest = URLRequest(url: request.remoteURL)
            urlRequest.httpMethod = request.method.rawValue
            for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
            let task: URLSessionTask
            switch request.operation {
            case .download: task = session.downloadTask(with: urlRequest)
            case .upload(let source):
                let sourceURL = try fileResolver.resolve(source)
                let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw RadrootsBackgroundTransferError.invalidRequest("background upload source must be a regular file")
                }
                if case .stagedBlob(let blob) = source, values.fileSize != blob.sizeBytes {
                    throw RadrootsBackgroundTransferError.invalidRequest("background upload source size does not match its handle")
                }
                if let expectedDigest = request.expectedSourceSHA256, try RadrootsAppleFileDigest.sha256(at: sourceURL) != expectedDigest {
                    throw RadrootsBackgroundTransferError.invalidRequest("background upload source does not match its digest")
                }
                task = session.uploadTask(with: urlRequest, fromFile: sourceURL)
            }
            task.taskDescription = request.identifier.rawValue
            sessionDelegate?.registerResponseBodyLimit(request.responsePolicy.maximumBodyBytes, taskIdentifier: task.taskIdentifier)
            task.resume()
        }

        func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async {
            let tasks = await allTasks()
            for task in tasks where task.taskDescription == identifier.rawValue { task.cancel() }
        }

        func activeTransferIdentifiers() async -> Set<RadrootsBackgroundTransferIdentifier> {
            let tasks = await allTasks()
            let identifiers = tasks.compactMap { task -> RadrootsBackgroundTransferIdentifier? in
                guard let taskDescription = task.taskDescription else { return nil }
                return try? RadrootsBackgroundTransferIdentifier(taskDescription)
            }
            return Set(identifiers)
        }

        func handleBackgroundEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) async {
            _ = backgroundSession()
            await coordinator.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
        }

        private func allTasks() async -> [URLSessionTask] {
            await withCheckedContinuation { continuation in
                backgroundSession().getAllTasks { tasks in continuation.resume(returning: tasks) }
            }
        }

        private func backgroundSession() -> URLSession {
            if let session { return session }
            removeOrphanedDownloadStagingFiles()
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            let delegateQueue = OperationQueue()
            delegateQueue.name = "org.radroots.background-transfer.\(identifier)"
            delegateQueue.maxConcurrentOperationCount = 1
            let delegate = RadrootsAppleBackgroundURLSessionDelegate(
                coordinator: coordinator, downloadStagingRoot: downloadStagingRoot, fileManager: fileManager)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
            self.session = session
            self.sessionDelegate = delegate
            self.sessionDelegateQueue = delegateQueue
            return session
        }

        private func removeOrphanedDownloadStagingFiles() {
            guard let urls = try? fileManager.contentsOfDirectory(at: downloadStagingRoot, includingPropertiesForKeys: nil) else { return }
            for url in urls where url.pathExtension == "download" { try? fileManager.removeItem(at: url) }
        }
    }

    private final class RadrootsAppleBackgroundURLSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate,
        URLSessionTaskDelegate, @unchecked Sendable
    {
        private static let absoluteMaximumResponseBodyBytes = 65_536
        private let coordinator: RadrootsAppleBackgroundTransferCoordinator
        private let downloadStagingRoot: URL
        private let fileManager: FileManager
        private let lock = NSLock()
        private var stagedDownloadResultsByTaskIdentifier: [Int: RadrootsStagedBackgroundDownloadResult]
        private var responseBodyLimitsByTaskIdentifier: [Int: Int]
        private var responseBodiesByTaskIdentifier: [Int: Data]
        private var exceededResponseBodyTaskIdentifiers: Set<Int>

        init(coordinator: RadrootsAppleBackgroundTransferCoordinator, downloadStagingRoot: URL, fileManager: FileManager) {
            self.coordinator = coordinator
            self.downloadStagingRoot = downloadStagingRoot
            self.fileManager = fileManager
            self.stagedDownloadResultsByTaskIdentifier = [:]
            self.responseBodyLimitsByTaskIdentifier = [:]
            self.responseBodiesByTaskIdentifier = [:]
            self.exceededResponseBodyTaskIdentifiers = []
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let identifier = transferIdentifier(from: downloadTask) else { return }
            let result: RadrootsStagedBackgroundDownloadResult
            do {
                try fileManager.createDirectory(at: downloadStagingRoot, withIntermediateDirectories: true)
                let destination = downloadStagingRoot.appendingPathComponent(
                    "\(identifier.rawValue)-\(downloadTask.taskIdentifier).download"
                ).standardizedFileURL
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: location, to: destination)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                result = .file(destination)
            } catch { result = .failure }
            recordDownloadResult(result, taskIdentifier: downloadTask.taskIdentifier)
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard let identifier = transferIdentifier(from: downloadTask) else { return }
            Task {
                await coordinator.updateProgress(
                    identifier: identifier, bytesTransferred: totalBytesWritten,
                    totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToWrite))
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let shouldCancel = appendResponseBody(data, taskIdentifier: dataTask.taskIdentifier)
            if shouldCancel { dataTask.cancel() }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            guard let identifier = transferIdentifier(from: task) else { return }
            Task {
                await coordinator.updateProgress(
                    identifier: identifier, bytesTransferred: totalBytesSent,
                    totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToSend))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let bytesTransferred = max(max(task.countOfBytesReceived, task.countOfBytesSent), 0)
            let expected = Self.expectedByteCount(max(task.countOfBytesExpectedToReceive, task.countOfBytesExpectedToSend))
            let stagedDownloadResult = takeDownloadResult(taskIdentifier: task.taskIdentifier)
            let httpResult = takeHTTPResult(for: task)
            guard let identifier = transferIdentifier(from: task) else {
                if case .file(let url) = stagedDownloadResult { try? fileManager.removeItem(at: url) }
                return
            }
            Task {
                await coordinator.complete(
                    identifier: identifier, platformError: error, stagedDownloadResult: stagedDownloadResult, httpResult: httpResult,
                    bytesTransferred: bytesTransferred, totalBytesExpected: expected)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { await coordinator.finishBackgroundEvents(identifier: session.configuration.identifier) }
        }

        private func recordDownloadResult(_ result: RadrootsStagedBackgroundDownloadResult, taskIdentifier: Int) {
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
            responseBodyLimitsByTaskIdentifier[taskIdentifier] = min(max(limit, 0), Self.absoluteMaximumResponseBodyBytes)
        }

        private func appendResponseBody(_ data: Data, taskIdentifier: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !exceededResponseBodyTaskIdentifiers.contains(taskIdentifier) else { return false }
            let limit = responseBodyLimitsByTaskIdentifier[taskIdentifier] ?? Self.absoluteMaximumResponseBodyBytes
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
                return RadrootsBackgroundHTTPResult(statusCode: nil, mediaType: nil, body: body, bodyExceeded: exceeded)
            }
            let mediaType = response.value(forHTTPHeaderField: "Content-Type").flatMap {
                try? RadrootsBackgroundTransferValidation.normalizedMediaType($0)
            }
            return RadrootsBackgroundHTTPResult(statusCode: response.statusCode, mediaType: mediaType, body: body, bodyExceeded: exceeded)
        }

        private func transferIdentifier(from task: URLSessionTask) -> RadrootsBackgroundTransferIdentifier? {
            guard let taskDescription = task.taskDescription else { return nil }
            return try? RadrootsBackgroundTransferIdentifier(taskDescription)
        }

        private static func expectedByteCount(_ value: Int64) -> Int64? { value >= 0 ? value : nil }

    }
#endif

extension RadrootsBackgroundTransferRequest {
    fileprivate var isUpload: Bool {
        if case .upload = operation { return true }
        return false
    }
}

extension RadrootsBackgroundTransferError {
    fileprivate var stableCode: String {
        let value: String
        switch self {
        case .invalidRequest(let message), .unavailable(let message), .transferFailure(let message), .persistenceFailure(let message):
            value = message
        }
        guard value.range(of: "^background_transfer_[a-z0-9_]+$", options: .regularExpression) != nil else {
            return "background_transfer_response_invalid"
        }
        return value
    }
}
