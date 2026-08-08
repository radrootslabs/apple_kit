import Foundation

#if canImport(AppKit)
    @preconcurrency import AppKit
#endif

#if canImport(UIKit)
    @preconcurrency import UIKit
#endif

public struct RadrootsAppleExternalActionsAdapters: Sendable {
    public let appSettingsURL: @Sendable () async -> URL?
    public let canOpenURL: @Sendable (URL) async -> Bool
    public let openURL: @Sendable (URL) async -> Bool

    public init(
        appSettingsURL: @escaping @Sendable () async -> URL?,
        canOpenURL: @escaping @Sendable (URL) async -> Bool,
        openURL: @escaping @Sendable (URL) async -> Bool
    ) {
        self.appSettingsURL = appSettingsURL
        self.canOpenURL = canOpenURL
        self.openURL = openURL
    }

    public static var live: Self {
        #if canImport(UIKit)
            Self(
                appSettingsURL: {
                    await MainActor.run {
                        URL(string: UIApplication.openSettingsURLString)
                    }
                },
                canOpenURL: { url in
                    await MainActor.run {
                        UIApplication.shared.canOpenURL(url)
                    }
                },
                openURL: { url in
                    await Self.openUIKitURL(url)
                }
            )
        #elseif canImport(AppKit)
            Self(
                appSettingsURL: {
                    nil
                },
                canOpenURL: { url in
                    await MainActor.run {
                        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
                    }
                },
                openURL: { url in
                    await MainActor.run {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        #else
            Self(
                appSettingsURL: {
                    nil
                },
                canOpenURL: { _ in
                    false
                },
                openURL: { _ in
                    false
                }
            )
        #endif
    }
}

public final class RadrootsAppleExternalActions: RadrootsExternalActions, Sendable {
    private let adapters: RadrootsAppleExternalActionsAdapters

    public init(adapters: RadrootsAppleExternalActionsAdapters = .live) {
        self.adapters = adapters
    }

    public func canOpen(_ destination: RadrootsExternalActionDestination) async -> RadrootsExternalActionCapability {
        let url = await resolvedURL(for: destination)
        guard let url else {
            return RadrootsExternalActionCapability(destination: destination, canOpen: false)
        }
        let canOpen = await adapters.canOpenURL(url)
        return RadrootsExternalActionCapability(
            destination: destination,
            canOpen: canOpen
        )
    }

    public func open(_ request: RadrootsExternalActionRequest) async throws {
        guard let url = await resolvedURL(for: request.destination) else {
            throw RadrootsExternalActionError.unavailable(
                "\(request.destination.kind.rawValue) external action is unavailable"
            )
        }
        let success = await adapters.openURL(url)
        guard success else {
            throw RadrootsExternalActionError.transientFailure(
                "failed to open \(request.destination.kind.rawValue) external action"
            )
        }
    }

    private func resolvedURL(for destination: RadrootsExternalActionDestination) async -> URL? {
        switch destination.kind {
        case .appSettings:
            await adapters.appSettingsURL()
        case .web, .nostr, .appleMaps:
            destination.url
        }
    }
}

#if canImport(UIKit)
    private extension RadrootsAppleExternalActionsAdapters {
        @MainActor
        static func openUIKitURL(_ url: URL) async -> Bool {
            await withCheckedContinuation { continuation in
                UIApplication.shared.open(url, options: [:]) { success in
                    continuation.resume(returning: success)
                }
            }
        }
    }
#endif
