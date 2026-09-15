#if os(iOS) && targetEnvironment(simulator)
    import Foundation
    @testable import RadrootsKit
    import Testing

    @Test(arguments: ["valid", "declared", "chunked", "missing", "status", "type", "shape", "encoded"])
    func nativeResponseEnforcesActualTransportBounds(_ name: String) async throws {
        let server = try NativeRedirectServer()
        defer { server.stop() }
        let port = try await server.start()
        server.respond(with: nativeResponseWire(name))
        let roots = try appleTransferRoots()
        defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
        let source = RadrootsFileReference(scope: .cache, relativePath: "response_body")
        try RadrootsAppleFileAccess(roots: roots).write(.inline(Data("isolated fixture body".utf8)), to: source)
        let store = RadrootsAppleBackgroundTransferStore(roots: roots)
        let adapters = try RadrootsAppleBackgroundTransferAdapters.live(
            sessionIdentifier: "org.radroots.response.\(UUID().uuidString.lowercased())", store: store,
            fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots),
            downloadStagingRoot: roots.temporaryRoot
        )
        let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: adapters)
        let request = try RadrootsBackgroundTransferRequest(
            identifier: RadrootsBackgroundTransferIdentifier("response.\(name)"),
            remoteURL: #require(URL(string: "http://127.0.0.1:\(port)/upload")), method: .put,
            operation: .upload(source: .file(source)), networkPolicy: .simulatorLoopbackHTTP,
            responsePolicy: .boundedJSON(maximumBodyBytes: 32)
        )
        _ = try await transfer.enqueue(request)
        let deadline = Date().addingTimeInterval(15)
        var snapshot = try await store.loadSnapshots().first
        while snapshot?.state == .queued || snapshot?.state == .running {
            guard Date() < deadline else { throw RadrootsBackgroundTransferError.transferFailure }
            try await Task.sleep(for: .milliseconds(25))
            snapshot = try await store.loadSnapshots().first
        }
        let failures: [String: RadrootsBackgroundTransferFailure] = [
            "declared": .responseTooLarge, "chunked": .responseTooLarge, "missing": .responseMissing,
            "status": .httpStatus, "type": .responseMediaType, "shape": .responseInvalid,
            "encoded": .responseContentEncoding
        ]
        #expect(snapshot?.state == (name == "valid" ? .awaitingVerification : .failed))
        #expect(snapshot?.failure == failures[name])
        #expect(server.requestCount == 1)
        if name == "valid" {
            #expect(snapshot?.response?.body == Data("{}".utf8))
        }
    }

    private func nativeResponseWire(_ name: String) -> Data {
        let status = name == "status" ? "503 Unavailable" : "200 OK"
        let type = name == "type" ? "image/jpeg" : "application/json"
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nConnection: close\r\n"
        if name == "encoded" {
            headers += "Content-Encoding: gzip\r\n"
        }
        if name == "chunked" {
            return Data((headers + "Transfer-Encoding: chunked\r\n\r\n20\r\n" + String(repeating: "x", count: 32)
                    + "\r\n1\r\nx\r\n0\r\n\r\n").utf8)
        }
        let body = name == "missing" ? "" : name == "shape" ? "[" : "{}"
        let length = name == "declared" ? 1024 : body.utf8.count
        return Data((headers + "Content-Length: \(length)\r\n\r\n" + body).utf8)
    }
#endif
