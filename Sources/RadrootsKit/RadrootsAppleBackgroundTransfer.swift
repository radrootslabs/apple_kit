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
        enqueue: { _ in
            throw RadrootsBackgroundTransferError.unavailable("background transfer is unavailable on this platform")
        },
        cancel: { _ in
            throw RadrootsBackgroundTransferError.unavailable("background transfer is unavailable on this platform")
        },
        activeTransferIdentifiers: {
            throw RadrootsBackgroundTransferError.unavailable("background transfer is unavailable on this platform")
        },
        handleBackgroundEvents: { _, completionHandler in
            completionHandler()
        }
    )

    public static func live(
        sessionIdentifier: String,
        store: any RadrootsBackgroundTransferStore,
        fileResolver: any RadrootsBackgroundTransferFileResolver,
        downloadStagingRoot: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> Self {
        #if os(iOS)
        let normalizedSessionIdentifier = try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier)
        let session = RadrootsAppleBackgroundURLSession(
            identifier: normalizedSessionIdentifier,
            store: store,
            fileResolver: fileResolver,
            downloadStagingRoot: downloadStagingRoot,
            now: now
        )
        return Self(
            now: now,
            enqueue: { request in
                try await session.enqueue(request)
            },
            cancel: { identifier in
                await session.cancel(identifier)
            },
            activeTransferIdentifiers: {
                await session.activeTransferIdentifiers()
            },
            handleBackgroundEvents: { identifier, completionHandler in
                await session.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
            }
        )
        #else
        return .unavailable
        #endif
    }
}

public final class RadrootsAppleBackgroundTransfer: RadrootsBackgroundTransfer, Sendable {
    private let store: any RadrootsBackgroundTransferStore
    private let adapters: RadrootsAppleBackgroundTransferAdapters

    public init(
        store: any RadrootsBackgroundTransferStore,
        adapters: RadrootsAppleBackgroundTransferAdapters
    ) {
        self.store = store
        self.adapters = adapters
    }

    public convenience init(
        roots: RadrootsAppleFileRoots,
        sessionIdentifier: String
    ) throws {
        let store = RadrootsAppleBackgroundTransferStore(roots: roots)
        let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
        let downloadStagingRoot = try roots.resolvedURL(
            for: RadrootsFileReference(
                scope: .temporary,
                relativePath: "background_transfers/\(try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier))/downloads"
            ),
            allowRootDirectory: true
        )
        try self.init(
            store: store,
            adapters: .live(
                sessionIdentifier: sessionIdentifier,
                store: store,
                fileResolver: resolver,
                downloadStagingRoot: downloadStagingRoot
            )
        )
    }

    public func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws -> RadrootsBackgroundTransferHandle {
        try await store.saveSnapshot(
            try RadrootsBackgroundTransferSnapshot(
                request: request,
                state: .queued,
                updatedAt: adapters.now()
            )
        )
        do {
            try await adapters.enqueue(request)
            let current = try await store.loadSnapshots().first { $0.identifier == request.identifier }
            if current?.state == .queued {
                try await store.saveSnapshot(
                    try RadrootsBackgroundTransferSnapshot(
                        request: request,
                        state: .running,
                        updatedAt: adapters.now()
                    )
                )
            }
            return RadrootsBackgroundTransferHandle(request: request)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            try await store.saveSnapshot(
                try RadrootsBackgroundTransferSnapshot(
                    request: request,
                    state: .failed,
                    errorMessage: message,
                    updatedAt: adapters.now()
                )
            )
            throw error
        }
    }

