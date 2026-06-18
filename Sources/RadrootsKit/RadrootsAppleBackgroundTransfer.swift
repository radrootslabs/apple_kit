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
        fileResolver: any RadrootsBackgroundTransferFileResolver
    ) throws -> Self {
        #if os(iOS)
        let normalizedSessionIdentifier = try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier)
        let session = RadrootsAppleBackgroundURLSession(identifier: normalizedSessionIdentifier)
        return Self(
            enqueue: { request in
                try await session.enqueue(request, fileResolver: fileResolver)
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
        let resolver = RadrootsAppleBackgroundTransferFileResolver(roots: roots)
        try self.init(
            store: RadrootsAppleBackgroundTransferStore(roots: roots),
            adapters: .live(sessionIdentifier: sessionIdentifier, fileResolver: resolver)
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
            try await store.saveSnapshot(
                try RadrootsBackgroundTransferSnapshot(
                    request: request,
                    state: .running,
                    updatedAt: adapters.now()
                )
            )
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

#if os(iOS)
private actor RadrootsAppleBackgroundURLSession {
    private let identifier: String
    private var completionHandlersByIdentifier: [String: @Sendable () -> Void]

    init(identifier: String) {
        self.identifier = identifier
        self.completionHandlersByIdentifier = [:]
    }

    func enqueue(
        _ request: RadrootsBackgroundTransferRequest,
        fileResolver: any RadrootsBackgroundTransferFileResolver
    ) async throws {
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
    ) {
        completionHandlersByIdentifier[identifier] = completionHandler
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            backgroundSession().getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func backgroundSession() -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration)
    }
}
#endif
