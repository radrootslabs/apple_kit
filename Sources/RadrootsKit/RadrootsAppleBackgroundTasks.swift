import Foundation

#if canImport(BackgroundTasks) && os(iOS)
    import BackgroundTasks
#endif

public struct RadrootsAppleBackgroundTaskRegistration: Sendable {
    public let identifier: RadrootsBackgroundTaskIdentifier
    public let kind: RadrootsBackgroundTaskKind
    public let handler: @Sendable () async -> Bool

    public init(
        identifier: RadrootsBackgroundTaskIdentifier,
        kind: RadrootsBackgroundTaskKind,
        handler: @escaping @Sendable () async -> Bool
    ) {
        self.identifier = identifier
        self.kind = kind
        self.handler = handler
    }
}

public struct RadrootsAppleBackgroundTaskSchedulerAdapters: Sendable {
    public let now: @Sendable () -> Date
    public let register: @Sendable (RadrootsAppleBackgroundTaskRegistration) async throws -> Bool
    public let submit: @Sendable (RadrootsBackgroundTaskRequest) async throws -> Void
    public let cancel: @Sendable (RadrootsBackgroundTaskIdentifier) async -> Void
    public let cancelAll: @Sendable () async -> Void
    public let pendingTasks: @Sendable () async throws -> [RadrootsBackgroundTaskSnapshot]

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        register: @escaping @Sendable (RadrootsAppleBackgroundTaskRegistration) async throws -> Bool,
        submit: @escaping @Sendable (RadrootsBackgroundTaskRequest) async throws -> Void,
        cancel: @escaping @Sendable (RadrootsBackgroundTaskIdentifier) async -> Void,
        cancelAll: @escaping @Sendable () async -> Void,
        pendingTasks: @escaping @Sendable () async throws -> [RadrootsBackgroundTaskSnapshot]
    ) {
        self.now = now
        self.register = register
        self.submit = submit
        self.cancel = cancel
        self.cancelAll = cancelAll
        self.pendingTasks = pendingTasks
    }

    public static var live: Self {
        #if canImport(BackgroundTasks) && os(iOS)
            Self(
                register: { registration in
                    BGTaskScheduler.shared.register(
                        forTaskWithIdentifier: registration.identifier.rawValue,
                        using: nil
                    ) { task in
                        let completion = RadrootsAppleBackgroundTaskCompletion(task: task)
                        let handlerTask = Task {
                            await registration.handler()
                        }
                        task.expirationHandler = {
                            handlerTask.cancel()
                            completion.complete(success: false)
                        }
                        Task {
                            let success = await handlerTask.value
                            completion.complete(success: success)
                        }
                    }
                },
                submit: { request in
                    try BGTaskScheduler.shared.submit(Self.platformRequest(for: request))
                },
                cancel: { identifier in
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier.rawValue)
                },
                cancelAll: {
                    BGTaskScheduler.shared.cancelAllTaskRequests()
                },
                pendingTasks: {
                    try await Self.pendingPlatformTaskSnapshots()
                }
            )
        #else
            unavailable
        #endif
    }

    public static let unavailable = Self(
        register: { _ in
            throw RadrootsBackgroundTaskError.unavailable("background task scheduling is unavailable on this platform")
        },
        submit: { _ in
            throw RadrootsBackgroundTaskError.unavailable("background task scheduling is unavailable on this platform")
        },
        cancel: { _ in },
        cancelAll: {},
        pendingTasks: {
            throw RadrootsBackgroundTaskError.unavailable("background task scheduling is unavailable on this platform")
        }
    )
}

public final class RadrootsAppleBackgroundTaskScheduler: RadrootsBackgroundTaskScheduler, Sendable {
    private let adapters: RadrootsAppleBackgroundTaskSchedulerAdapters

    public init(adapters: RadrootsAppleBackgroundTaskSchedulerAdapters = .live) {
        self.adapters = adapters
    }

    @discardableResult
    public func register(_ registration: RadrootsAppleBackgroundTaskRegistration) async throws -> Bool {
        let registered = try await adapters.register(registration)
        guard registered else {
            throw RadrootsBackgroundTaskError.schedulerFailure(
                "background task registration was rejected"
            )
        }
        return registered
    }

    public func submit(_ request: RadrootsBackgroundTaskRequest) async throws -> RadrootsBackgroundTaskSnapshot {
        try await adapters.submit(request)
        return try RadrootsBackgroundTaskSnapshot(
            request: request,
            submittedAt: adapters.now()
        )
    }

    public func cancel(_ identifier: RadrootsBackgroundTaskIdentifier) async throws {
        await adapters.cancel(identifier)
    }

    public func cancelAll() async throws {
        await adapters.cancelAll()
    }

    public func pendingTasks() async throws -> [RadrootsBackgroundTaskSnapshot] {
        try await adapters.pendingTasks()
    }
}

#if canImport(BackgroundTasks) && os(iOS)
    private extension RadrootsAppleBackgroundTaskSchedulerAdapters {
        static func platformRequest(for request: RadrootsBackgroundTaskRequest) -> BGTaskRequest {
            let platformRequest: BGTaskRequest
            switch request.kind {
            case .appRefresh:
                platformRequest = BGAppRefreshTaskRequest(identifier: request.identifier.rawValue)
            case .processing:
                let processingRequest = BGProcessingTaskRequest(identifier: request.identifier.rawValue)
                processingRequest.requiresNetworkConnectivity = request.requiresNetworkConnectivity
                processingRequest.requiresExternalPower = request.requiresExternalPower
                platformRequest = processingRequest
            }
            platformRequest.earliestBeginDate = request.earliestBeginDate
            return platformRequest
        }

        static func pendingPlatformTaskSnapshots() async throws -> [RadrootsBackgroundTaskSnapshot] {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RadrootsBackgroundTaskSnapshot], Error>) in
                BGTaskScheduler.shared.getPendingTaskRequests { requests in
                    do {
                        let snapshots: [RadrootsBackgroundTaskSnapshot] = try requests.compactMap { request -> RadrootsBackgroundTaskSnapshot? in
                            guard let identifier = try? RadrootsBackgroundTaskIdentifier(request.identifier) else {
                                return nil
                            }
                            let kind: RadrootsBackgroundTaskKind
                            let requiresNetworkConnectivity: Bool
                            let requiresExternalPower: Bool
                            if let processingRequest = request as? BGProcessingTaskRequest {
                                kind = .processing
                                requiresNetworkConnectivity = processingRequest.requiresNetworkConnectivity
                                requiresExternalPower = processingRequest.requiresExternalPower
                            } else {
                                kind = .appRefresh
                                requiresNetworkConnectivity = false
                                requiresExternalPower = false
                            }
                            return try RadrootsBackgroundTaskSnapshot(
                                identifier: identifier,
                                kind: kind,
                                earliestBeginDate: request.earliestBeginDate,
                                submittedAt: Date(),
                                requiresNetworkConnectivity: requiresNetworkConnectivity,
                                requiresExternalPower: requiresExternalPower
                            )
                        }
                        .sorted { left, right in
                            left.identifier.rawValue < right.identifier.rawValue
                        }
                        continuation.resume(returning: snapshots)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
#endif

#if canImport(BackgroundTasks) && os(iOS)
    private final class RadrootsAppleBackgroundTaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var completed = false

        init(task: BGTask) {
            self.task = task
        }

        func complete(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else {
                return
            }
            completed = true
            task.setTaskCompleted(success: success)
        }
    }
#endif
