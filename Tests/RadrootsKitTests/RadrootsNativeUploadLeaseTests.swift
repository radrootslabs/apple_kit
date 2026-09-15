#if os(iOS) && targetEnvironment(simulator)
    import Foundation
    import Network
    @testable import RadrootsKit
    import RadrootsKitTesting
    import Testing

    @Test func nativeUploadConsumesLeaseAfterOriginalChangesBeforeTaskCreation() async throws {
        let server = try NativeLeaseHTTPServer()
        defer { server.stop() }
        let port = try await server.start()
        let roots = try appleTransferRoots()
        defer { try? FileManager.default.removeItem(at: roots.dataRoot.deletingLastPathComponent()) }
        let bytes = Data("immutable native upload body".utf8)
        let source = RadrootsFileReference(scope: .cache, relativePath: "native_upload")
        try RadrootsAppleFileAccess(roots: roots).write(.inline(bytes), to: source)
        let resolver = ReplacingNativeLeaseResolver(roots: roots, source: source)
        let store = RadrootsAppleBackgroundTransferStore(roots: roots)
        let adapters = try RadrootsAppleBackgroundTransferAdapters.live(
            sessionIdentifier: "org.radroots.native-lease.\(UUID().uuidString.lowercased())",
            store: store, fileResolver: resolver, downloadStagingRoot: roots.temporaryRoot
        )
        let transfer = RadrootsAppleBackgroundTransfer(store: store, adapters: adapters)
        let request = try RadrootsBackgroundTransferRequest(
            identifier: RadrootsBackgroundTransferIdentifier("native.lease.upload"),
            remoteURL: #require(URL(string: "http://127.0.0.1:\(port)/upload")), method: .put,
            operation: .upload(source: .file(source)), networkPolicy: .simulatorLoopbackHTTP,
            expectedSourceSHA256: RadrootsAppleFileDigest.sha256(bytes), maximumTransferBytes: 65536
        )
        _ = try await transfer.enqueue(request)
        await #expect(throws: RadrootsBackgroundTransferError.invalidRequest) { _ = try await transfer.enqueue(request)
        }
        let deadline = Date().addingTimeInterval(15)
        var snapshot = try await transfer.snapshot(for: request.identifier)
        while snapshot?.state == .queued || snapshot?.state == .running {
            guard Date() < deadline else { throw RadrootsBackgroundTransferError.transferFailure }
            try await Task.sleep(for: .milliseconds(25))
            snapshot = try await transfer.snapshot(for: request.identifier)
        }
        let completed = try #require(snapshot)
        #expect(completed.state == .awaitingVerification)
        #expect(completed.uploadLease?.blobID == request.expectedSourceSHA256)
        #expect(server.bodies == [bytes])
        #expect(try resolver.read(.file(source), maximumBytes: 65536) != bytes)
        try await transfer.settle(request.identifier, verification: .accepted)
        #expect(try await transfer.snapshot(for: request.identifier)?.state == .completed)
    }

    private struct ReplacingNativeLeaseResolver: RadrootsBackgroundTransferFileResolver {
        let roots: RadrootsAppleFileRoots
        let source: RadrootsFileReference
        private var live: RadrootsAppleBackgroundTransferFileResolver {
            .init(roots: roots)
        }

        func resolve(_ file: RadrootsBackgroundTransferLocalFile) throws -> URL {
            try live.resolve(file)
        }

        func read(_ file: RadrootsBackgroundTransferLocalFile, maximumBytes: Int) throws -> Data {
            try live.read(file, maximumBytes: maximumBytes)
        }

        func prepareUploadLease(
            for request: RadrootsBackgroundTransferRequest, executionID: UUID, existing: RadrootsStagedBlobReference?
        ) throws -> RadrootsStagedBlobLease {
            let lease = try live.prepareUploadLease(for: request, executionID: executionID, existing: existing)
            try RadrootsAppleFileAccess(roots: roots).write(.inline(Data("replaced original".utf8)), to: source)
            return lease
        }

        func releaseUploadLease(executionID: UUID) throws {
            try live.releaseUploadLease(executionID: executionID)
        }
    }

    /// Network callbacks use one private queue; observed result copies use a lock.
    private final class NativeLeaseHTTPServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "org.radroots.tests.native-lease-http")
        private let lock = NSLock()
        private var receivedBodies: [Data] = []
        private var connections: [NWConnection] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var bodies: [Data] {
            lock.withLock { receivedBodies }
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connections.append(connection)
                connection.start(queue: queue)
                read(connection, accumulated: Data())
            }
            listener.start(queue: queue)
            for _ in 0 ..< 500 {
                if let port = listener.port, port.rawValue > 0 {
                    return port.rawValue
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw RadrootsBackgroundTransferError.unavailable
        }

        func stop() {
            listener.cancel()
            queue.async { for connection in self.connections {
                connection.cancel()
            } }
        }

        private func read(_ connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var bytes = accumulated
                if let data {
                    bytes.append(data)
                }
                guard error == nil, bytes.count <= 131_072 else { connection.cancel(); return }
                if let body = self.body(in: bytes) {
                    self.lock.withLock { self.receivedBodies.append(body) }
                    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete {
                    connection.cancel()
                } else {
                    self.read(connection, accumulated: bytes)
                }
            }
        }

        private func body(in bytes: Data) -> Data? {
            guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8),
                  header.hasPrefix("PUT /upload HTTP/1.1\r\n")
            else { return nil }
            let length = header.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("content-length:")
            }.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
            guard let length, (0 ... 65536).contains(length),
                  bytes.count - separator.upperBound == length else { return nil }
            return Data(bytes[separator.upperBound...])
        }
    }
#endif
