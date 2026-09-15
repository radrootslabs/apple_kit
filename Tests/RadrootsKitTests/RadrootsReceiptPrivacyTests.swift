import Foundation
@testable import RadrootsKit
import Testing

@Test func receiptPersistenceAndDiagnosticsExcludeTransientAuthorityAndHostMetadata() async throws {
    let roots = try appleTransferRoots()
    defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
    let markers = ["AUTH_SENTINEL_809d", "DRAFT_SENTINEL_81ac", "LOCATION_SENTINEL_717d"]
    let request = try RadrootsBackgroundTransferRequest(
        identifier: RadrootsBackgroundTransferIdentifier("privacy.receipt"),
        remoteURL: #require(URL(string: "https://example.org/upload")), method: .put,
        operation: .upload(source: .file(RadrootsFileReference(scope: .cache, relativePath: "body"))),
        headers: ["Authorization": markers[0]], metadata: [markers[1]: markers[2]], responsePolicy: .boundedJSON()
    )
    let response = try RadrootsBackgroundTransferResponse(statusCode: 200, mediaType: "application/json",
                                                          body: Data(#"{"url":"https://example.org/blob"}"#.utf8))
    let snapshot = try RadrootsBackgroundTransferSnapshot(request: request, state: .awaitingVerification,
                                                          response: response, executionID: UUID())
    let store = RadrootsAppleBackgroundTransferStore(roots: roots)
    try await store.saveSnapshot(snapshot)
    let serializedRequest = try JSONEncoder().encode(request)
    let serializedSnapshot = try JSONEncoder().encode(snapshot)
    let persistedFile = RadrootsFileReference(scope: .data, relativePath: "background_transfers/transfers.json")
    let persistedURL = try roots.resolvedURL(for: persistedFile)
    let persisted = try Data(contentsOf: persistedURL)
    let diagnostics = [String(reflecting: request), String(describing: request), String(reflecting: snapshot),
                       String(describing: snapshot), String(reflecting: response), String(describing: response)]
    for marker in markers {
        #expect(![serializedRequest, serializedSnapshot, persisted].contains { $0.range(of: Data(marker.utf8)) != nil })
        #expect(!diagnostics.contains { $0.contains(marker) })
    }
    #expect(!diagnostics.contains { $0.contains("https://example.org/blob") })
    let recovered = try #require(try await store.loadSnapshots().first)
    #expect(recovered.request.headers.isEmpty && recovered.request.metadata.isEmpty)
    #expect(recovered.response == response && recovered.executionID == snapshot.executionID)
    #expect(request.headers["Authorization"] == markers[0])
}
