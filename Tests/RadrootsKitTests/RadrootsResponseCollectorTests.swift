import Foundation
@testable import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func responseCollectorBoundsDeclaredChunkedAndDiscardedBodies() throws {
    let url = try #require(URL(string: "https://example.org/upload"))
    let collector = RadrootsTransferResponseCollector()
    collector.register(8, taskIdentifier: 1)
    let declared = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: [
                                                    "Content-Type": "application/json",
                                                    "Content-Length": "9"
                                                ]))
    #expect(!collector.begin(declared, taskIdentifier: 1, fallbackLimit: 8))
    #expect(collector.take(taskIdentifier: 1, response: declared, destinationMismatch: false).bodyExceeded)
    collector.register(8, taskIdentifier: 2)
    let chunked = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                               headerFields: [
                                                   "Content-Type": "application/json",
                                                   "Transfer-Encoding": "chunked"
                                               ]))
    #expect(collector.begin(chunked, taskIdentifier: 2, fallbackLimit: 8))
    #expect(!collector.append(Data(repeating: 1, count: 8), taskIdentifier: 2, fallbackLimit: 8))
    #expect(collector.append(Data([1]), taskIdentifier: 2, fallbackLimit: 8))
    let rejected = collector.take(taskIdentifier: 2, response: chunked, destinationMismatch: false)
    #expect(rejected.body == nil && rejected.bodyExceeded)
    collector.register(0, taskIdentifier: 3)
    #expect(!collector.append(Data(repeating: 1, count: 65536), taskIdentifier: 3, fallbackLimit: 0))
    #expect(collector.append(Data([1]), taskIdentifier: 3, fallbackLimit: 0))
    #expect(collector.take(taskIdentifier: 3, response: chunked, destinationMismatch: false).body == nil)
}

@Test(arguments: ["gzip", "br", "identity, gzip", String(repeating: "x", count: 1024)])
func responseCollectorRejectsEncodingBeforeCollecting(_ encoding: String) throws {
    let url = try #require(URL(string: "https://example.org/upload"))
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: [
                                                    "Content-Encoding": encoding,
                                                    "Content-Type": "application/json"
                                                ]))
    let collector = RadrootsTransferResponseCollector()
    #expect(!collector.begin(response, taskIdentifier: 1, fallbackLimit: 32))
    #expect(collector.append(Data("{}".utf8), taskIdentifier: 1, fallbackLimit: 32))
    let result = collector.take(taskIdentifier: 1, response: response, destinationMismatch: false)
    #expect(result.headerFailure == .responseContentEncoding && result.body == nil)
}

@Test(arguments: ["", "[]", "null", "\"scalar\"", "{broken"])
func responseValidationRejectsMissingOrMalformedDescriptorShape(_ raw: String) async throws {
    let roots = try appleTransferRoots()
    defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
    let request = try appleUploadRequest(identifier: "response.shape", responsePolicy: .boundedJSON())
    let store = try RadrootsInMemoryBackgroundTransferStore(snapshots: [RadrootsBackgroundTransferSnapshot(
        request: request, state: .running
    )])
    let coordinator = RadrootsTransferCoordinator(sessionIdentifier: "shape.tests", store: store,
                                                  fileResolver: RadrootsAppleBackgroundTransferFileResolver(
                                                      roots: roots
                                                  ))
    await coordinator.complete(identifier: request.identifier, completion: RadrootsTransferCompletion(
        platformError: nil, stagedDownloadResult: nil, httpResult: RadrootsBackgroundHTTPResult(
            statusCode: 200,
            mediaType: "application/json",
            body: Data(raw.utf8),
            bodyExceeded: false
        ), bytesTransferred: 10,
        totalBytesExpected: 10
    ))
    #expect(try await store.loadSnapshots().first?.failure == .responseInvalid)
}

@Test func responseCollectorBoundsMetadataAndPreservesSafeVerificationFields() throws {
    let url = try #require(URL(string: "https://example.org/upload"))
    let collector = RadrootsTransferResponseCollector()
    let oversized = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json;" + String(
                                                     repeating: "x",
                                                     count: 1024
                                                 )]))
    #expect(!collector.begin(oversized, taskIdentifier: 1, fallbackLimit: 32))
    #expect(collector.take(taskIdentifier: 1, response: oversized, destinationMismatch: false).mediaTypeWasMalformed)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                                headerFields: [
                                                    "Content-Type": "application/json",
                                                    "Content-Encoding": "identity",
                                                    "Set-Cookie": "secret-marker"
                                                ]))
    #expect(collector.begin(response, taskIdentifier: 2, fallbackLimit: 32))
    #expect(!collector.append(Data("{}".utf8), taskIdentifier: 2, fallbackLimit: 32))
    let receipt = collector.take(taskIdentifier: 2, response: response, destinationMismatch: false)
    #expect(receipt.statusCode == 201 && receipt.mediaType == "application/json" && receipt
        .contentEncoding == "identity")
    #expect(receipt.body == Data("{}".utf8))
    #expect(!String(reflecting: receipt).contains("secret-marker"))
}
