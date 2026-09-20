import Foundation

public struct RadrootsAppleBackgroundTransferAdapters: Sendable {
    /// System-managed background sessions cannot establish the required
    /// redirect/connect guarantee. Keep their legacy recovery operational,
    /// and route new public work through the host's shared foreground uploader.
    public static func supportsNewEnqueue(for policy: RadrootsBackgroundTransferNetworkPolicy) -> Bool {
        #if os(iOS) && targetEnvironment(simulator)
            policy == .simulatorLoopbackHTTP
        #else
            false
        #endif
    }

    public let now: @Sendable () -> Date
    public let enqueue: @Sendable (RadrootsBackgroundTransferRequest, UUID) async throws -> Void
    public let cancel: @Sendable (RadrootsBackgroundTransferIdentifier) async throws -> Void
    public let activeTransferIdentifiers: @Sendable () async throws -> Set<RadrootsBackgroundTransferIdentifier>
    public let handleBackgroundEvents: @Sendable (String, @escaping @Sendable () -> Void) async -> Void

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        enqueue: @escaping @Sendable (RadrootsBackgroundTransferRequest, UUID) async throws -> Void,
        cancel: @escaping @Sendable (RadrootsBackgroundTransferIdentifier) async throws -> Void,
        activeTransferIdentifiers:
        @escaping @Sendable () async throws -> Set<RadrootsBackgroundTransferIdentifier>,
        handleBackgroundEvents:
        @escaping @Sendable (String, @escaping @Sendable () -> Void) async -> Void
    ) {
        self.now = now
        self.enqueue = enqueue
        self.cancel = cancel
        self.activeTransferIdentifiers = activeTransferIdentifiers
        self.handleBackgroundEvents = handleBackgroundEvents
    }

    public static let unavailable = Self(
        enqueue: { _, _ in
            throw RadrootsBackgroundTransferError.unavailable
        },
        cancel: { _ in
            throw RadrootsBackgroundTransferError.unavailable
        },
        activeTransferIdentifiers: {
            throw RadrootsBackgroundTransferError.unavailable
        }, handleBackgroundEvents: { _, completionHandler in completionHandler() }
    )

    public static func live(
        sessionIdentifier: String, store: any RadrootsBackgroundTransferStore,
        fileResolver: any RadrootsBackgroundTransferFileResolver,
        downloadStagingRoot: URL, now: @escaping @Sendable () -> Date = Date.init
    ) throws -> Self {
        #if os(iOS)
            let normalizedSessionIdentifier =
                try RadrootsBackgroundTransferValidation.normalizedIdentifier(sessionIdentifier)
            let session = RadrootsAppleBackgroundURLSession(
                identifier: normalizedSessionIdentifier, store: store, fileResolver: fileResolver,
                downloadStagingRoot: downloadStagingRoot,
                now: now
            )
            #if targetEnvironment(simulator)
                let simulatorSession = RadrootsAppleBackgroundURLSession(
                    identifier: normalizedSessionIdentifier, store: store, fileResolver: fileResolver,
                    downloadStagingRoot: downloadStagingRoot,
                    now: now, usesForegroundSession: true
                )
            #endif
            return Self(
                now: now,
                enqueue: { request, executionID in
                    guard Self.supportsNewEnqueue(for: request.networkPolicy) else {
                        throw RadrootsBackgroundTransferError.unavailable
                    }
                    #if targetEnvironment(simulator)
                        try await simulatorSession.enqueue(request, executionID: executionID)
                    #else
                        throw RadrootsBackgroundTransferError.unavailable
                    #endif
                },
                cancel: { identifier in
                    #if targetEnvironment(simulator)
                        try await simulatorSession.cancel(identifier)
                    #endif
                    try await session.cancel(identifier)
                },
                activeTransferIdentifiers: {
                    var identifiers = try await session.activeTransferIdentifiers()
                    #if targetEnvironment(simulator)
                        try await identifiers.formUnion(simulatorSession.activeTransferIdentifiers())
                    #endif
                    return identifiers
                },
                handleBackgroundEvents: { identifier, completionHandler in
                    await session.handleBackgroundEvents(
                        identifier: identifier, completionHandler: completionHandler
                    )
                }
            )
        #else
            return .unavailable
        #endif
    }
}
