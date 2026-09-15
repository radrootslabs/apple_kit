import Foundation

#if os(iOS)

    actor RadrootsAppleBackgroundURLSession {
        private let identifier: String
        private let fileResolver: any RadrootsBackgroundTransferFileResolver
        private let downloadStagingRoot: URL
        private let coordinator: RadrootsTransferCoordinator
        private let fileManager: FileManager
        private let usesForegroundSession: Bool
        private var session: URLSession?
        private var sessionDelegate: RadrootsTransferSessionDelegate?
        private var sessionDelegateQueue: OperationQueue?
        private let store: any RadrootsBackgroundTransferStore
        private var admissions: Set<RadrootsBackgroundTransferIdentifier> = []
        private var cancelledAdmissions: Set<RadrootsBackgroundTransferIdentifier> = []

        init(
            identifier: String, store: any RadrootsBackgroundTransferStore,
            fileResolver: any RadrootsBackgroundTransferFileResolver,
            downloadStagingRoot: URL, now: @escaping @Sendable () -> Date,
            usesForegroundSession: Bool = false
        ) {
            self.identifier = identifier
            self.store = store
            self.fileResolver = fileResolver
            self.downloadStagingRoot = downloadStagingRoot
            fileManager = .default
            self.usesForegroundSession = usesForegroundSession
            coordinator = RadrootsTransferCoordinator(
                sessionIdentifier: identifier, store: store, fileResolver: fileResolver, now: now
            )
        }

        func enqueue(_ request: RadrootsBackgroundTransferRequest, executionID: UUID) async throws {
            guard usesForegroundSession,
                  RadrootsAppleBackgroundTransferAdapters.supportsNewEnqueue(for: request.networkPolicy)
            else { throw RadrootsBackgroundTransferError.unavailable }
            try RadrootsNativeDestinationPolicy.validate(request.remoteURL, policy: request.networkPolicy)
            guard admissions.count < 256, admissions.insert(request.identifier).inserted else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            defer {
                admissions.remove(request.identifier)
                cancelledAdmissions.remove(request.identifier)
            }
            if try await alreadyAdmitted(request.identifier, executionID: executionID) {
                return
            }
            guard let snapshot = try await store.loadSnapshots().first(where: { $0.identifier == request.identifier }),
                  snapshot.executionID == executionID, snapshot.state == .queued,
                  try snapshot.request == request.redactedForPersistence(),
                  !cancelledAdmissions.contains(request.identifier)
            else { throw RadrootsBackgroundTransferError.invalidRequest }
            let session = backgroundSession()
            var urlRequest = URLRequest(url: request.remoteURL)
            urlRequest.httpMethod = request.method.rawValue
            for (key, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
            let task: URLSessionTask
            switch request.operation {
            case .download: task = session.downloadTask(with: urlRequest)
            case .upload:
                let lease = try fileResolver.prepareUploadLease(
                    for: request,
                    executionID: executionID,
                    existing: snapshot.uploadLease
                )
                let leased = try RadrootsBackgroundTransferSnapshot(
                    request: snapshot.request, state: .queued, updatedAt: snapshot.updatedAt,
                    executionID: executionID, uploadLease: lease.blob
                )
                guard try await store.compareExchangeSnapshot(expected: snapshot, desired: leased),
                      !cancelledAdmissions.contains(request.identifier), !Task.isCancelled
                else { throw RadrootsBackgroundTransferError.transferFailure }
                task = session.uploadTask(with: urlRequest, fromFile: lease.fileURL)
            }
            task.taskDescription = RadrootsBackgroundURLTaskDescriptor(request: request, executionID: executionID)
                .taskDescription
            sessionDelegate?.registerResponseBodyLimit(
                request.responsePolicy.maximumBodyBytes, taskIdentifier: task.taskIdentifier
            )
            task.resume()
        }

        private func alreadyAdmitted(_ identifier: RadrootsBackgroundTransferIdentifier,
                                     executionID: UUID) async throws -> Bool {
            let tasks = await allTasks()
            let existingTasks = tasks.filter {
                RadrootsBackgroundURLTaskDescriptor(taskDescription: $0.taskDescription)?.identifier == identifier
            }
            if !existingTasks.isEmpty {
                guard existingTasks.count == 1,
                      RadrootsBackgroundURLTaskDescriptor(taskDescription: existingTasks[0].taskDescription)?
                      .executionID == executionID
                else { throw RadrootsBackgroundTransferError.invalidRequest }
                return true
            }
            return false
        }

        func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async {
            if admissions.contains(identifier) {
                cancelledAdmissions.insert(identifier)
            }
            let tasks = await allTasks()
            for task in tasks
                where RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.identifier
                == identifier {
                task.cancel()
            }
        }

        func activeTransferIdentifiers() async -> Set<RadrootsBackgroundTransferIdentifier> {
            let tasks = await allTasks()
            let identifiers = tasks.compactMap { task -> RadrootsBackgroundTransferIdentifier? in
                RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.identifier
            }
            return Set(identifiers).union(sessionDelegate?.callbacks.pendingIdentifiers ?? [])
        }

        func handleBackgroundEvents(
            identifier: String, completionHandler: @escaping @Sendable () -> Void
        ) async {
            _ = backgroundSession()
            await coordinator.handleBackgroundEvents(
                identifier: identifier, completionHandler: completionHandler
            )
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
            let delegate = RadrootsTransferSessionDelegate(
                coordinator: coordinator, downloadStagingRoot: downloadStagingRoot, fileManager: fileManager
            )
            let session = URLSession(
                configuration: configuration, delegate: delegate, delegateQueue: delegateQueue
            )
            self.session = session
            sessionDelegate = delegate
            sessionDelegateQueue = delegateQueue
            return session
        }

        private func removeOrphanedDownloadStagingFiles() {
            guard
                let urls = try? fileManager.contentsOfDirectory(
                    at: downloadStagingRoot, includingPropertiesForKeys: nil
                )
            else { return }
            for url in urls where url.pathExtension == "download" {
                try? fileManager.removeItem(at: url)
            }
        }
    }

#endif