    public func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
        try await adapters.cancel(identifier)
        if let existing = try await store.loadSnapshots().first(where: { $0.identifier == identifier }) {
            try await store.saveSnapshot(
                try RadrootsBackgroundTransferSnapshot(
                    request: existing.request,
                    state: .cancelled,
                    progress: existing.progress,
                    updatedAt: adapters.now()
                )
            )
        }
    }

    public func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> RadrootsBackgroundTransferSnapshot? {
        try await snapshots().first { $0.identifier == identifier }
    }

    public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        let activeIdentifiers = try await adapters.activeTransferIdentifiers()
        let storedSnapshots = try await store.loadSnapshots()
        var reconciled: [RadrootsBackgroundTransferSnapshot] = []
        for snapshot in storedSnapshots {
            if activeIdentifiers.contains(snapshot.identifier), snapshot.state == .queued {
                let runningSnapshot = try RadrootsBackgroundTransferSnapshot(
                    request: snapshot.request,
                    state: .running,
                    progress: snapshot.progress,
                    errorMessage: snapshot.errorMessage,
                    updatedAt: adapters.now()
                )
                try await store.saveSnapshot(runningSnapshot)
                reconciled.append(runningSnapshot)
            } else {
                reconciled.append(snapshot)
            }
        }
        return reconciled.sorted { left, right in
            left.identifier < right.identifier
        }
    }

    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        await adapters.handleBackgroundEvents(identifier, completionHandler)
    }
}

enum RadrootsStagedBackgroundDownloadResult: Sendable, Equatable {
    case file(URL)
    case failure(String)
}

