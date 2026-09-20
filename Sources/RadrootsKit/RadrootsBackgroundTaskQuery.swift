import Foundation

/// A failed local OS inventory is unknown, never an empty successful inventory.
enum RadrootsBackgroundTaskQuery {
    static let maximumTasks = 4096
    static func read<Value: Sendable>(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        _ query: (@escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        guard timeoutNanoseconds > 0, timeoutNanoseconds <= 5_000_000_000 else {
            throw RadrootsBackgroundTransferError.invalidRequest
        }
        let state = RadrootsBackgroundTaskQueryState<Value>()
        let timer = Task {
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            state.resolve(.failure(.transferFailure))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                query { [weak state] value in state?.resolve(.success(value)) }
            }
        } onCancel: {
            state.resolve(.failure(.transferFailure))
        }
    }

    static func descriptors(_ descriptions: [String?]) throws -> [RadrootsBackgroundURLTaskDescriptor] {
        // Bound local parsing while retaining large recovered inventories. Refusal
        // preserves all tasks and receipts and grants no new enqueue authority.
        guard descriptions.count <= maximumTasks else { throw RadrootsBackgroundTransferError.transferFailure }
        return try descriptions.map { description in
            guard let description, description.utf8.count <= 256,
                  let descriptor = RadrootsBackgroundURLTaskDescriptor(taskDescription: description)
            else { throw RadrootsBackgroundTransferError.transferFailure }
            return descriptor
        }
    }
}

/// The lock protects every field. Only the first result wins; foreign callbacks
/// and continuation resumption always execute after releasing the lock.
private final class RadrootsBackgroundTaskQueryState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var resolved = false
    private var earlyResult: Result<Value, RadrootsBackgroundTransferError>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        if let earlyResult {
            self.earlyResult = nil
            lock.unlock()
            continuation.resume(with: earlyResult.mapError { $0 as any Error })
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resolve(_ result: Result<Value, RadrootsBackgroundTransferError>) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let pending = continuation
        continuation = nil
        if pending == nil {
            earlyResult = result
        }
        lock.unlock()
        pending?.resume(with: result.mapError { $0 as any Error })
    }
}
