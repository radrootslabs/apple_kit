#if os(iOS) && targetEnvironment(simulator)
    import Foundation
    @testable import RadrootsKit
    import RadrootsKitTesting
    import Testing

    @Test func nativeDestinationRejectsNewPublicEnqueueBeforeTaskCreation() async throws {
        let roots = try appleTransferRoots()
        defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
        let store = RadrootsInMemoryBackgroundTransferStore()
        let adapters = try RadrootsAppleBackgroundTransferAdapters.live(
            sessionIdentifier: "org.radroots.public-refusal.\(UUID().uuidString.lowercased())", store: store,
            fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots),
            downloadStagingRoot: roots.temporaryRoot
        )
        let request = try RadrootsBackgroundTransferRequest(
            identifier: RadrootsBackgroundTransferIdentifier("public.refused"),
            remoteURL: #require(URL(string: "https://example.org/upload")), method: .put,
            operation: .upload(source: .file(RadrootsFileReference(scope: .cache, relativePath: "absent")))
        )
        await #expect(throws: RadrootsBackgroundTransferError.unavailable) {
            try await adapters.enqueue(request, UUID())
        }
        #expect(try await adapters.activeTransferIdentifiers().isEmpty)
        #expect(try await store.loadSnapshots().isEmpty)
    }

    @Test(arguments: ["same_host", "cross_host", "cross_port"])
    func nativeDestinationRefusesActualForegroundRedirect(_ kind: String) async throws {
        let server = try NativeRedirectServer()
        let target = try NativeRedirectServer()
        defer { server.stop(); target.stop() }
        let port = try await server.start()
        let targetPort = try await target.start()
        let destinations = ["same_host": "http://127.0.0.1:\(port)/other",
                            "cross_host": "http://localhost:\(targetPort)/other",
                            "cross_port": "http://127.0.0.1:\(targetPort)/other"]
        try server.redirect(to: #require(destinations[kind]))
        let roots = try appleTransferRoots()
        defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
        let source = RadrootsFileReference(scope: .cache, relativePath: "redirect_body")
        try RadrootsAppleFileAccess(roots: roots).write(.inline(Data("isolated fixture body".utf8)), to: source)
        let store = RadrootsAppleBackgroundTransferStore(roots: roots)
        let adapters = try RadrootsAppleBackgroundTransferAdapters.live(
            sessionIdentifier: "org.radroots.redirect.\(UUID().uuidString.lowercased())", store: store,
            fileResolver: RadrootsAppleBackgroundTransferFileResolver(roots: roots),
            downloadStagingRoot: roots.temporaryRoot
        )
        let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: adapters)
        let request = try RadrootsBackgroundTransferRequest(
            identifier: RadrootsBackgroundTransferIdentifier("redirect.\(kind)"),
            remoteURL: #require(URL(string: "http://127.0.0.1:\(port)/upload")), method: .put,
            operation: .upload(source: .file(source)), networkPolicy: .simulatorLoopbackHTTP
        )
        _ = try await transfer.enqueue(request)
        let deadline = Date().addingTimeInterval(15)
        var snapshot = try await store.loadSnapshots().first
        while snapshot?.state == .queued || snapshot?.state == .running {
            guard Date() < deadline else { throw RadrootsBackgroundTransferError.transferFailure }
            try await Task.sleep(for: .milliseconds(25))
            snapshot = try await store.loadSnapshots().first
        }
        #expect(snapshot?.state == .failed)
        #expect(snapshot?.failure == .httpStatus)
        #expect(server.requestCount == 1)
        #expect(target.requestCount == 0)
    }

    @Test func nativeDestinationDelegateRejectsDowngradeAndResponseMismatch() throws {
        let roots = try appleTransferRoots()
        defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
        let coordinator = RadrootsTransferCoordinator(sessionIdentifier: "callback.tests",
                                                      store: RadrootsInMemoryBackgroundTransferStore(),
                                                      fileResolver: RadrootsAppleBackgroundTransferFileResolver(
                                                          roots: roots
                                                      ))
        let delegate = RadrootsTransferSessionDelegate(coordinator: coordinator,
                                                       downloadStagingRoot: roots.temporaryRoot, fileManager: .default)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://example.org/upload"))
        let task = session.dataTask(with: url)
        let redirect = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil))
        var called = false
        let downgrade = try #require(URL(string: "http://example.org/upload"))
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: downgrade)) {
            called = true
            #expect($0 == nil)
        }
        #expect(called)
        for raw in ["https://other.org/upload", "https://example.org/other", "http://example.org/upload"] {
            let responseURL = try #require(URL(string: raw))
            let response = try #require(HTTPURLResponse(url: responseURL, statusCode: 200,
                                                        httpVersion: nil, headerFields: nil))
            var received = false
            delegate.urlSession(session, dataTask: task, didReceive: response) {
                received = true
                #expect($0 == .cancel)
            }
            #expect(received)
        }
    }

#endif
