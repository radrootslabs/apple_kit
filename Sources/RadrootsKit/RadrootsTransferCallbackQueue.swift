import Foundation

/// Delegate callbacks arrive on a serial OS queue. Preserve that order across
/// Swift suspension so finished events cannot overtake receipt persistence.
final class RadrootsTransferCallbackQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var receipts: [RadrootsBackgroundTransferIdentifier: Int] = [:]

    var pendingIdentifiers: Set<RadrootsBackgroundTransferIdentifier> {
        lock.withLock { Set(receipts.keys) }
    }

    func enqueue(
        receipt identifier: RadrootsBackgroundTransferIdentifier? = nil,
        operation: @escaping @Sendable () async -> Void
    ) {
        lock.withLock {
            if let identifier {
                receipts[identifier, default: 0] += 1
            }
            let previous = tail
            tail = Task {
                await previous?.value
                await operation()
                if let identifier {
                    self.finished(identifier)
                }
            }
        }
    }

    private func finished(_ identifier: RadrootsBackgroundTransferIdentifier) {
        lock.withLock {
            let remaining = (receipts[identifier] ?? 1) - 1
            if remaining == 0 {
                receipts.removeValue(forKey: identifier)
            } else {
                receipts[identifier] = remaining
            }
        }
    }
}
