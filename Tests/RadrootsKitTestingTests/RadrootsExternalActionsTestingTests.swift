import Foundation
import Testing
import RadrootsKit
import RadrootsKitTesting

@Test func fakeExternalActionsRecordsCapabilityAndOpenRequests() async throws {
    let web = try RadrootsExternalActionDestination.web("https://radroots.org")
    let nostr = try RadrootsExternalActionDestination.nostr("nostr:npub1qqqqqq")
    let actions = RadrootsFakeExternalActions(
        capabilityOverrides: [nostr: false],
        defaultCanOpen: true
    )

    #expect(await actions.canOpen(web).canOpen)
    #expect(!(await actions.canOpen(nostr).canOpen))
    try await actions.open(RadrootsExternalActionRequest(destination: web))

    #expect(await actions.capabilityRequestCount == 2)
    #expect(await actions.openRequestCount == 1)
    #expect(await actions.lastCapabilityDestination == nostr)
    #expect(await actions.lastOpenedDestination == web)
    #expect(await actions.openedDestinations == [web])
}

@Test func fakeExternalActionsReturnsConfiguredFailures() async throws {
    let destination = RadrootsExternalActionDestination.appSettings
    let actions = RadrootsFakeExternalActions(
        openOutcome: .failure(.unavailable("external actions unavailable"))
    )

    await #expect(throws: RadrootsExternalActionError.unavailable("external actions unavailable")) {
        try await actions.open(RadrootsExternalActionRequest(destination: destination))
    }

    #expect(await actions.openRequestCount == 1)
    #expect(await actions.lastOpenedDestination == destination)
}
