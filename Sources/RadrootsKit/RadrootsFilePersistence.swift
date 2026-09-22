import Foundation

/// Immutable per-owner mechanics. Internal injection exercises real callers
/// without process-global faults or a public persistence bypass.
struct RadrootsFilePersistence: Sendable {
    let install: @Sendable (Data, URL, RadrootsAtomicFile.Mode, Bool) throws -> Void
    let synchronize: @Sendable (URL) throws -> Void

    static let live = Self(
        install: { try RadrootsAtomicFile.install($0, at: $1, mode: $2, readOnly: $3) },
        synchronize: { try RadrootsAtomicFile.synchronizeExisting(at: $0) }
    )
}
