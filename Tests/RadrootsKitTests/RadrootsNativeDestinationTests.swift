import Foundation
@testable import RadrootsKit
import Testing

@Test(arguments: [
    "https://user@example.org/upload", "https://user:secret@example.org/upload",
    "https://example.org/upload?token=secret", "https://example.org/upload#fragment",
    "https://example.org:0/upload", "https://example.org:65536/upload",
    "http://example.org/upload", "https://example.org/a/../upload",
    "https://example.org/%2e/upload", "https://example.org/%2Fupload",
    "https://example.org/%5cupload", "https://example.org/%00upload"
]) func nativeDestinationRejectsAmbiguousAuthority(_ raw: String) throws {
    let url = try #require(URL(string: raw))
    #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
        try RadrootsNativeDestinationPolicy.validate(url, policy: .publicHTTPS)
    }
}

@Test(arguments: ["127.0.0.2", "127.1", "[::ffff:127.0.0.1]", "localhost.example.org", "example.org"])
func nativeDestinationRejectsFixtureEscape(_ host: String) throws {
    let url = try #require(URL(string: "http://\(host):8080/upload"))
    #expect(throws: RadrootsBackgroundTransferError.invalidRequest) {
        try RadrootsNativeDestinationPolicy.validate(url, policy: .simulatorLoopbackHTTP)
    }
}

@Test func nativeDestinationAcceptsExplicitAuthorityAndReportsPlatformCapability() throws {
    try RadrootsNativeDestinationPolicy.validate(#require(URL(string: "https://example.org:443/upload")),
                                                 policy: .publicHTTPS)
    #expect(!RadrootsAppleBackgroundTransferAdapters.supportsNewEnqueue(for: .publicHTTPS))
    #if os(iOS) && targetEnvironment(simulator)
        #expect(RadrootsAppleBackgroundTransferAdapters.supportsNewEnqueue(for: .simulatorLoopbackHTTP))
    #else
        #expect(!RadrootsAppleBackgroundTransferAdapters.supportsNewEnqueue(for: .simulatorLoopbackHTTP))
    #endif
    #if !os(iOS) || targetEnvironment(simulator)
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            try RadrootsNativeDestinationPolicy.validate(#require(URL(string: "http://\(host):8080/upload")),
                                                         policy: .simulatorLoopbackHTTP)
        }
    #endif
}

@Test func nativeDestinationRequiresOriginalMethodOriginAndPath() throws {
    var original = try URLRequest(url: #require(URL(string: "https://example.org/upload")))
    original.httpMethod = "PUT"
    #expect(RadrootsNativeDestinationPolicy.responseMatches(
        URL(string: "https://EXAMPLE.org:443/upload"), original: original, current: original
    ))
    for raw in ["http://example.org/upload", "https://other.org/upload", "https://example.org:444/upload",
                "https://example.org/other", "https://example.org/upload?token=secret"] {
        #expect(!RadrootsNativeDestinationPolicy.responseMatches(
            URL(string: raw),
            original: original,
            current: original
        ))
    }
    var redirected = original
    redirected.httpMethod = "GET"
    #expect(!RadrootsNativeDestinationPolicy.responseMatches(original.url, original: original, current: redirected))
    redirected = original
    redirected.url = URL(string: "https://example.org/other")
    #expect(!RadrootsNativeDestinationPolicy.responseMatches(original.url, original: original, current: redirected))
    #expect(!RadrootsNativeDestinationPolicy.responseMatches(nil, original: original, current: original))
}
