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
        case .invalidRequest(let message):
            message
        case .unavailable(let message):
            message
        case .transferFailure(let message):
            message
        case .persistenceFailure(let message):
            message
        }
    }
}

public struct RadrootsBackgroundTransferIdentifier: Sendable, Equatable, Hashable, Comparable, Codable {
    public let rawValue: String

    public init(_ value: String) throws {
        self.rawValue = try RadrootsBackgroundTransferValidation.normalizedIdentifier(value)
    }

    public static func generated() -> Self {
        Self(validatedRawValue: UUID().uuidString.lowercased())
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private init(validatedRawValue: String) {
        self.rawValue = validatedRawValue
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
}

public struct RadrootsBackgroundTransferRequest: Sendable, Equatable, Hashable, Codable {
    public let identifier: RadrootsBackgroundTransferIdentifier
    public let remoteURL: URL
    public let method: RadrootsBackgroundTransferMethod
    public let operation: RadrootsBackgroundTransferOperation
    public let headers: [String: String]
    public let metadata: [String: String]

    public init(
        identifier: RadrootsBackgroundTransferIdentifier = .generated(),
        remoteURL: URL,
        method: RadrootsBackgroundTransferMethod,
        operation: RadrootsBackgroundTransferOperation,
        headers: [String: String] = [:],
        metadata: [String: String] = [:]
    ) throws {
        try RadrootsBackgroundTransferValidation.validate(
            remoteURL: remoteURL,
            method: method,
            operation: operation,
            headers: headers,
            metadata: metadata
        )
        self.identifier = identifier
        self.remoteURL = remoteURL
        self.method = method
        self.operation = operation
        self.headers = headers
        self.metadata = metadata
    }
}

public struct RadrootsBackgroundTransferHandle: Sendable, Equatable, Hashable, Codable {
    public let identifier: RadrootsBackgroundTransferIdentifier
    public let request: RadrootsBackgroundTransferRequest

    public init(request: RadrootsBackgroundTransferRequest) {
        self.identifier = request.identifier
        self.request = request
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
                throw RadrootsBackgroundTransferError.invalidRequest("background transfer expected byte count cannot be less than transferred bytes")
            }
        }
        self.bytesTransferred = bytesTransferred
        self.totalBytesExpected = totalBytesExpected
    }

    public static let zero = RadrootsBackgroundTransferProgress(validatedBytesTransferred: 0, totalBytesExpected: nil)

    private init(validatedBytesTransferred: Int64, totalBytesExpected: Int64?) {
        self.bytesTransferred = validatedBytesTransferred
        self.totalBytesExpected = totalBytesExpected
    }
}

public struct RadrootsBackgroundTransferSnapshot: Sendable, Equatable, Hashable, Codable {
    public let identifier: RadrootsBackgroundTransferIdentifier
    public let request: RadrootsBackgroundTransferRequest
    public let state: RadrootsBackgroundTransferState
    public let progress: RadrootsBackgroundTransferProgress
    public let errorMessage: String?
    public let updatedAt: Date

    public init(
        request: RadrootsBackgroundTransferRequest,
        state: RadrootsBackgroundTransferState = .queued,
        progress: RadrootsBackgroundTransferProgress = .zero,
        errorMessage: String? = nil,
        updatedAt: Date = Date()
    ) throws {
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer updated date must be finite")
        }
        self.identifier = request.identifier
        self.request = request
        self.state = state
        self.progress = progress
        self.errorMessage = try RadrootsBackgroundTransferValidation.normalizedOptionalMessage(errorMessage)
        self.updatedAt = updatedAt
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
}

public protocol RadrootsBackgroundTransferFileResolver: Sendable {
    func resolve(_ file: RadrootsBackgroundTransferLocalFile) throws -> URL
}

public struct RadrootsAppleBackgroundTransferFileResolver: RadrootsBackgroundTransferFileResolver, Sendable {
    private let roots: RadrootsAppleFileRoots

    public init(roots: RadrootsAppleFileRoots) {
        self.roots = roots
    }

    public func resolve(_ file: RadrootsBackgroundTransferLocalFile) throws -> URL {
        switch file {
        case .file(let reference):
            try roots.resolvedURL(for: reference)
        case .stagedBlob(let blob):
            try roots.stagedBlobURL(for: blob)
        }
    }
}

public final class RadrootsAppleBackgroundTransferStore: RadrootsBackgroundTransferStore, @unchecked Sendable {
    private let roots: RadrootsAppleFileRoots
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(roots: RadrootsAppleFileRoots, fileManager: FileManager = .default) {
        self.roots = roots
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func loadSnapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        let url = try storeURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([RadrootsBackgroundTransferSnapshot].self, from: data)
            .sorted { left, right in
                left.identifier < right.identifier
            }
    }

