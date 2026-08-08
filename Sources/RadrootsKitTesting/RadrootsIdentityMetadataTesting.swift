import Foundation
import RadrootsKit

public final class RadrootsInMemoryIdentityMetadataStore: RadrootsIdentityMetadataStore,
    @unchecked Sendable
{
    public enum Operation: Equatable, Sendable {
        case read
        case write
        case delete
    }

    public enum Failure: Error, Sendable {
        case forced
    }

    private let lock = NSLock()
    private var values: [RadrootsIdentityMetadataSlot: Data] = [:]
    private var nextFailure: (Operation, RadrootsIdentityMetadataSlot)?

    public init() {}

    public func data(for slot: RadrootsIdentityMetadataSlot) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        try failIfRequested(.read, slot: slot)
        return values[slot]
    }

    public func put(_ data: Data, for slot: RadrootsIdentityMetadataSlot) throws {
        lock.lock()
        defer { lock.unlock() }
        try failIfRequested(.write, slot: slot)
        values[slot] = data
    }

    public func delete(_ slot: RadrootsIdentityMetadataSlot) throws {
        lock.lock()
        defer { lock.unlock() }
        try failIfRequested(.delete, slot: slot)
        values.removeValue(forKey: slot)
    }

    public func failNext(_ operation: Operation, slot: RadrootsIdentityMetadataSlot) {
        lock.lock()
        nextFailure = (operation, slot)
        lock.unlock()
    }

    public func rawData(for slot: RadrootsIdentityMetadataSlot) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[slot]
    }

    public func replaceRawData(_ data: Data?, for slot: RadrootsIdentityMetadataSlot) {
        lock.lock()
        values[slot] = data
        lock.unlock()
    }

    private func failIfRequested(_ operation: Operation, slot: RadrootsIdentityMetadataSlot) throws {
        guard let failure = nextFailure,
              failure.0 == operation,
              failure.1 == slot
        else {
            return
        }
        nextFailure = nil
        throw Failure.forced
    }
}
