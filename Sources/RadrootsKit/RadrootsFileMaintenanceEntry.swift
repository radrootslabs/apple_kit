import Darwin
import Foundation

/// Opaque captured identity. A candidate is valid only for its originating scan;
/// neither its name nor its age is independent authority to remove a file.
public struct RadrootsFileMaintenanceEntry: Sendable {
    public enum Kind: Sendable { case regularFile, directory, other }

    public let name: String
    public let kind: Kind
    public let sizeBytes: Int64
    public let modifiedAt: Date
    let scanID: UUID
    let identity: RadrootsFileMaintenanceIdentity

    init(name: String, value: stat, scanID: UUID) {
        self.name = name
        kind = switch value.st_mode & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        default: .other
        }
        sizeBytes = value.st_size
        modifiedAt = Date(timeIntervalSince1970:
            Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        self.scanID = scanID
        identity = RadrootsFileMaintenanceIdentity(value)
    }
}

public struct RadrootsFileMaintenancePage: Sendable {
    public let entries: [RadrootsFileMaintenanceEntry]
    /// Includes ignored dot entries, disappeared entries and the coordination file.
    public let scannedEntries: Int
    /// End of this live stream, not a snapshot or a global absence assertion.
    public let reachedEnd: Bool
}

struct RadrootsFileMaintenanceIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let links: nlink_t
    let owner: uid_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        links = value.st_nlink
        owner = value.st_uid
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanos = value.st_ctimespec.tv_nsec
    }
}
