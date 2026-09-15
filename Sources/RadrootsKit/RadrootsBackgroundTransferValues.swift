import Foundation

public struct RadrootsBackgroundDownloadedArtifact: Sendable, Equatable, Hashable, Codable,
    CustomDebugStringConvertible {
    public let file: RadrootsFileReference
    public let sha256: String
    public let byteSize: UInt64
    public let mediaType: String?

    public init(file: RadrootsFileReference, sha256: String, byteSize: UInt64, mediaType: String?)
        throws {
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, byteSize > 0,
              byteSize <= RadrootsBackgroundTransferRequest.absoluteMaximumTransferBytes
        else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        try RadrootsBackgroundTransferValidation.validateLocalFile(.file(file))
        self.file = file
        self.sha256 = sha256
        self.byteSize = byteSize
        self.mediaType = try mediaType.map {
            try RadrootsBackgroundTransferValidation.normalizedMediaType($0)
        }
    }

    public var debugDescription: String {
        "RadrootsBackgroundDownloadedArtifact(sha256: \(sha256), byteSize: \(byteSize), "
            + "mediaType: \(mediaType ?? "none"), file: <redacted>)"
    }
}

public enum RadrootsBackgroundTransferVerification: Sendable, Equatable {
    case accepted
    case rejected(failure: RadrootsBackgroundTransferFailure)
}

public struct RadrootsBackgroundTransferHandle: Sendable, Equatable, Hashable, Codable,
    CustomDebugStringConvertible {
    public let identifier: RadrootsBackgroundTransferIdentifier
    public let request: RadrootsBackgroundTransferRequest

    public init(request: RadrootsBackgroundTransferRequest) {
        identifier = request.identifier
        self.request = request
    }

    public var debugDescription: String {
        "RadrootsBackgroundTransferHandle(identifier: \(identifier.rawValue), request: \(request.debugDescription))"
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case request
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try values.decode(
            RadrootsBackgroundTransferIdentifier.self, forKey: .identifier
        )
        let request = try values.decode(RadrootsBackgroundTransferRequest.self, forKey: .request)
        guard identifier == request.identifier else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        self.init(request: request)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(identifier, forKey: .identifier)
        try values.encode(request, forKey: .request)
    }
}

public struct RadrootsBackgroundTransferProgress: Sendable, Equatable, Hashable, Codable {
    public let bytesTransferred: Int64
    public let totalBytesExpected: Int64?

    public init(bytesTransferred: Int64, totalBytesExpected: Int64? = nil) throws {
        guard bytesTransferred >= 0 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        if let totalBytesExpected {
            guard totalBytesExpected >= 0 else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
            guard totalBytesExpected >= bytesTransferred else {
                throw RadrootsBackgroundTransferError.invalidRequest
            }
        }
        self.bytesTransferred = bytesTransferred
        self.totalBytesExpected = totalBytesExpected
    }

    public static let zero = RadrootsBackgroundTransferProgress(
        validatedBytesTransferred: 0, totalBytesExpected: nil
    )

    private init(validatedBytesTransferred: Int64, totalBytesExpected: Int64?) {
        bytesTransferred = validatedBytesTransferred
        self.totalBytesExpected = totalBytesExpected
    }

    private enum CodingKeys: String, CodingKey {
        case bytesTransferred
        case totalBytesExpected
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bytesTransferred: values.decode(Int64.self, forKey: .bytesTransferred),
            totalBytesExpected: values.decodeIfPresent(Int64.self, forKey: .totalBytesExpected)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bytesTransferred, forKey: .bytesTransferred)
        try values.encodeIfPresent(totalBytesExpected, forKey: .totalBytesExpected)
    }
}
