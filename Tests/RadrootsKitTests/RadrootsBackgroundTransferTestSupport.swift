import Darwin
import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

actor RadrootsAppleBackgroundTransferProbe {
    private let nowValue: Date
    private let enqueueOutcome: Result<Void, RadrootsBackgroundTransferError>
    private var activeIdentifiersValue: Set<RadrootsBackgroundTransferIdentifier>
    private var enqueuedRequestsValue: [RadrootsBackgroundTransferRequest]
    private var cancelledIdentifiersValue: [RadrootsBackgroundTransferIdentifier]
    private var handledBackgroundEventIdentifiersValue: [String]

    init(
        now: Date = Date(timeIntervalSince1970: 0),
        enqueueOutcome: Result<Void, RadrootsBackgroundTransferError> = .success(()),
        activeIdentifiers: Set<RadrootsBackgroundTransferIdentifier> = []
    ) {
        nowValue = now
        self.enqueueOutcome = enqueueOutcome
        activeIdentifiersValue = activeIdentifiers
        enqueuedRequestsValue = []
        cancelledIdentifiersValue = []
        handledBackgroundEventIdentifiersValue = []
    }

    nonisolated func adapters() -> RadrootsAppleBackgroundTransferAdapters {
        RadrootsAppleBackgroundTransferAdapters(
            now: { self.nowValue }, enqueue: { request, _ in try await self.enqueue(request) },
            cancel: { identifier in await self.cancel(identifier) },
            activeTransferIdentifiers: { await self.activeIdentifiers() },
            handleBackgroundEvents: { identifier, completionHandler in
                await self.handleBackgroundEvents(
                    identifier: identifier, completionHandler: completionHandler
                )
            }
        )
    }

    private func enqueue(_ request: RadrootsBackgroundTransferRequest) throws {
        enqueuedRequestsValue.append(request)
        switch enqueueOutcome {
        case .success: activeIdentifiersValue.insert(request.identifier)
        case let .failure(error): throw error
        }
    }

    private func cancel(_ identifier: RadrootsBackgroundTransferIdentifier) {
        cancelledIdentifiersValue.append(identifier)
        activeIdentifiersValue.remove(identifier)
    }

    private func activeIdentifiers() -> Set<RadrootsBackgroundTransferIdentifier> {
        activeIdentifiersValue
    }

    private func handleBackgroundEvents(
        identifier: String, completionHandler: @escaping @Sendable () -> Void
    ) {
        handledBackgroundEventIdentifiersValue.append(identifier)
        completionHandler()
    }

    var enqueuedRequests: [RadrootsBackgroundTransferRequest] {
        enqueuedRequestsValue
    }

    var cancelledIdentifiers: [RadrootsBackgroundTransferIdentifier] {
        cancelledIdentifiersValue
    }

    var handledBackgroundEventIdentifiers: [String] {
        handledBackgroundEventIdentifiersValue
    }
}

final class RadrootsCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completionCountValue = 0

    func markCompleted() {
        lock.lock()
        completionCountValue += 1
        lock.unlock()
    }

    var completed: Bool {
        completionCount > 0
    }

    var completionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completionCountValue
    }
}

final class RadrootsProtectedDataProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stateValue: RadrootsProtectedDataState

    init(state: RadrootsProtectedDataState) {
        stateValue = state
    }

    var state: RadrootsProtectedDataState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stateValue
        }
        set {
            lock.lock()
            stateValue = newValue
            lock.unlock()
        }
    }
}

func appleTransferRequest(identifier: String) throws -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier),
        remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .get,
        operation: .download(
            destination: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))
        )
    )
}

func appleUploadRequest(
    identifier: String,
    responsePolicy: RadrootsBackgroundTransferResponsePolicy = .discard,
    maximumTransferBytes: UInt64 = RadrootsBackgroundTransferRequest.defaultMaximumTransferBytes
) throws
    -> RadrootsBackgroundTransferRequest {
    try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier(identifier),
        remoteURL: URL(string: "https://radroots.org/\(identifier).json")!,
        method: .put,
        operation: .upload(
            source: .file(RadrootsFileReference(scope: .cache, relativePath: "\(identifier).json"))
        ),
        responsePolicy: responsePolicy, maximumTransferBytes: maximumTransferBytes
    )
}

func successfulHTTPResult() -> RadrootsBackgroundHTTPResult {
    RadrootsBackgroundHTTPResult(statusCode: 200, mediaType: nil, body: nil, bodyExceeded: false)
}

func appleTransferRoots() throws -> RadrootsAppleFileRoots {
    let unresolvedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "radroots-apple-background-transfer-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: false)
    guard let resolvedPointer = unresolvedRoot.path.withCString({ Darwin.realpath($0, nil) }) else {
        throw RadrootsBackgroundTransferError.persistenceFailure
    }
    defer { Darwin.free(resolvedPointer) }
    let root = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
    return try RadrootsAppleFileRoots(
        appIdentifier: "org.radroots.tests",
        dataRoot: root.appendingPathComponent("data", isDirectory: true),
        cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
}
