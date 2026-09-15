import Foundation

public enum RadrootsBackgroundTransferError: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case transferFailure
    case persistenceFailure
}

extension RadrootsBackgroundTransferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The background transfer request is invalid."
        case .unavailable: "Background transfer is unavailable."
        case .transferFailure: "The background transfer could not be completed."
        case .persistenceFailure: "The background transfer state could not be saved."
        }
    }
}

public struct RadrootsBackgroundTransferIdentifier: Sendable, Equatable, Hashable, Comparable,
    Codable {
    public let rawValue: String

    public init(_ value: String) throws {
        rawValue = try RadrootsBackgroundTransferValidation.normalizedIdentifier(value)
    }

    public static func generated() -> Self {
        Self(validatedRawValue: UUID().uuidString.lowercased())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rawValue, forKey: .rawValue)
    }
}

public enum RadrootsBackgroundTransferMethod: String, Sendable, Equatable, Hashable, Codable,
    CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
}

public enum RadrootsBackgroundTransferLocalFile: Sendable, Equatable, Hashable, Codable {
    case file(RadrootsFileReference)
    case stagedBlob(RadrootsStagedBlobReference)
}

public enum RadrootsBackgroundTransferOperation: Sendable, Equatable, Hashable, Codable {
    case download(destination: RadrootsBackgroundTransferLocalFile)
    case upload(source: RadrootsBackgroundTransferLocalFile)
}

public enum RadrootsBackgroundTransferState: String, Sendable, Equatable, Hashable, Codable,
    CaseIterable {
    case queued
    case running
    case awaitingVerification
    case completed
    case failed
    case cancelled
    case expired
    case interrupted
}

public enum RadrootsBackgroundTransferFailure: String, Sendable, Equatable, Hashable, Codable,
    CaseIterable {
    case enqueueFailed = "background_transfer_enqueue_failed"
    case expired = "background_transfer_expired"
    case interrupted = "background_transfer_interrupted"
    case verificationRejected = "background_transfer_verification_rejected"
    case transferTooLarge = "background_transfer_transfer_too_large"
    case responseTooLarge = "background_transfer_response_too_large"
    case responseMediaType = "background_transfer_response_media_type"
    case responseContentEncoding = "background_transfer_response_content_encoding"
    case platformFailure = "background_transfer_platform_failure"
    case responseMissing = "background_transfer_response_missing"
    case httpStatus = "background_transfer_http_status"
    case responseInvalid = "background_transfer_response_invalid"
    case downloadStagingFailure = "background_transfer_download_staging_failure"
    case destinationFailure = "background_transfer_destination_failure"
}

public enum RadrootsBackgroundTransferNetworkPolicy: String, Sendable, Equatable, Hashable, Codable {
    case publicHTTPS
    case simulatorLoopbackHTTP
}

public protocol RadrootsBackgroundTransferStore: Sendable {
    /// Serializes admission across suspension and independent owners. This is a
    /// nonblocking reservation, separate from short persistence transactions.
    func withAdmission(
        for identifier: RadrootsBackgroundTransferIdentifier,
        operation: @escaping @Sendable () async throws -> RadrootsBackgroundTransferHandle
    ) async throws -> RadrootsBackgroundTransferHandle
    func admissionIsActive(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> Bool
    /// Atomically installs a redacted snapshot only if the exact expected value
    /// still owns the identifier. Nil reserves a previously absent identifier.
    func compareExchangeSnapshot(
        expected: RadrootsBackgroundTransferSnapshot?, desired: RadrootsBackgroundTransferSnapshot
    ) async throws -> Bool
    func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot]
    func saveSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws
    func removeSnapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
    func removeAllSnapshots() async throws
}

public protocol RadrootsBackgroundTransfer: Sendable {
    func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws
        -> RadrootsBackgroundTransferHandle
    func retry(_ request: RadrootsBackgroundTransferRequest) async throws
        -> RadrootsBackgroundTransferHandle
    func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws
    func expire(_ identifier: RadrootsBackgroundTransferIdentifier) async throws
    func settle(
        _ identifier: RadrootsBackgroundTransferIdentifier,
        verification: RadrootsBackgroundTransferVerification
    ) async throws
    func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
        -> RadrootsBackgroundTransferSnapshot?
    func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot]
    func handleEventsForBackgroundURLSession(
        identifier: String, completionHandler: @escaping @Sendable () -> Void
    ) async
}

public protocol RadrootsBackgroundTransferFileResolver: Sendable {
    func resolve(_ file: RadrootsBackgroundTransferLocalFile) throws -> URL
    func read(_ file: RadrootsBackgroundTransferLocalFile, maximumBytes: Int) throws -> Data
    func prepareUploadLease(
        for request: RadrootsBackgroundTransferRequest, executionID: UUID,
        existing: RadrootsStagedBlobReference?
    ) throws -> RadrootsStagedBlobLease
    func releaseUploadLease(executionID: UUID) throws
}

public struct RadrootsUnavailableBackgroundTransfer: RadrootsBackgroundTransfer, Sendable {
    public init() {}

    public func enqueue(_: RadrootsBackgroundTransferRequest) async throws
        -> RadrootsBackgroundTransferHandle {
        throw RadrootsBackgroundTransferError.unavailable
    }

    public func retry(_: RadrootsBackgroundTransferRequest) async throws
        -> RadrootsBackgroundTransferHandle {
        throw RadrootsBackgroundTransferError.unavailable
    }

    public func cancel(_: RadrootsBackgroundTransferIdentifier) async throws {
        throw RadrootsBackgroundTransferError.unavailable
    }

    public func expire(_: RadrootsBackgroundTransferIdentifier) async throws {
        throw RadrootsBackgroundTransferError.unavailable
    }

    public func settle(
        _: RadrootsBackgroundTransferIdentifier,
        verification _: RadrootsBackgroundTransferVerification
    ) async throws {
        throw RadrootsBackgroundTransferError.unavailable
    }

    public func snapshot(for _: RadrootsBackgroundTransferIdentifier) async throws
        -> RadrootsBackgroundTransferSnapshot? {
        throw RadrootsBackgroundTransferError.unavailable
    }

    public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        throw RadrootsBackgroundTransferError.unavailable
    }

    public func handleEventsForBackgroundURLSession(
        identifier _: String, completionHandler: @escaping @Sendable () -> Void
    ) async {
        completionHandler()
    }
}

extension RadrootsBackgroundTransferOperation {
    var redactedLabel: String {
        switch self {
        case .download: "download"
        case .upload: "upload"
        }
    }
}
