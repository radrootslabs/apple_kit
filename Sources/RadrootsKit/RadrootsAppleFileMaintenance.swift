import Darwin
import Foundation

/// Coordinates cooperating users of one governed root. Every operation that can
/// create a reference, read, replace or write a collected file must hold a use
/// reservation until its underlying work has drained, including after cancellation.
/// This mechanism does not establish application reference absence or retention policy.
public struct RadrootsAppleFileMaintenance: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Contention returns nil. No waiting, background work or automatic retry.
    public func reserveUse() throws -> RadrootsFileUseReservation? {
        try RadrootsFileMaintenanceGate.open(root: root, exclusive: false).map(RadrootsFileUseReservation.init)
    }

    /// Acquire before inspecting references; retain through the last conditional unlink.
    public func reserveMaintenance() throws -> RadrootsFileMaintenanceReservation? {
        try RadrootsFileMaintenanceGate.open(root: root, exclusive: true).map(RadrootsFileMaintenanceReservation.init)
    }
}

/// Release by dropping the last owner only after every underlying user has drained.
public final class RadrootsFileUseReservation: Sendable {
    private let gate: RadrootsFileMaintenanceGate
    fileprivate init(_ gate: RadrootsFileMaintenanceGate) {
        self.gate = gate
    }

    public func validate() throws {
        try gate.validate()
    }
}

/// Child scans retain this exclusive reservation. There is no early unlock API.
public final class RadrootsFileMaintenanceReservation: Sendable {
    let gate: RadrootsFileMaintenanceGate
    fileprivate init(_ gate: RadrootsFileMaintenanceGate) {
        self.gate = gate
    }

    /// Empty path selects the governed root. Other paths must be canonical relative
    /// directories without symlinks. Streams are live and never persisted as cookies.
    public func openDirectory(relativePath: String = "") throws -> RadrootsFileMaintenanceScan {
        try RadrootsFileMaintenanceScan(reservation: self, relativePath: relativePath)
    }

    public func validate() throws {
        try gate.validate()
    }
}

/// Immutable descriptor ownership; descriptors close only at final deinitialization.
/// Methods neither mutate descriptor state nor release the advisory reservation.
final class RadrootsFileMaintenanceGate: @unchecked Sendable {
    static let name = ".radroots_file_maintenance.lock"
    let directory: RadrootsAtomicFile.Directory
    private let descriptor: Int32

    private init(directory: RadrootsAtomicFile.Directory, descriptor: Int32) {
        self.directory = directory
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(directory.descriptor)
    }

    static func open(root: URL, exclusive: Bool) throws -> RadrootsFileMaintenanceGate? {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0) else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let parts = root.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let directory = try RadrootsAtomicFile.Directory.open(parts, create: true)
        var owned = false
        defer {
            if !owned {
                Darwin.close(directory.descriptor)
            }
        }
        for attempt in 0 ..< 4 {
            try directory.validate()
            let descriptor = Darwin.openat(directory.descriptor, name,
                                           O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (exclusive ? O_EXLOCK : O_SHLOCK), 0o600)
            if descriptor >= 0 {
                let gate = RadrootsFileMaintenanceGate(directory: directory, descriptor: descriptor)
                owned = true
                try gate.validate()
                return gate
            }
            let error = errno
            if error == EWOULDBLOCK {
                return nil
            }
            guard error == ENOENT else { throw RadrootsAppleFileError.permanentFailure }
            if attempt == 3 {
                throw RadrootsAppleFileError.transientFailure
            }
        }
        throw RadrootsAppleFileError.transientFailure
    }

    func validate() throws {
        try directory.validate()
        var held = stat()
        var current = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              Darwin.fstatat(directory.descriptor, Self.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_mode & S_IFMT == S_IFREG, current.st_mode & S_IFMT == S_IFREG,
              held.st_nlink == 1, held.st_size == 0, held.st_uid == geteuid(),
              held.st_dev == current.st_dev, held.st_ino == current.st_ino
        else {
            throw RadrootsAppleFileError.permanentFailure
        }
    }
}
