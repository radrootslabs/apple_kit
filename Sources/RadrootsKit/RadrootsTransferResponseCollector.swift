import Foundation

/// Bounds bytes as they arrive. Header strings are bounded before normalization;
/// no request headers or arbitrary response headers enter the receipt.
final class RadrootsTransferResponseCollector: @unchecked Sendable {
    private static let maximumBodyBytes = 65536
    private let lock = NSLock()
    private var limits: [Int: Int] = [:]
    private var bodies: [Int: Data] = [:]
    private var counts: [Int: Int] = [:]
    private var failures: [Int: RadrootsBackgroundTransferFailure] = [:]

    func register(_ limit: Int, taskIdentifier: Int) {
        lock.withLock { limits[taskIdentifier] = min(max(limit, 0), Self.maximumBodyBytes) }
    }

    func begin(_ response: URLResponse, taskIdentifier: Int, fallbackLimit: Int) -> Bool {
        lock.withLock {
            guard let http = response as? HTTPURLResponse else {
                failures[taskIdentifier] = .responseInvalid
                return false
            }
            let limit = effectiveLimit(taskIdentifier, fallback: fallbackLimit)
            let failure = Self.headerFailure(http) ?? (
                response.expectedContentLength > Int64(limit) ? .responseTooLarge : nil
            )
            if let failure {
                failures[taskIdentifier] = failure
            }
            return failure == nil
        }
    }

    /// Returns true when the task must be cancelled, including discard-policy
    /// responses that exceed the absolute transport bound.
    func append(_ data: Data, taskIdentifier: Int, fallbackLimit: Int) -> Bool {
        lock.withLock {
            guard failures[taskIdentifier] == nil else { return true }
            let limit = effectiveLimit(taskIdentifier, fallback: fallbackLimit)
            let count = counts[taskIdentifier] ?? 0
            guard data.count <= limit - count else {
                bodies.removeValue(forKey: taskIdentifier)
                failures[taskIdentifier] = .responseTooLarge
                return true
            }
            counts[taskIdentifier] = count + data.count
            if (limits[taskIdentifier] ?? fallbackLimit) > 0 {
                bodies[taskIdentifier, default: Data()].append(data)
            }
            return false
        }
    }

    func take(taskIdentifier: Int, response: HTTPURLResponse?,
              destinationMismatch: Bool) -> RadrootsBackgroundHTTPResult {
        lock.withLock {
            let body = bodies.removeValue(forKey: taskIdentifier)
            let failure = failures.removeValue(forKey: taskIdentifier) ?? response.flatMap(Self.headerFailure)
            limits.removeValue(forKey: taskIdentifier)
            counts.removeValue(forKey: taskIdentifier)
            let rawType = response?.value(forHTTPHeaderField: "Content-Type")
            let mediaType = rawType.flatMap { value -> String? in
                guard value.utf8.count <= 256 else { return nil }
                return try? RadrootsBackgroundTransferValidation.normalizedMediaType(value)
            }
            let rawEncoding = response?.value(forHTTPHeaderField: "Content-Encoding")
            let encoding = rawEncoding.flatMap { value -> String? in
                guard value.utf8.count <= 32 else { return "invalid" }
                return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            return RadrootsBackgroundHTTPResult(
                statusCode: response?.statusCode, mediaType: mediaType, body: body, contentEncoding: encoding,
                bodyExceeded: failure == .responseTooLarge, mediaTypeWasMalformed: rawType != nil && mediaType == nil,
                destinationMismatch: destinationMismatch, headerFailure: failure
            )
        }
    }

    private func effectiveLimit(_ identifier: Int, fallback: Int) -> Int {
        let limit = limits[identifier] ?? min(max(fallback, 0), Self.maximumBodyBytes)
        return limit == 0 ? Self.maximumBodyBytes : limit
    }

    private static func headerFailure(_ response: HTTPURLResponse) -> RadrootsBackgroundTransferFailure? {
        if let value = response.value(forHTTPHeaderField: "Content-Encoding"),
           value.utf8.count > 32 || value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            return .responseContentEncoding
        }
        if let value = response.value(forHTTPHeaderField: "Content-Type"),
           value.utf8.count > 256 || (try? RadrootsBackgroundTransferValidation.normalizedMediaType(value)) == nil {
            return .responseMediaType
        }
        return nil
    }
}
