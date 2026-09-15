#if os(iOS) && targetEnvironment(simulator)
    import Foundation
    import Network
    @testable import RadrootsKit

    /// Isolated loopback fixture. No external DNS, TLS trust changes, or credentials.
    final class NativeRedirectServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "org.radroots.tests.redirect-http")
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var received = 0
        private var location: String?
        private var wireResponse: Data?

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }

        var requestCount: Int {
            lock.withLock { received }
        }

        func redirect(to location: String) {
            lock.withLock { self.location = location }
        }

        func respond(with bytes: Data) {
            lock.withLock { wireResponse = bytes }
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
                if self.hasBody(bytes) {
                    let destination = self.lock.withLock { self.received += 1; return self.location }
                    let status = destination.map { "307 Temporary Redirect\r\nLocation: \($0)" } ?? "200 OK"
                    let response = self.lock.withLock { self.wireResponse }
                        ?? Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete {
                    connection.cancel()
                } else {
                    self.read(connection, accumulated: bytes)
                }
            }
        }

        private func hasBody(_ bytes: Data) -> Bool {
            guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8)
            else { return false }
            let length = header.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("content-length:")
            }.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            return (0 ... 65536).contains(length) && bytes.count - separator.upperBound == length
        }
    }
#endif
