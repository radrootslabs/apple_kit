import Foundation

public enum RadrootsBackgroundTransferError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case unavailable(String)
    case transferFailure(String)
    case persistenceFailure(String)
}

extension RadrootsBackgroundTransferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message): message
        case let .unavailable(message): message
        case let .transferFailure(message): message
        case let .persistenceFailure(message): message
        }
    }
}

public struct RadrootsBackgroundTransferIdentifier: Sendable, Equatable, Hashable, Comparable, Codable {
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

public enum RadrootsBackgroundTransferMethod: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
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

public enum RadrootsBackgroundTransferState: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case interrupted
}

public enum RadrootsBackgroundTransferNetworkPolicy: String, Sendable, Equatable, Hashable, Codable {
    case publicHTTPS
    case simulatorLoopbackHTTP
}

public struct RadrootsBackgroundTransferResponsePolicy: Sendable, Equatable, Hashable, Codable {
    public let maximumBodyBytes: Int
    public let acceptedMediaTypes: [String]

    public init(maximumBodyBytes: Int = 0, acceptedMediaTypes: [String] = []) throws {
        guard (0 ... 65536).contains(maximumBodyBytes), acceptedMediaTypes.count <= 8 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer response policy is invalid")
        }
        let normalized = try acceptedMediaTypes.map { try RadrootsBackgroundTransferValidation.normalizedMediaType($0) }
        guard Set(normalized).count == normalized.count, (maximumBodyBytes == 0) == normalized.isEmpty else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer response policy is invalid")
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
    public let body: Data?

    public init(statusCode: Int, mediaType: String?, body: Data?) throws {
        guard (100 ... 599).contains(statusCode), body?.count ?? 0 <= 65536 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer response is invalid")
        }
        self.statusCode = statusCode
        self.mediaType = try mediaType.map { try RadrootsBackgroundTransferValidation.normalizedMediaType($0) }
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case statusCode
        case mediaType
        case body
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            statusCode: values.decode(Int.self, forKey: .statusCode), mediaType: values.decodeIfPresent(String.self, forKey: .mediaType),
            body: values.decodeIfPresent(Data.self, forKey: .body)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(statusCode, forKey: .statusCode)
        try values.encodeIfPresent(mediaType, forKey: .mediaType)
        try values.encodeIfPresent(body, forKey: .body)
    }
}

public struct RadrootsBackgroundTransferRequest: Sendable, Equatable, Hashable, Codable, CustomDebugStringConvertible {
    public let identifier: RadrootsBackgroundTransferIdentifier
    public let remoteURL: URL
    public let method: RadrootsBackgroundTransferMethod
    public let operation: RadrootsBackgroundTransferOperation
    public let headers: [String: String]
    public let metadata: [String: String]
    public let networkPolicy: RadrootsBackgroundTransferNetworkPolicy
    public let responsePolicy: RadrootsBackgroundTransferResponsePolicy
    public let expectedSourceSHA256: String?

