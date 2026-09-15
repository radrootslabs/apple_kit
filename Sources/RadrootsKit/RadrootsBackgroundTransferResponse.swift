import Foundation

public struct RadrootsBackgroundTransferResponsePolicy: Sendable, Equatable, Hashable, Codable {
    public let maximumBodyBytes: Int
    public let acceptedMediaTypes: [String]

    public init(maximumBodyBytes: Int = 0, acceptedMediaTypes: [String] = []) throws {
        guard (0 ... 65536).contains(maximumBodyBytes), acceptedMediaTypes.count <= 8 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        let normalized = try acceptedMediaTypes.map {
            try RadrootsBackgroundTransferValidation.normalizedMediaType($0)
        }
        guard Set(normalized).count == normalized.count, (maximumBodyBytes == 0) == normalized.isEmpty
        else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        self.maximumBodyBytes = maximumBodyBytes
        self.acceptedMediaTypes = normalized
    }

    public static let discard = Self(maximumBodyBytes: 0, acceptedMediaTypes: [], validated: ())

    public static func boundedJSON(maximumBodyBytes: Int = 16384) throws -> Self {
        try Self(maximumBodyBytes: maximumBodyBytes, acceptedMediaTypes: ["application/json"])
    }

    private init(maximumBodyBytes: Int, acceptedMediaTypes: [String], validated _: Void) {
        self.maximumBodyBytes = maximumBodyBytes
        self.acceptedMediaTypes = acceptedMediaTypes
    }

    private enum CodingKeys: String, CodingKey {
        case maximumBodyBytes
        case acceptedMediaTypes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumBodyBytes: values.decode(Int.self, forKey: .maximumBodyBytes),
            acceptedMediaTypes: values.decode([String].self, forKey: .acceptedMediaTypes)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maximumBodyBytes, forKey: .maximumBodyBytes)
        try values.encode(acceptedMediaTypes, forKey: .acceptedMediaTypes)
    }
}

public struct RadrootsBackgroundTransferResponse: Sendable, Equatable, Hashable, Codable {
    public let statusCode: Int
    public let mediaType: String?
    public let contentEncoding: String?
    public let body: Data?

    public init(
        statusCode: Int, mediaType: String?, contentEncoding: String? = nil, body: Data?
    ) throws {
        guard (100 ... 599).contains(statusCode), body?.count ?? 0 <= 65536 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        self.statusCode = statusCode
        self.mediaType = try mediaType.map {
            try RadrootsBackgroundTransferValidation.normalizedMediaType($0)
        }
        let normalizedEncoding = contentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedEncoding == nil || normalizedEncoding == "identity" else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        self.contentEncoding = normalizedEncoding
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case statusCode
        case mediaType
        case contentEncoding
        case body
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            statusCode: values.decode(Int.self, forKey: .statusCode),
            mediaType: values.decodeIfPresent(String.self, forKey: .mediaType),
            contentEncoding: values.decodeIfPresent(String.self, forKey: .contentEncoding),
            body: values.decodeIfPresent(Data.self, forKey: .body)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(statusCode, forKey: .statusCode)
        try values.encodeIfPresent(mediaType, forKey: .mediaType)
        try values.encodeIfPresent(contentEncoding, forKey: .contentEncoding)
        try values.encodeIfPresent(body, forKey: .body)
    }
}
