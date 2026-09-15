import Foundation

#if os(iOS)
    final class RadrootsTransferSessionDelegate: NSObject,
        URLSessionDownloadDelegate, URLSessionDataDelegate,
        URLSessionTaskDelegate, @unchecked Sendable {
        private let coordinator: RadrootsTransferCoordinator
        private let downloadStagingRoot: URL
        private let fileManager: FileManager
        private let lock = NSLock()
        private var stagedDownloadResultsByTaskIdentifier: [Int: RadrootsStagedBackgroundDownloadResult]
        let callbacks = RadrootsTransferCallbackQueue()
        private let responses = RadrootsTransferResponseCollector()

        init(
            coordinator: RadrootsTransferCoordinator, downloadStagingRoot: URL,
            fileManager: FileManager
        ) {
            self.coordinator = coordinator
            self.downloadStagingRoot = downloadStagingRoot
            self.fileManager = fileManager
            stagedDownloadResultsByTaskIdentifier = [:]
        }

        func urlSession(
            _: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            guard let identifier = transferIdentifier(from: downloadTask) else { return }
            let result: RadrootsStagedBackgroundDownloadResult
            do {
                guard
                    RadrootsNativeDestinationPolicy.responseMatches(
                        downloadTask.response?.url, original: downloadTask.originalRequest,
                        current: downloadTask.currentRequest
                    ),
                    let descriptor = RadrootsBackgroundURLTaskDescriptor(
                        taskDescription: downloadTask.taskDescription
                    ),
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
            } catch {
                result = .failure
            }
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
                    totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToWrite),
                    executionID: RadrootsBackgroundURLTaskDescriptor(taskDescription: downloadTask.taskDescription)?
                        .executionID
                )
            }
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let shouldCancel = responses.append(data, taskIdentifier: dataTask.taskIdentifier,
                                                fallbackLimit: responseLimit(dataTask))
            if shouldCancel {
                dataTask.cancel()
            }
        }

        func urlSession(
            _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let accepted = RadrootsNativeDestinationPolicy.responseMatches(
                response.url, original: dataTask.originalRequest, current: dataTask.currentRequest
            ) && responses.begin(
                response,
                taskIdentifier: dataTask.taskIdentifier,
                fallbackLimit: responseLimit(dataTask)
            )
            completionHandler(accepted ? .allow : .cancel)
        }

        func urlSession(
            _: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            guard let identifier = transferIdentifier(from: task) else { return }
            if exceedsTransferLimit(
                task: task, bytesTransferred: totalBytesSent, totalBytesExpected: totalBytesExpectedToSend
            ) {
                task.cancel()
                return
            }
            Task {
                await coordinator.updateProgress(
                    identifier: identifier, bytesTransferred: totalBytesSent,
                    totalBytesExpected: Self.expectedByteCount(totalBytesExpectedToSend),
                    executionID: RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.executionID
                )
            }
        }

        func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let bytesTransferred = max(max(task.countOfBytesReceived, task.countOfBytesSent), 0)
            let expected = Self.expectedByteCount(
                max(task.countOfBytesExpectedToReceive, task.countOfBytesExpectedToSend)
            )
            let stagedDownloadResult = takeDownloadResult(taskIdentifier: task.taskIdentifier)
            let httpResult = takeHTTPResult(for: task)
            guard let identifier = transferIdentifier(from: task) else {
                if case let .file(url) = stagedDownloadResult {
                    try? fileManager.removeItem(at: url)
                }
                return
            }
            callbacks.enqueue(receipt: identifier) { [coordinator] in
                await coordinator.complete(
                    identifier: identifier,
                    completion: RadrootsTransferCompletion(platformError: error,
                                                           stagedDownloadResult: stagedDownloadResult,
                                                           httpResult: httpResult,
                                                           bytesTransferred: bytesTransferred,
                                                           totalBytesExpected: expected),
                    executionID: RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.executionID
                )
                await coordinator.releaseUploadLease(
                    executionID: RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?.executionID
                )
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            callbacks.enqueue { [coordinator] in
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
            responses.register(limit, taskIdentifier: taskIdentifier)
        }

        private func responseLimit(_ task: URLSessionTask) -> Int {
            RadrootsBackgroundURLTaskDescriptor(taskDescription: task.taskDescription)?
                .maximumResponseBodyBytes ?? 65536
        }

        private func takeHTTPResult(for task: URLSessionTask) -> RadrootsBackgroundHTTPResult {
            responses.take(taskIdentifier: task.taskIdentifier, response: task.response as? HTTPURLResponse,
                           destinationMismatch: task.response != nil && !RadrootsNativeDestinationPolicy
                               .responseMatches(
                                   task.response?.url,
                                   original: task.originalRequest,
                                   current: task.currentRequest
                               ))
        }

        private func transferIdentifier(from task: URLSessionTask)
            -> RadrootsBackgroundTransferIdentifier? {
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