    public init(
        identifier: RadrootsBackgroundTransferIdentifier = .generated(), remoteURL: URL, method: RadrootsBackgroundTransferMethod,
        operation: RadrootsBackgroundTransferOperation, headers: [String: String] = [:], metadata: [String: String] = [:],
        networkPolicy: RadrootsBackgroundTransferNetworkPolicy = .publicHTTPS,
        responsePolicy: RadrootsBackgroundTransferResponsePolicy = .discard, expectedSourceSHA256: String? = nil
    ) throws {
        try RadrootsBackgroundTransferValidation.validate(
            remoteURL: remoteURL, method: method, operation: operation, headers: headers, metadata: metadata, networkPolicy: networkPolicy,
            responsePolicy: responsePolicy, expectedSourceSHA256: expectedSourceSHA256
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
    }

    public var debugDescription: String {
        "RadrootsBackgroundTransferRequest(identifier: \(identifier.rawValue), method: \(method.rawValue), operation: \(operation.redactedLabel), headers: <redacted>, metadataKeys: \(metadata.keys.sorted()), responseBodyLimit: \(responsePolicy.maximumBodyBytes))"
    }

    func redactedForPersistence() throws -> Self {
        try Self(
            identifier: identifier, remoteURL: remoteURL, method: method, operation: operation, headers: [:], metadata: [:],
            networkPolicy: networkPolicy, responsePolicy: responsePolicy, expectedSourceSHA256: expectedSourceSHA256
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
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: values.decode(RadrootsBackgroundTransferIdentifier.self, forKey: .identifier),
            remoteURL: values.decode(URL.self, forKey: .remoteURL),
            method: values.decode(RadrootsBackgroundTransferMethod.self, forKey: .method),
            operation: values.decode(RadrootsBackgroundTransferOperation.self, forKey: .operation), headers: [:],
            metadata: values.decode([String: String].self, forKey: .metadata),
            networkPolicy: values.decodeIfPresent(RadrootsBackgroundTransferNetworkPolicy.self, forKey: .networkPolicy) ?? .publicHTTPS,
            responsePolicy: values.decodeIfPresent(RadrootsBackgroundTransferResponsePolicy.self, forKey: .responsePolicy) ?? .discard,
            expectedSourceSHA256: values.decodeIfPresent(String.self, forKey: .expectedSourceSHA256)
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
    }
}

public struct RadrootsBackgroundTransferHandle: Sendable, Equatable, Hashable, Codable, CustomDebugStringConvertible {
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
        let identifier = try values.decode(RadrootsBackgroundTransferIdentifier.self, forKey: .identifier)
        let request = try values.decode(RadrootsBackgroundTransferRequest.self, forKey: .request)
        guard identifier == request.identifier else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer handle identifier does not match its request")
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
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer bytes transferred cannot be negative")
        }
        if let totalBytesExpected {
            guard totalBytesExpected >= 0 else {
                throw RadrootsBackgroundTransferError.invalidRequest("background transfer expected byte count cannot be negative")
            }
            guard totalBytesExpected >= bytesTransferred else {
                throw RadrootsBackgroundTransferError.invalidRequest(
                    "background transfer expected byte count cannot be less than transferred bytes"
                )
            }
        }
        self.bytesTransferred = bytesTransferred
        self.totalBytesExpected = totalBytesExpected
    }

    public static let zero = RadrootsBackgroundTransferProgress(validatedBytesTransferred: 0, totalBytesExpected: nil)

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

public struct RadrootsBackgroundTransferSnapshot: Sendable, Equatable, Hashable, Codable, CustomDebugStringConvertible {
    public let identifier: RadrootsBackgroundTransferIdentifier
    public let request: RadrootsBackgroundTransferRequest
    public let state: RadrootsBackgroundTransferState
    public let progress: RadrootsBackgroundTransferProgress
    public let errorMessage: String?
    public let response: RadrootsBackgroundTransferResponse?
    public let possibleRemoteOrphan: Bool
    public let updatedAt: Date

    public init(
        request: RadrootsBackgroundTransferRequest, state: RadrootsBackgroundTransferState = .queued,
        progress: RadrootsBackgroundTransferProgress = .zero, errorMessage: String? = nil,
        response: RadrootsBackgroundTransferResponse? = nil, possibleRemoteOrphan: Bool = false, updatedAt: Date = Date()
    ) throws {
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer updated date must be finite")
        }
        guard response == nil || state == .completed else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer response requires completed state")
        }
        if let response {
            try RadrootsBackgroundTransferValidation.validate(response: response, policy: request.responsePolicy)
        }
        if possibleRemoteOrphan {
            guard case .upload = request.operation, state == .failed || state == .interrupted else {
                throw RadrootsBackgroundTransferError.invalidRequest("background transfer orphan marker is invalid")
            }
        }
        identifier = request.identifier
        self.request = request
        self.state = state
        self.progress = progress
        self.errorMessage = try RadrootsBackgroundTransferValidation.normalizedOptionalMessage(errorMessage)
        self.response = response
        self.possibleRemoteOrphan = possibleRemoteOrphan
        self.updatedAt = updatedAt
    }

    public var debugDescription: String {
        let statusCode = response?.statusCode.description ?? "none"
        return
            "RadrootsBackgroundTransferSnapshot(identifier: \(identifier.rawValue), state: \(state.rawValue), bytesTransferred: \(progress.bytesTransferred), statusCode: \(statusCode), possibleRemoteOrphan: \(possibleRemoteOrphan))"
    }

    func redactedForPersistence() throws -> Self {
        try Self(
            request: request.redactedForPersistence(), state: state, progress: progress, errorMessage: errorMessage, response: response,
            possibleRemoteOrphan: possibleRemoteOrphan, updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case request
        case state
        case progress
        case errorMessage
        case response
        case possibleRemoteOrphan
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            request: values.decode(RadrootsBackgroundTransferRequest.self, forKey: .request),
            state: values.decode(RadrootsBackgroundTransferState.self, forKey: .state),
            progress: values.decode(RadrootsBackgroundTransferProgress.self, forKey: .progress),
            errorMessage: values.decodeIfPresent(String.self, forKey: .errorMessage),
            response: values.decodeIfPresent(RadrootsBackgroundTransferResponse.self, forKey: .response),
            possibleRemoteOrphan: values.decodeIfPresent(Bool.self, forKey: .possibleRemoteOrphan) ?? false,
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request, forKey: .request)
        try values.encode(state, forKey: .state)
        try values.encode(progress, forKey: .progress)
        try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try values.encodeIfPresent(response, forKey: .response)
        try values.encode(possibleRemoteOrphan, forKey: .possibleRemoteOrphan)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

public protocol RadrootsBackgroundTransferStore: Sendable {
    func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot]
    func saveSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws
    func removeSnapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws
    func removeAllSnapshots() async throws
}

