import Foundation

public struct RadrootsBackgroundTransferRequest: Sendable, Equatable, Hashable, Codable,
    CustomDebugStringConvertible {
    public static let defaultMaximumTransferBytes: UInt64 = 64 * 1024 * 1024
    public static let absoluteMaximumTransferBytes: UInt64 = 512 * 1024 * 1024

    public let identifier: RadrootsBackgroundTransferIdentifier
    public let remoteURL: URL
    public let method: RadrootsBackgroundTransferMethod
    public let operation: RadrootsBackgroundTransferOperation
    public let headers: [String: String]
    public let metadata: [String: String]
    public let networkPolicy: RadrootsBackgroundTransferNetworkPolicy
    public let responsePolicy: RadrootsBackgroundTransferResponsePolicy
    public let expectedSourceSHA256: String?
    public let maximumTransferBytes: UInt64

    public init(
        identifier: RadrootsBackgroundTransferIdentifier = .generated(), remoteURL: URL,
        method: RadrootsBackgroundTransferMethod,
        operation: RadrootsBackgroundTransferOperation, headers: [String: String] = [:],
        metadata: [String: String] = [:],
        networkPolicy: RadrootsBackgroundTransferNetworkPolicy = .publicHTTPS,
        responsePolicy: RadrootsBackgroundTransferResponsePolicy = .discard,
        expectedSourceSHA256: String? = nil,
        maximumTransferBytes: UInt64 = Self.defaultMaximumTransferBytes
    ) throws {
        try RadrootsBackgroundTransferValidation.validate(
            remoteURL: remoteURL, method: method, operation: operation, headers: headers,
            metadata: metadata, networkPolicy: networkPolicy,
            responsePolicy: responsePolicy, expectedSourceSHA256: expectedSourceSHA256,
            maximumTransferBytes: maximumTransferBytes
        )
        self.identifier = identifier
        self.remoteURL = remoteURL
        self.method = method
        self.operation = operation
        self.headers = headers
        self.metadata = metadata
        self.networkPolicy = networkPolicy
        self.responsePolicy = responsePolicy
        self.expectedSourceSHA256 = expectedSourceSHA256
        self.maximumTransferBytes = maximumTransferBytes
    }

    public var debugDescription: String {
        "RadrootsBackgroundTransferRequest(identifier: \(identifier.rawValue), method: \(method.rawValue), "
            + "operation: \(operation.redactedLabel), headers: <redacted>, metadataKeys: \(metadata.keys.sorted()), "
            + "maximumTransferBytes: \(maximumTransferBytes), responseBodyLimit: \(responsePolicy.maximumBodyBytes))"
    }

    func redactedForPersistence() throws -> Self {
        try Self(
            identifier: identifier, remoteURL: remoteURL, method: method, operation: operation,
            headers: [:], metadata: [:],
            networkPolicy: networkPolicy, responsePolicy: responsePolicy,
            expectedSourceSHA256: expectedSourceSHA256,
            maximumTransferBytes: maximumTransferBytes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case remoteURL
        case method
        case operation
        case metadata
        case networkPolicy
        case responsePolicy
        case expectedSourceSHA256
        case maximumTransferBytes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: values.decode(RadrootsBackgroundTransferIdentifier.self, forKey: .identifier),
            remoteURL: values.decode(URL.self, forKey: .remoteURL),
            method: values.decode(RadrootsBackgroundTransferMethod.self, forKey: .method),
            operation: values.decode(RadrootsBackgroundTransferOperation.self, forKey: .operation),
            headers: [:],
            metadata: values.decode([String: String].self, forKey: .metadata),
            networkPolicy: values.decodeIfPresent(
                RadrootsBackgroundTransferNetworkPolicy.self, forKey: .networkPolicy
            ) ?? .publicHTTPS,
            responsePolicy: values.decodeIfPresent(
                RadrootsBackgroundTransferResponsePolicy.self, forKey: .responsePolicy
            ) ?? .discard,
            expectedSourceSHA256: values.decodeIfPresent(String.self, forKey: .expectedSourceSHA256),
            maximumTransferBytes: values.decodeIfPresent(UInt64.self, forKey: .maximumTransferBytes)
                ?? Self.defaultMaximumTransferBytes
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(identifier, forKey: .identifier)
        try values.encode(remoteURL, forKey: .remoteURL)
        try values.encode(method, forKey: .method)
        try values.encode(operation, forKey: .operation)
        try values.encode(metadata, forKey: .metadata)
        try values.encode(networkPolicy, forKey: .networkPolicy)
        try values.encode(responsePolicy, forKey: .responsePolicy)
        try values.encodeIfPresent(expectedSourceSHA256, forKey: .expectedSourceSHA256)
        try values.encode(maximumTransferBytes, forKey: .maximumTransferBytes)
    }
}
