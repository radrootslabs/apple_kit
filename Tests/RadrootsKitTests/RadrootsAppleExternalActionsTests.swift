import Foundation
@testable import RadrootsKit
import Testing

@Test func appleExternalActionsOpensAppSettingsThroughAdapter() async throws {
    let settingsURL = try #require(URL(string: "app-settings:radroots"))
    let probe = RadrootsExternalActionAdapterProbe(appSettingsURL: settingsURL)
    let service = RadrootsAppleExternalActions(adapters: probe.adapters())

    let capability = await service.canOpen(.appSettings)
    try await service.open(RadrootsExternalActionRequest(destination: .appSettings))

    #expect(capability.destination == .appSettings)
    #expect(capability.canOpen)
    #expect(await probe.canOpenURLs == [settingsURL])
    #expect(await probe.openedURLs == [settingsURL])
}

@Test func appleExternalActionsReportsUnavailableAppSettingsWithoutAPlatformUrl() async {
    let probe = RadrootsExternalActionAdapterProbe(appSettingsURL: nil)
    let service = RadrootsAppleExternalActions(adapters: probe.adapters())

    let capability = await service.canOpen(.appSettings)

    #expect(!capability.canOpen)
    await #expect(throws: RadrootsExternalActionError.unavailable("appSettings external action is unavailable")) {
        try await service.open(RadrootsExternalActionRequest(destination: .appSettings))
    }
    #expect(await probe.canOpenURLs.isEmpty)
    #expect(await probe.openedURLs.isEmpty)
}

@Test func appleExternalActionsMapsPlatformOpenFailure() async throws {
    let destination = try RadrootsExternalActionDestination.web("https://radroots.org")
    let url = try #require(destination.url)
    let probe = RadrootsExternalActionAdapterProbe(openResult: false)
    let service = RadrootsAppleExternalActions(adapters: probe.adapters())

    await #expect(throws: RadrootsExternalActionError.transientFailure("failed to open web external action")) {
        try await service.open(RadrootsExternalActionRequest(destination: destination))
    }

    #expect(await probe.openedURLs == [url])
}

@Test func appleExternalActionsChecksExternalDestinationCapabilities() async throws {
    let destination = try RadrootsExternalActionDestination.nostr("nostr:npub1qqqqqq")
    let url = try #require(destination.url)
    let probe = RadrootsExternalActionAdapterProbe(canOpenResult: false)
    let service = RadrootsAppleExternalActions(adapters: probe.adapters())

    let capability = await service.canOpen(destination)

    #expect(capability.destination == destination)
    #expect(!capability.canOpen)
    #expect(await probe.canOpenURLs == [url])
}

private actor RadrootsExternalActionAdapterProbe {
    private let appSettingsURLValue: URL?
    private let canOpenResult: Bool
    private let openResult: Bool
    private var canOpenURLsValue: [URL]
    private var openedURLsValue: [URL]

    init(
        appSettingsURL: URL? = URL(string: "app-settings:radroots"),
        canOpenResult: Bool = true,
        openResult: Bool = true
    ) {
        appSettingsURLValue = appSettingsURL
        self.canOpenResult = canOpenResult
        self.openResult = openResult
        canOpenURLsValue = []
        openedURLsValue = []
    }

    nonisolated func adapters() -> RadrootsAppleExternalActionsAdapters {
        RadrootsAppleExternalActionsAdapters(
            appSettingsURL: {
                await self.appSettingsURL()
            },
            canOpenURL: { url in
                await self.canOpen(url)
            },
            openURL: { url in
                await self.open(url)
            }
        )
    }

    private func appSettingsURL() -> URL? {
        appSettingsURLValue
    }

    private func canOpen(_ url: URL) -> Bool {
        canOpenURLsValue.append(url)
        return canOpenResult
    }

    private func open(_ url: URL) -> Bool {
        openedURLsValue.append(url)
        return openResult
    }

    var canOpenURLs: [URL] {
        canOpenURLsValue
    }

    var openedURLs: [URL] {
        openedURLsValue
    }
}
