import Foundation

public struct RadrootsBackgroundTransferSnapshot: Sendable, Equatable, Hashable, Codable,
    CustomDebugStringConvertible {
    public let identifier: RadrootsBackgroundTransferIdentifier
    public let request: RadrootsBackgroundTransferRequest
    public let state: RadrootsBackgroundTransferState
    public let progress: RadrootsBackgroundTransferProgress
    public let failure: RadrootsBackgroundTransferFailure?
    public let response: RadrootsBackgroundTransferResponse?
    public let downloadedArtifact: RadrootsBackgroundDownloadedArtifact?
    public let possibleRemoteOrphan: Bool
    public let updatedAt: Date
    public let executionID: UUID?
    public let uploadLease: RadrootsStagedBlobReference?

    public init(
        request: RadrootsBackgroundTransferRequest, state: RadrootsBackgroundTransferState = .queued,
        progress: RadrootsBackgroundTransferProgress = .zero,
        failure: RadrootsBackgroundTransferFailure? = nil,
        response: RadrootsBackgroundTransferResponse? = nil,
        downloadedArtifact: RadrootsBackgroundDownloadedArtifact? = nil,
        possibleRemoteOrphan: Bool = false, updatedAt: Date = Date(),
        executionID: UUID? = nil, uploadLease: RadrootsStagedBlobReference? = nil
    ) throws {
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        if let uploadLease {
            guard executionID != nil, request.isUpload,
                  uploadLease.blobID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  uploadLease.sizeBytes >= 0, UInt64(uploadLease.sizeBytes) <= request.maximumTransferBytes,
                  request.expectedSourceSHA256 == nil || request.expectedSourceSHA256 == uploadLease.blobID
            else { throw RadrootsBackgroundTransferError.invalidRequest }
        }
        guard response == nil || state == .awaitingVerification || state == .completed else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        if let response {
            try RadrootsBackgroundTransferValidation.validate(
                response: response, policy: request.responsePolicy
            )
        }
        if possibleRemoteOrphan {
            guard case .upload = request.operation,
                  state == .failed || state == .interrupted || state == .cancelled || state == .expired
            else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
        }
        if let downloadedArtifact {
            guard case let .download(destination) = request.operation,
                  destination == .file(downloadedArtifact.file),
                  state == .awaitingVerification || state == .completed
            else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
        }
        identifier = request.identifier
        self.request = request
        self.state = state
        self.progress = progress
        self.failure = failure
        self.response = response
        self.downloadedArtifact = downloadedArtifact
        self.possibleRemoteOrphan = possibleRemoteOrphan
        self.updatedAt = updatedAt
        self.executionID = executionID
        self.uploadLease = uploadLease
    }

    public var debugDescription: String {
        let statusCode = response?.statusCode.description ?? "none"
        return "RadrootsBackgroundTransferSnapshot(identifier: \(identifier.rawValue), state: \(state.rawValue), "
            + "bytesTransferred: \(progress.bytesTransferred), statusCode: \(statusCode), "
            + "downloadedArtifact: \(downloadedArtifact == nil ? "none" : "present"), "
            + "possibleRemoteOrphan: \(possibleRemoteOrphan))"
    }

    func redactedForPersistence() throws -> Self {
        try Self(
            request: request.redactedForPersistence(), state: state, progress: progress,
            failure: failure, response: response,
            downloadedArtifact: downloadedArtifact, possibleRemoteOrphan: possibleRemoteOrphan,
            updatedAt: updatedAt, executionID: executionID, uploadLease: uploadLease
        )
    }

    private enum CodingKeys: String, CodingKey {
        case request
        case state
        case progress
        case failure
        case response
        case downloadedArtifact
        case possibleRemoteOrphan
        case updatedAt
        case executionID
        case uploadLease
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            request: values.decode(RadrootsBackgroundTransferRequest.self, forKey: .request),
            state: values.decode(RadrootsBackgroundTransferState.self, forKey: .state),
            progress: values.decode(RadrootsBackgroundTransferProgress.self, forKey: .progress),
            failure: values.decodeIfPresent(RadrootsBackgroundTransferFailure.self, forKey: .failure),
            response: values.decodeIfPresent(RadrootsBackgroundTransferResponse.self, forKey: .response),
            downloadedArtifact: values.decodeIfPresent(
                RadrootsBackgroundDownloadedArtifact.self, forKey: .downloadedArtifact
            ),
            possibleRemoteOrphan: values.decodeIfPresent(Bool.self, forKey: .possibleRemoteOrphan)
                ?? false,
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            executionID: values.decodeIfPresent(UUID.self, forKey: .executionID),
            uploadLease: values.decodeIfPresent(RadrootsStagedBlobReference.self, forKey: .uploadLease)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request, forKey: .request)
        try values.encode(state, forKey: .state)
        try values.encode(progress, forKey: .progress)
        try values.encodeIfPresent(failure, forKey: .failure)
        try values.encodeIfPresent(response, forKey: .response)
        try values.encodeIfPresent(downloadedArtifact, forKey: .downloadedArtifact)
        try values.encode(possibleRemoteOrphan, forKey: .possibleRemoteOrphan)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(executionID, forKey: .executionID)
        try values.encodeIfPresent(uploadLease, forKey: .uploadLease)
    }
}
