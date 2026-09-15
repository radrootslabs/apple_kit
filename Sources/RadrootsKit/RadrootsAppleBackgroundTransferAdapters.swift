import Foundation

public struct RadrootsAppleBackgroundTransferAdapters: Sendable {
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
                    #if targetEnvironment(simulator)
                        if request.networkPolicy == .simulatorLoopbackHTTP {
                            try await simulatorSession.enqueue(request, executionID: executionID)
                            return
                        }
                    #endif
                    try await session.enqueue(request, executionID: executionID)
                },
                cancel: { identifier in
                    #if targetEnvironment(simulator)
                        await simulatorSession.cancel(identifier)
                    #endif
                    await session.cancel(identifier)
                },
                activeTransferIdentifiers: {
                    var identifiers = await session.activeTransferIdentifiers()
                    #if targetEnvironment(simulator)
                        await identifiers.formUnion(simulatorSession.activeTransferIdentifiers())
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
