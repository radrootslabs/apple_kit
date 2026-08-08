import Foundation
@testable import RadrootsKit
import Testing

@Test func webDestinationAcceptsOnlyHttpsUrlsWithHosts() throws {
    let destination = try RadrootsExternalActionDestination.web(" https://radroots.org/field ")

    #expect(destination.kind == .web)
    #expect(destination.url?.absoluteString == "https://radroots.org/field")

    #expect(throws: RadrootsExternalActionError.blockedByPolicy("external web urls must use https with a host")) {
        _ = try RadrootsExternalActionDestination.web("http://radroots.org")
    }
    #expect(throws: RadrootsExternalActionError.blockedByPolicy("external web urls must use https with a host")) {
        _ = try RadrootsExternalActionDestination.web("wss://radroots.org")
    }
    #expect(throws: RadrootsExternalActionError.blockedByPolicy("external web urls must use https with a host")) {
        _ = try RadrootsExternalActionDestination.web("https:///missing-host")
    }
    #expect(throws: RadrootsExternalActionError.invalidRequest("web url cannot contain whitespace or control characters")) {
        _ = try RadrootsExternalActionDestination.web("https://radroots.org/a b")
    }
}

@Test func nostrDestinationAllowsPublicIdentifiersAndRejectsSecrets() throws {
    let destination = try RadrootsExternalActionDestination.nostr("nostr:NPUB1qqqqqq")

    #expect(destination.kind == .nostr)
    #expect(destination.url?.absoluteString == "nostr:npub1qqqqqq")

    _ = try RadrootsExternalActionDestination.nostr("nostr:nprofile1qqqqqq")
    _ = try RadrootsExternalActionDestination.nostr("nostr:note1qqqqqq")
    _ = try RadrootsExternalActionDestination.nostr("nostr:nevent1qqqqqq")
    _ = try RadrootsExternalActionDestination.nostr("nostr:naddr1qqqqqq")
    _ = try RadrootsExternalActionDestination.nostr("nostr:nrelay1qqqqqq")

    #expect(throws: RadrootsExternalActionError.blockedByPolicy("nostr secret payloads cannot be opened externally")) {
        _ = try RadrootsExternalActionDestination.nostr("nostr:nsec1qqqqqq")
    }
    #expect(throws: RadrootsExternalActionError.blockedByPolicy("nostr uri payload must be a public Nostr identifier")) {
        _ = try RadrootsExternalActionDestination.nostr("nostr:relay1qqqqqq")
    }
    #expect(throws: RadrootsExternalActionError.invalidRequest("nostr uri cannot contain whitespace or control characters")) {
        _ = try RadrootsExternalActionDestination.nostr("nostr:npub1qq q")
    }
}

@Test func appleMapsDestinationBuildsSafeMapsUrls() throws {
    let coordinate = try RadrootsLocationCoordinate(latitude: 49.2827, longitude: -123.1207)
    let destination = try RadrootsExternalActionDestination.appleMaps(
        coordinate: coordinate,
        label: "Field Site"
    )

    #expect(destination.kind == .appleMaps)
    #expect(destination.url?.scheme == "https")
    #expect(destination.url?.host == "maps.apple.com")
    #expect(destination.url?.absoluteString.contains("ll=49.2827,-123.1207") == true)
    #expect(destination.url?.absoluteString.contains("q=Field%20Site") == true)

    _ = try RadrootsExternalActionDestination.appleMaps("https://maps.apple.com/?q=Field")

    #expect(throws: RadrootsExternalActionError.blockedByPolicy("apple maps urls must use https://maps.apple.com")) {
        _ = try RadrootsExternalActionDestination.appleMaps("https://example.com/maps")
    }
}

@Test func externalActionRequestPreservesDestination() throws {
    let destination = try RadrootsExternalActionDestination.web("https://radroots.org")
    let request = RadrootsExternalActionRequest(destination: destination)
    let capability = RadrootsExternalActionCapability(destination: destination, canOpen: true)

    #expect(request.destination == destination)
    #expect(capability.destination == destination)
    #expect(capability.canOpen)
}