actor RadrootsAppleBackgroundTransferCoordinator {
    private let sessionIdentifier: String
    private let store: any RadrootsBackgroundTransferStore
    private let fileResolver: any RadrootsBackgroundTransferFileResolver
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private var completionHandlersByIdentifier: [String: @Sendable () -> Void]

    init(
        sessionIdentifier: String,
        store: any RadrootsBackgroundTransferStore,
        fileResolver: any RadrootsBackgroundTransferFileResolver,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.store = store
        self.fileResolver = fileResolver
        self.now = now
        self.fileManager = fileManager
        self.completionHandlersByIdentifier = [:]
    }

    func updateProgress(
        identifier: RadrootsBackgroundTransferIdentifier,
        bytesTransferred: Int64,
        totalBytesExpected: Int64?
    ) async {
        guard let existing = try? await snapshot(for: identifier), existing.state == .running || existing.state == .queued else {
            return
        }
        guard let progress = Self.progress(
            bytesTransferred: bytesTransferred,
            totalBytesExpected: totalBytesExpected,
            fallback: existing.progress
        ) else {
            return
        }
        try? await store.saveSnapshot(
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request,
                state: .running,
                progress: progress,
                errorMessage: existing.errorMessage,
                updatedAt: now()
            )
        )
    }

    func complete(
        identifier: RadrootsBackgroundTransferIdentifier,
        platformError: Error?,
        stagedDownloadResult: RadrootsStagedBackgroundDownloadResult?,
        bytesTransferred: Int64,
        totalBytesExpected: Int64?
    ) async {
        guard let existing = try? await snapshot(for: identifier), existing.state != .cancelled else {
            return
        }
        if let platformError {
            await fail(existing: existing, message: Self.failureMessage(for: platformError))
            return
        }
        switch existing.request.operation {
        case .download(let destination):
            await completeDownload(
                existing: existing,
                destination: destination,
                stagedDownloadResult: stagedDownloadResult,
                bytesTransferred: bytesTransferred,
                totalBytesExpected: totalBytesExpected
            )
        case .upload:
            await completeUpload(
                existing: existing,
                bytesTransferred: bytesTransferred,
                totalBytesExpected: totalBytesExpected
            )
        }
    }

    func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        guard identifier == sessionIdentifier else {
            completionHandler()
            return
        }
        completionHandlersByIdentifier[identifier] = completionHandler
    }

    func finishBackgroundEvents(identifier: String?) {
        guard identifier == nil || identifier == sessionIdentifier else {
            return
        }
        completionHandlersByIdentifier.removeValue(forKey: sessionIdentifier)?()
    }

    private func completeUpload(
        existing: RadrootsBackgroundTransferSnapshot,
        bytesTransferred: Int64,
        totalBytesExpected: Int64?
    ) async {
        let progress = Self.progress(
            bytesTransferred: bytesTransferred,
            totalBytesExpected: totalBytesExpected,
            fallback: existing.progress
        ) ?? existing.progress
        try? await store.saveSnapshot(
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request,
                state: .completed,
                progress: progress,
                updatedAt: now()
            )
        )
    }

    private func completeDownload(
        existing: RadrootsBackgroundTransferSnapshot,
        destination: RadrootsBackgroundTransferLocalFile,
        stagedDownloadResult: RadrootsStagedBackgroundDownloadResult?,
        bytesTransferred: Int64,
        totalBytesExpected: Int64?
    ) async {
        guard case .file(let stagedFileURL) = stagedDownloadResult else {
            let message: String
            if case .failure(let failureMessage) = stagedDownloadResult {
                message = failureMessage
            } else {
                message = "background download finished without a staged file"
            }
            await fail(existing: existing, message: message)
            return
        }
        do {
            let destinationURL = try fileResolver.resolve(destination)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: stagedFileURL, to: destinationURL)
            let fileSize = try Self.fileSize(at: destinationURL, fileManager: fileManager)
            let progress = Self.progress(
                bytesTransferred: max(bytesTransferred, fileSize),
                totalBytesExpected: totalBytesExpected,
                fallback: existing.progress
            ) ?? existing.progress
            try await store.saveSnapshot(
                try RadrootsBackgroundTransferSnapshot(
                    request: existing.request,
                    state: .completed,
                    progress: progress,
                    updatedAt: now()
                )
            )
        } catch {
            await fail(existing: existing, message: Self.failureMessage(for: error))
        }
    }

    private func fail(existing: RadrootsBackgroundTransferSnapshot, message: String) async {
        try? await store.saveSnapshot(
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request,
                state: .failed,
                progress: existing.progress,
                errorMessage: Self.sanitizedMessage(message),
                updatedAt: now()
            )
        )
    }

    private func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> RadrootsBackgroundTransferSnapshot? {
        try await store.loadSnapshots().first { $0.identifier == identifier }
    }

    private static func progress(
        bytesTransferred: Int64,
        totalBytesExpected: Int64?,
        fallback: RadrootsBackgroundTransferProgress
    ) -> RadrootsBackgroundTransferProgress? {
        let safeBytesTransferred = max(bytesTransferred, fallback.bytesTransferred)
        let safeTotalBytesExpected = totalBytesExpected.flatMap { value -> Int64? in
            value >= safeBytesTransferred ? value : nil
        } ?? fallback.totalBytesExpected.flatMap { value -> Int64? in
            value >= safeBytesTransferred ? value : nil
        }
        return try? RadrootsBackgroundTransferProgress(
            bytesTransferred: safeBytesTransferred,
            totalBytesExpected: safeTotalBytesExpected
        )
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func failureMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return sanitizedMessage(description)
        }
        return sanitizedMessage(String(describing: error))
    }

    private static func sanitizedMessage(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? UnicodeScalar(32)! : scalar
        }
        let withoutControls = String(String.UnicodeScalarView(scalars))
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "background transfer failed"
        }
        return String(trimmed.prefix(240))
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
        identifier: String,
        store: any RadrootsBackgroundTransferStore,
        fileResolver: any RadrootsBackgroundTransferFileResolver,
        downloadStagingRoot: URL,
        now: @escaping @Sendable () -> Date
    ) {
        self.identifier = identifier
        self.fileResolver = fileResolver
        self.downloadStagingRoot = downloadStagingRoot
        self.fileManager = .default
        self.coordinator = RadrootsAppleBackgroundTransferCoordinator(
            sessionIdentifier: identifier,
            store: store,
            fileResolver: fileResolver,
            now: now
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
        case .download:
            task = session.downloadTask(with: urlRequest)
        case .upload(let source):
            task = try session.uploadTask(with: urlRequest, fromFile: fileResolver.resolve(source))
        }
        task.taskDescription = request.identifier.rawValue
        task.resume()
    }

    func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async {
        let tasks = await allTasks()
        for task in tasks where task.taskDescription == identifier.rawValue {
            task.cancel()
        }
    }

    func activeTransferIdentifiers() async -> Set<RadrootsBackgroundTransferIdentifier> {
        let tasks = await allTasks()
        let identifiers = tasks.compactMap { task -> RadrootsBackgroundTransferIdentifier? in
            guard let taskDescription = task.taskDescription else {
                return nil
            }
            return try? RadrootsBackgroundTransferIdentifier(taskDescription)
        }
        return Set(identifiers)
    }

    func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) async {
        await coordinator.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            backgroundSession().getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func backgroundSession() -> URLSession {
        if let session {
            return session
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let delegateQueue = OperationQueue()
        delegateQueue.name = "org.radroots.background-transfer.\(identifier)"
        delegateQueue.maxConcurrentOperationCount = 1
        let delegate = RadrootsAppleBackgroundURLSessionDelegate(
            coordinator: coordinator,
            downloadStagingRoot: downloadStagingRoot,
            fileManager: fileManager
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        self.session = session
        self.sessionDelegate = delegate
        self.sessionDelegateQueue = delegateQueue
        return session
    }
}

private final class RadrootsAppleBackgroundURLSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let coordinator: RadrootsAppleBackgroundTransferCoordinator
    private let downloadStagingRoot: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var stagedDownloadResultsByTaskIdentifier: [Int: RadrootsStagedBackgroundDownloadResult]

    init(
        coordinator: RadrootsAppleBackgroundTransferCoordinator,
        downloadStagingRoot: URL,
        fileManager: FileManager
    ) {
        self.coordinator = coordinator
        self.downloadStagingRoot = downloadStagingRoot
        self.fileManager = fileManager
        self.stagedDownloadResultsByTaskIdentifier = [:]
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let identifier = transferIdentifier(from: downloadTask) else {
            return
        }
        let result: RadrootsStagedBackgroundDownloadResult
        do {
            try fileManager.createDirectory(at: downloadStagingRoot, withIntermediateDirectories: true)
            let destination = downloadStagingRoot
                .appendingPathComponent("\(identifier.rawValue)-\(downloadTask.taskIdentifier).download")
                .standardizedFileURL
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            result = .file(destination)
        } catch {
            result = .failure(Self.failureMessage(for: error))
        }
        recordDownloadResult(result, taskIdentifier: downloadTask.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let identifier = transferIdentifier(from: downloadTask) else {
            return
        }
        Task {
            await coordinator.updateProgress(
                identifier: identifier,
                bytesTransferred: totalBytesWritten,
                totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToWrite)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let identifier = transferIdentifier(from: task) else {
            return
        }
        Task {
            await coordinator.updateProgress(
                identifier: identifier,
                bytesTransferred: totalBytesSent,
                totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToSend)
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let identifier = transferIdentifier(from: task) else {
            return
        }
        let bytesTransferred = max(max(task.countOfBytesReceived, task.countOfBytesSent), 0)
        let expected = Self.expectedByteCount(max(task.countOfBytesExpectedToReceive, task.countOfBytesExpectedToSend))
        let stagedDownloadResult = takeDownloadResult(taskIdentifier: task.taskIdentifier)
        Task {
            await coordinator.complete(
                identifier: identifier,
                platformError: error,
                stagedDownloadResult: stagedDownloadResult,
                bytesTransferred: bytesTransferred,
                totalBytesExpected: expected
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task {
            await coordinator.finishBackgroundEvents(identifier: session.configuration.identifier)
        }
    }

    private func recordDownloadResult(
        _ result: RadrootsStagedBackgroundDownloadResult,
        taskIdentifier: Int
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

    private func transferIdentifier(from task: URLSessionTask) -> RadrootsBackgroundTransferIdentifier? {
        guard let taskDescription = task.taskDescription else {
            return nil
        }
        return try? RadrootsBackgroundTransferIdentifier(taskDescription)
    }

    private static func expectedByteCount(_ value: Int64) -> Int64? {
        value >= 0 ? value : nil
    }

    private static func failureMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
#endif