public protocol RadrootsBackgroundTransfer: Sendable {
    func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws -> RadrootsBackgroundTransferHandle
    func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws
    func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> RadrootsBackgroundTransferSnapshot?
    func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot]
    func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping @Sendable () -> Void) async
}

public protocol RadrootsBackgroundTransferFileResolver: Sendable { func resolve(_ file: RadrootsBackgroundTransferLocalFile) throws -> URL }

public struct RadrootsAppleBackgroundTransferFileResolver: RadrootsBackgroundTransferFileResolver, Sendable {
    private let roots: RadrootsAppleFileRoots

    public init(roots: RadrootsAppleFileRoots) {
        self.roots = roots
    }

    public func resolve(_ file: RadrootsBackgroundTransferLocalFile) throws -> URL {
        let candidate: URL
        let root: URL
        switch file {
        case let .file(reference):
            candidate = try roots.resolvedURL(for: reference)
            root = roots.root(for: reference.scope)
        case let .stagedBlob(blob):
            candidate = try roots.stagedBlobURL(for: blob)
            root = roots.stagedBlobsRoot
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer local file resolved outside its root")
        }
        return candidate
    }
}

public actor RadrootsAppleBackgroundTransferStore: RadrootsBackgroundTransferStore {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let snapshots: [RadrootsBackgroundTransferSnapshot]

        init(snapshots: [RadrootsBackgroundTransferSnapshot]) {
            schemaVersion = 1
            self.snapshots = snapshots
        }
    }

    private let roots: RadrootsAppleFileRoots
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let protectedData: RadrootsProtectedDataProvider

    public init(
        roots: RadrootsAppleFileRoots, fileManager: FileManager = .default, protectedData: RadrootsProtectedDataProvider = .available
    ) {
        self.roots = roots
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.protectedData = protectedData
        encoder.outputFormatting = [.sortedKeys]
    }

    public func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        try requireProtectedData()
        do {
            let url = try storeURL()
            let legacyURL = try legacyStoreURL()
            let sourceURL: URL
            let isLegacy: Bool
            if fileManager.fileExists(atPath: url.path) {
                sourceURL = url
                isLegacy = false
            } else if fileManager.fileExists(atPath: legacyURL.path) {
                sourceURL = legacyURL
                isLegacy = true
            } else {
                return []
            }
            let data = try Data(contentsOf: sourceURL)
            let decoded: [RadrootsBackgroundTransferSnapshot]
            let usedLegacyEncoding: Bool
            if let envelope = try? decoder.decode(Envelope.self, from: data) {
                guard envelope.schemaVersion == 1 else {
                    throw RadrootsBackgroundTransferError.persistenceFailure("background transfer persistence version is unsupported")
                }
                decoded = envelope.snapshots
                usedLegacyEncoding = false
            } else {
                decoded = try decoder.decode([RadrootsBackgroundTransferSnapshot].self, from: data)
                usedLegacyEncoding = true
            }
            let snapshots = try decoded.map { try $0.redactedForPersistence() }.sorted { left, right in left.identifier < right.identifier }
            if isLegacy || usedLegacyEncoding {
                try write(snapshots)
            }
            if fileManager.fileExists(atPath: legacyURL.path) {
                try fileManager.removeItem(at: legacyURL)
            }
            return snapshots
        } catch { throw RadrootsBackgroundTransferError.persistenceFailure("background transfer persistence could not be read") }
    }

    public func saveSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws {
        try requireProtectedData()
        do {
            var snapshots = try await loadSnapshots()
            snapshots.removeAll { $0.identifier == snapshot.identifier }
            try snapshots.append(snapshot.redactedForPersistence())
            try write(snapshots.sorted { left, right in left.identifier < right.identifier })
        } catch let error as RadrootsBackgroundTransferError { throw error } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure("background transfer persistence could not be written")
        }
    }

    public func removeSnapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws {
        try requireProtectedData()
        do {
            var snapshots = try await loadSnapshots()
            snapshots.removeAll { $0.identifier == identifier }
            try write(snapshots)
        } catch let error as RadrootsBackgroundTransferError { throw error } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure("background transfer persistence could not be written")
        }
    }

    public func removeAllSnapshots() async throws {
        try requireProtectedData()
        do {
            for url in try [storeURL(), legacyStoreURL()] where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch let error as RadrootsBackgroundTransferError { throw error } catch {
            throw RadrootsBackgroundTransferError.persistenceFailure("background transfer persistence could not be removed")
        }
    }

    private func write(_ snapshots: [RadrootsBackgroundTransferSnapshot]) throws {
        let url = try storeURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(Envelope(snapshots: snapshots))
        try data.write(to: url, options: [.atomic])
        #if os(iOS)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private func storeURL() throws -> URL {
        try roots.resolvedURL(for: RadrootsFileReference(scope: .data, relativePath: "background_transfers/transfers.json"))
    }

    private func legacyStoreURL() throws -> URL {
        try roots.resolvedURL(for: RadrootsFileReference(scope: .cache, relativePath: "background_transfers/transfers.json"))
    }

    private func requireProtectedData() throws {
        guard protectedData.currentState() == .available else {
            throw RadrootsBackgroundTransferError.persistenceFailure("background transfer protected data is unavailable")
        }
    }
}

