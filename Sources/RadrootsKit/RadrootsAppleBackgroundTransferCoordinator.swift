import Foundation

actor RadrootsTransferCoordinator {
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
        totalBytesExpected: Int64?, executionID: UUID? = nil
    ) async {
        guard let existing = try? await snapshot(for: identifier), existing.executionID == executionID,
              existing.state == .running || existing.state == .queued
        else { return }
        guard
            let progress = Self.progress(
                bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected,
                fallback: existing.progress
            )
        else { return }
        _ = try? await store.compareExchangeSnapshot(expected: existing, desired:
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .running, progress: progress,
                failure: existing.failure,
                response: existing.response, possibleRemoteOrphan: existing.possibleRemoteOrphan,
                updatedAt: now(), executionID: existing.executionID, uploadLease: existing.uploadLease
            ))
    }

    func complete(
        identifier: RadrootsBackgroundTransferIdentifier, completion: RadrootsTransferCompletion,
        executionID: UUID? = nil
    ) async {
        guard let existing = try? await snapshot(for: identifier), existing.executionID == executionID,
              [.queued, .running, .interrupted].contains(existing.state)
        else { return }
        if let failure = Self.completionFailure(request: existing.request, completion: completion) {
            Self.removeStagedDownload(completion.stagedDownloadResult, fileManager: fileManager)
            await fail(existing: existing, code: failure, possibleRemoteOrphan: existing.request.isUpload)
            return
        }
        let response: RadrootsBackgroundTransferResponse
        do {
            response = try Self.validatedResponse(for: existing.request, httpResult: completion.httpResult)
        } catch {
            Self.removeStagedDownload(completion.stagedDownloadResult, fileManager: fileManager)
            await fail(existing: existing,
                       code: (error as? RadrootsTransferResponseError)?.failure ?? .responseInvalid,
                       possibleRemoteOrphan: existing.request.isUpload)
            return
        }
        switch existing.request.operation {
        case let .download(destination):
            await completeDownload(
                existing: existing,
                destination: destination,
                response: response,
                completion: completion
            )
        case .upload:
            await completeUpload(existing: existing, response: response, bytesTransferred: completion.bytesTransferred,
                                 totalBytesExpected: completion.totalBytesExpected)
        }
    }

    private static func completionFailure(
        request: RadrootsBackgroundTransferRequest, completion: RadrootsTransferCompletion
    ) -> RadrootsBackgroundTransferFailure? {
        if UInt64(max(completion.bytesTransferred, 0)) > request.maximumTransferBytes
            || completion.totalBytesExpected.map({ UInt64(max($0, 0)) > request.maximumTransferBytes }) == true {
            return .transferTooLarge
        }
        if completion.httpResult.bodyExceeded {
            return .responseTooLarge
        }
        if completion.httpResult.mediaTypeWasMalformed {
            return .responseMediaType
        }
        if completion.platformError != nil {
            return .platformFailure
        }
        guard let status = completion.httpResult.statusCode else { return .responseMissing }
        return (200 ... 299).contains(status) ? nil : .httpStatus
    }

    func releaseUploadLease(executionID: UUID?) {
        guard let executionID else { return }
        // Only the native terminal callback calls this. Cancellation intent alone
        // cannot release bytes still owned by URLSession. Failed cleanup remains
        // an owned orphan for later reconciliation.
        try? fileResolver.releaseUploadLease(executionID: executionID)
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
}

