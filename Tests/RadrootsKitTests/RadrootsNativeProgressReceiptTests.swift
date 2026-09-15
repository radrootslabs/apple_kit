#if os(iOS) && targetEnvironment(simulator)
    import Foundation
    @testable import RadrootsKit
    import RadrootsKitTesting
    import Testing

    @Test func nativeUploadDelegatePreservesExecutionIdentityForProgress() async throws {
        let roots = try appleTransferRoots()
        defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
        let request = try RadrootsBackgroundTransferRequest(
            identifier: RadrootsBackgroundTransferIdentifier("progress.identity"),
            remoteURL: #require(URL(string: "http://127.0.0.1:8080/upload")), method: .put,
            operation: .upload(source: .file(RadrootsFileReference(scope: .cache, relativePath: "body"))),
            networkPolicy: .simulatorLoopbackHTTP
        )
        let executionID = UUID()
        let running = try RadrootsBackgroundTransferSnapshot(
            request: request,
            state: .running,
            executionID: executionID
        )
        let store = RadrootsInMemoryBackgroundTransferStore(snapshots: [running])
        let coordinator = RadrootsTransferCoordinator(sessionIdentifier: "progress.tests", store: store,
                                                      fileResolver: RadrootsAppleBackgroundTransferFileResolver(
                                                          roots: roots
                                                      ))
        let delegate = RadrootsTransferSessionDelegate(coordinator: coordinator,
                                                       downloadStagingRoot: roots.temporaryRoot, fileManager: .default)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var nativeRequest = URLRequest(url: request.remoteURL)
        nativeRequest.httpMethod = "PUT"
        let task = session.uploadTask(with: nativeRequest, from: Data(repeating: 1, count: 10))
        task.taskDescription = RadrootsBackgroundURLTaskDescriptor(request: request, executionID: executionID)
            .taskDescription
        delegate.urlSession(session, task: task, didSendBodyData: 5, totalBytesSent: 5, totalBytesExpectedToSend: 10)
        for _ in 0 ..< 100 {
            if try await store.loadSnapshots().first?.progress.bytesTransferred == 5 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.loadSnapshots().first?.progress.bytesTransferred == 5)
        task.taskDescription = RadrootsBackgroundURLTaskDescriptor(request: request, executionID: UUID())
            .taskDescription
        delegate.urlSession(session, task: task, didSendBodyData: 5, totalBytesSent: 10, totalBytesExpectedToSend: 10)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await store.loadSnapshots().first?.progress.bytesTransferred == 5)
    }
#endif