public struct RadrootsUnavailableBackgroundTransfer: RadrootsBackgroundTransfer, Sendable {
    private let reason: String

    public init(reason: String = "background transfer is unavailable on this platform") {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = trimmedReason.isEmpty ? "background transfer is unavailable on this platform" : trimmedReason
    }

    public func enqueue(_: RadrootsBackgroundTransferRequest) async throws -> RadrootsBackgroundTransferHandle {
        throw RadrootsBackgroundTransferError.unavailable(reason)
    }

    public func cancel(_: RadrootsBackgroundTransferIdentifier) async throws {
        throw RadrootsBackgroundTransferError.unavailable(reason)
    }

    public func snapshot(for _: RadrootsBackgroundTransferIdentifier) async throws -> RadrootsBackgroundTransferSnapshot? {
        throw RadrootsBackgroundTransferError.unavailable(reason)
    }

    public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        throw RadrootsBackgroundTransferError.unavailable(reason)
    }

    public func handleEventsForBackgroundURLSession(identifier _: String, completionHandler: @escaping @Sendable () -> Void) async {
        completionHandler()
    }
}

public enum RadrootsBackgroundTransferValidation {
    public static func normalizedIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer identifier must not be empty")
        }
        guard trimmed.count <= 128 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer identifier is too long")
        }
        guard trimmed.range(of: "^[a-z0-9][a-z0-9._-]*[a-z0-9]$|^[a-z0-9]$", options: .regularExpression) != nil else {
            throw RadrootsBackgroundTransferError.invalidRequest(
                "background transfer identifier must use lowercase safe identifier characters"
            )
        }
        guard !trimmed.contains("..") else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer identifier cannot contain empty path components")
        }
        return trimmed
    }

    public static func validate(
        remoteURL: URL, method: RadrootsBackgroundTransferMethod, operation: RadrootsBackgroundTransferOperation, headers: [String: String],
        metadata: [String: String], networkPolicy: RadrootsBackgroundTransferNetworkPolicy,
        responsePolicy: RadrootsBackgroundTransferResponsePolicy, expectedSourceSHA256: String?
    ) throws {
        try validate(remoteURL: remoteURL, networkPolicy: networkPolicy)
        try validate(method: method, operation: operation)
        try validate(headers: headers)
        try validate(metadata: metadata)
        if case .download = operation, responsePolicy != .discard {
            throw RadrootsBackgroundTransferError.invalidRequest("background downloads must discard the separate response body")
        }
        if let expectedSourceSHA256 {
            guard case .upload = operation, expectedSourceSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw RadrootsBackgroundTransferError.invalidRequest("background transfer source digest is invalid")
            }
        }
    }

    public static func normalizedOptionalMessage(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 240 else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer message is too long") }
        guard doesNotContainControlCharacters(trimmed) else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer message cannot contain control characters")
        }
        return trimmed
    }

    private static func validate(remoteURL: URL, networkPolicy: RadrootsBackgroundTransferNetworkPolicy) throws {
        guard let components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false),
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil
        else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer remote URL is unsafe") }
        let scheme = components.scheme?.lowercased()
        switch networkPolicy {
        case .publicHTTPS:
            guard scheme == "https" else {
                throw RadrootsBackgroundTransferError.invalidRequest("background transfer remote URL must use public HTTPS")
            }
        case .simulatorLoopbackHTTP:
            #if os(iOS) && !targetEnvironment(simulator)
                throw RadrootsBackgroundTransferError.invalidRequest("background transfer simulator policy is unavailable on this device")
            #else
                guard scheme == "http", let host = components.host?.lowercased(),
                      host == "localhost" || host == "127.0.0.1" || host == "::1"
                else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer simulator URL must use loopback HTTP") }
            #endif
        }
    }

    private static func validate(method: RadrootsBackgroundTransferMethod, operation: RadrootsBackgroundTransferOperation) throws {
        switch operation {
        case let .download(destination):
            guard method == .get else { throw RadrootsBackgroundTransferError.invalidRequest("background download transfers must use GET") }
            try validateLocalFile(destination)
        case let .upload(source):
            guard method == .post || method == .put else {
                throw RadrootsBackgroundTransferError.invalidRequest("background upload transfers must use POST or PUT")
            }
            try validateLocalFile(source)
        }
    }

    static func validateLocalFile(_ localFile: RadrootsBackgroundTransferLocalFile) throws {
        switch localFile {
        case let .file(reference):
            let path = reference.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !NSString(string: path).isAbsolutePath,
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." })
            else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer local file is unsafe") }
        case let .stagedBlob(blob):
            guard
                (try? RadrootsStagedBlobReference(
                    blobID: blob.blobID, sizeBytes: blob.sizeBytes, mediaType: blob.mediaType, filenameHint: blob.filenameHint
                )) != nil
            else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer staged blob is invalid") }
        }
    }

    private static func validate(headers: [String: String]) throws {
        guard headers.count <= 32 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer header count is too large")
        }
        for (key, value) in headers {
            try validateSafeText(key, field: "background transfer header name", maximumLength: 80)
            guard key.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                  !["connection", "content-length", "host", "transfer-encoding"].contains(key.lowercased())
            else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer header name is unsafe") }
            try validateSafeText(value, field: "background transfer header value", maximumLength: 8192)
        }
    }

    private static func validate(metadata: [String: String]) throws {
        guard metadata.count <= 32 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer metadata count is too large")
        }
        for (key, value) in metadata {
            try validateSafeText(key, field: "background transfer metadata key", maximumLength: 80)
            try validateSafeText(value, field: "background transfer metadata value", maximumLength: 500)
            let unsafeKey = key.lowercased()
            guard !["auth", "token", "secret", "credential", "cookie", "header", "path", "url"].contains(where: { unsafeKey.contains($0) })
            else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer metadata key is sensitive") }
        }
    }

    static func normalizedMediaType(_ value: String) throws -> String {
        let normalized = value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard normalized.range(of: "^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$", options: .regularExpression) != nil,
              normalized.utf8.count <= 127
        else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer media type is invalid") }
        return normalized
    }

    static func validate(response: RadrootsBackgroundTransferResponse, policy: RadrootsBackgroundTransferResponsePolicy) throws {
        guard (200 ... 299).contains(response.statusCode) else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer response status is invalid")
        }
        if policy.maximumBodyBytes == 0 {
            guard response.body == nil, response.mediaType == nil else {
                throw RadrootsBackgroundTransferError.invalidRequest("background transfer response body is not permitted")
            }
            return
        }
        guard let body = response.body, body.count <= policy.maximumBodyBytes, let mediaType = response.mediaType,
              policy.acceptedMediaTypes.contains(mediaType)
        else { throw RadrootsBackgroundTransferError.invalidRequest("background transfer response violates its policy") }
    }

    private static func validateSafeText(_ value: String, field: String, maximumLength: Int) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RadrootsBackgroundTransferError.invalidRequest("\(field) must not be empty") }
        guard trimmed.count <= maximumLength else { throw RadrootsBackgroundTransferError.invalidRequest("\(field) is too long") }
        guard doesNotContainControlCharacters(trimmed) else {
            throw RadrootsBackgroundTransferError.invalidRequest("\(field) cannot contain control characters")
        }
    }

    private static func doesNotContainControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

private extension RadrootsBackgroundTransferOperation {
    var redactedLabel: String {
        switch self {
        case .download: "download"
        case .upload: "upload"
        }
    }
}