extension RadrootsTransferCoordinator {
    private func completeUpload(
        existing: RadrootsBackgroundTransferSnapshot, response: RadrootsBackgroundTransferResponse,
        bytesTransferred: Int64,
        totalBytesExpected: Int64?
    ) async {
        let progress =
            Self.progress(
                bytesTransferred: bytesTransferred, totalBytesExpected: totalBytesExpected,
                fallback: existing.progress
            )
            ?? existing.progress
        _ = try? await store.compareExchangeSnapshot(expected: existing, desired:
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .awaitingVerification, progress: progress,
                response: response, updatedAt: now(), executionID: existing.executionID,
                uploadLease: existing.uploadLease
            ))
    }

    private func completeDownload(
        existing: RadrootsBackgroundTransferSnapshot, destination: RadrootsBackgroundTransferLocalFile,
        response: RadrootsBackgroundTransferResponse, completion: RadrootsTransferCompletion
    ) async {
        let stagedDownloadResult = completion.stagedDownloadResult
        let mediaType = completion.httpResult.mediaType
        let bytesTransferred = completion.bytesTransferred
        let totalBytesExpected = completion.totalBytesExpected
        guard case let .file(stagedFileURL) = stagedDownloadResult else {
            await fail(existing: existing, code: .downloadStagingFailure)
            return
        }
        do {
            guard case let .file(destinationReference) = destination else {
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
                at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
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
            _ = try await store.compareExchangeSnapshot(expected: existing, desired:
                RadrootsBackgroundTransferSnapshot(
                    request: existing.request, state: .awaitingVerification, progress: progress,
                    response: response,
                    downloadedArtifact: downloadedArtifact, updatedAt: now(), executionID: existing.executionID,
                    uploadLease: existing.uploadLease
                ))
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
        _ = try? await store.compareExchangeSnapshot(expected: existing, desired:
            try RadrootsBackgroundTransferSnapshot(
                request: existing.request, state: .failed, progress: existing.progress, failure: code,
                possibleRemoteOrphan: possibleRemoteOrphan, updatedAt: now(), executionID: existing.executionID,
                uploadLease: existing.uploadLease
            ))
    }

    private func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
        -> RadrootsBackgroundTransferSnapshot? {
        try await store.loadSnapshots().first { $0.identifier == identifier }
    }

    private static func progress(
        bytesTransferred: Int64, totalBytesExpected: Int64?,
        fallback: RadrootsBackgroundTransferProgress
    )
        -> RadrootsBackgroundTransferProgress? {
        let safeBytesTransferred = max(bytesTransferred, fallback.bytesTransferred)
        let safeTotalBytesExpected =
            totalBytesExpected.flatMap { value -> Int64? in value >= safeBytesTransferred ? value : nil }
                ?? fallback.totalBytesExpected.flatMap { value -> Int64? in
                    value >= safeBytesTransferred ? value : nil
                }
        return try? RadrootsBackgroundTransferProgress(
            bytesTransferred: safeBytesTransferred, totalBytesExpected: safeTotalBytesExpected
        )
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
        -> RadrootsBackgroundTransferResponse {
        guard let statusCode = httpResult.statusCode else {
            throw RadrootsTransferResponseError(failure: .responseMissing)
        }
        if request.responsePolicy == .discard {
            return try RadrootsBackgroundTransferResponse(
                statusCode: statusCode, mediaType: nil, contentEncoding: nil, body: nil
            )
        }
        guard let body = httpResult.body else {
            throw RadrootsTransferResponseError(failure: .responseMissing)
        }
        guard let mediaType = httpResult.mediaType,
              request.responsePolicy.acceptedMediaTypes.contains(mediaType)
        else {
            throw RadrootsTransferResponseError(failure: .responseMediaType)
        }
        guard body.count <= request.responsePolicy.maximumBodyBytes else {
            throw RadrootsTransferResponseError(failure: .responseTooLarge)
        }
        guard httpResult.contentEncoding == nil || httpResult.contentEncoding == "identity" else {
            throw RadrootsTransferResponseError(failure: .responseContentEncoding)
        }
        return try RadrootsBackgroundTransferResponse(
            statusCode: statusCode, mediaType: mediaType,
            contentEncoding: httpResult.contentEncoding, body: body
        )
    }

    private static func removeStagedDownload(
        _ result: RadrootsStagedBackgroundDownloadResult?, fileManager: FileManager
    ) {
        guard case let .file(url) = result, fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}