    public func saveSnapshot(_ snapshot: RadrootsBackgroundTransferSnapshot) async throws {
        var snapshots = try await loadSnapshots()
        snapshots.removeAll { $0.identifier == snapshot.identifier }
        snapshots.append(snapshot)
        try write(snapshots.sorted { left, right in
            left.identifier < right.identifier
        })
    }

    public func removeSnapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws {
        var snapshots = try await loadSnapshots()
        snapshots.removeAll { $0.identifier == identifier }
        try write(snapshots)
    }

    public func removeAllSnapshots() async throws {
        let url = try storeURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func write(_ snapshots: [RadrootsBackgroundTransferSnapshot]) throws {
        let url = try storeURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(snapshots)
        try data.write(to: url, options: [.atomic])
    }

    private func storeURL() throws -> URL {
        try roots.resolvedURL(
            for: RadrootsFileReference(
                scope: .cache,
                relativePath: "background_transfers/transfers.json"
            )
        )
    }
}

public struct RadrootsUnavailableBackgroundTransfer: RadrootsBackgroundTransfer, Sendable {
    private let reason: String

    public init(reason: String = "background transfer is unavailable on this platform") {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = trimmedReason.isEmpty ? "background transfer is unavailable on this platform" : trimmedReason
    }

    public func enqueue(_ request: RadrootsBackgroundTransferRequest) async throws -> RadrootsBackgroundTransferHandle {
        throw RadrootsBackgroundTransferError.unavailable(reason)
    }

    public func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) async throws {
        throw RadrootsBackgroundTransferError.unavailable(reason)
    }

    public func snapshot(for identifier: RadrootsBackgroundTransferIdentifier) async throws -> RadrootsBackgroundTransferSnapshot? {
        throw RadrootsBackgroundTransferError.unavailable(reason)
    }

    public func snapshots() async throws -> [RadrootsBackgroundTransferSnapshot] {
        throw RadrootsBackgroundTransferError.unavailable(reason)
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
        guard trimmed.range(
            of: "^[a-z0-9][a-z0-9._-]*[a-z0-9]$|^[a-z0-9]$",
            options: .regularExpression
        ) != nil else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer identifier must use lowercase safe identifier characters")
        }
        guard !trimmed.contains("..") else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer identifier cannot contain empty path components")
        }
        return trimmed
    }

    public static func validate(
        remoteURL: URL,
        method: RadrootsBackgroundTransferMethod,
        operation: RadrootsBackgroundTransferOperation,
        headers: [String: String],
        metadata: [String: String]
    ) throws {
        try validate(remoteURL: remoteURL)
        try validate(method: method, operation: operation)
        try validate(headers: headers)
        try validate(metadata: metadata)
    }

    public static func normalizedOptionalMessage(_ value: String?) throws -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.count <= 240 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer message is too long")
        }
        guard doesNotContainControlCharacters(trimmed) else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer message cannot contain control characters")
        }
        return trimmed
    }

    private static func validate(remoteURL: URL) throws {
        guard let components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer remote URL must use https with a host and no credentials")
        }
    }

    private static func validate(
        method: RadrootsBackgroundTransferMethod,
        operation: RadrootsBackgroundTransferOperation
    ) throws {
        switch operation {
        case .download:
            guard method == .get else {
                throw RadrootsBackgroundTransferError.invalidRequest("background download transfers must use GET")
            }
        case .upload:
            guard method == .post || method == .put else {
                throw RadrootsBackgroundTransferError.invalidRequest("background upload transfers must use POST or PUT")
            }
        }
    }

    private static func validate(headers: [String: String]) throws {
        guard headers.count <= 32 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer header count is too large")
        }
        for (key, value) in headers {
            try validateSafeText(key, field: "background transfer header name", maximumLength: 80)
            try validateSafeText(value, field: "background transfer header value", maximumLength: 500)
        }
    }

    private static func validate(metadata: [String: String]) throws {
        guard metadata.count <= 32 else {
            throw RadrootsBackgroundTransferError.invalidRequest("background transfer metadata count is too large")
        }
        for (key, value) in metadata {
            try validateSafeText(key, field: "background transfer metadata key", maximumLength: 80)
            try validateSafeText(value, field: "background transfer metadata value", maximumLength: 500)
        }
    }

    private static func validateSafeText(_ value: String, field: String, maximumLength: Int) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsBackgroundTransferError.invalidRequest("\(field) must not be empty")
        }
        guard trimmed.count <= maximumLength else {
            throw RadrootsBackgroundTransferError.invalidRequest("\(field) is too long")
        }
        guard doesNotContainControlCharacters(trimmed) else {
            throw RadrootsBackgroundTransferError.invalidRequest("\(field) cannot contain control characters")
        }
    }

    private static func doesNotContainControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
