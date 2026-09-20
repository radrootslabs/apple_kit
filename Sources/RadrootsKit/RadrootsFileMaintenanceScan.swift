import Darwin
import Foundation

/// The mutex serializes the retained directory stream and synchronous unlink.
/// No callbacks or async work run under it. Final deinitialization closes both
/// scan descriptors, then releases its retained exclusive maintenance reservation.
public final class RadrootsFileMaintenanceScan: @unchecked Sendable {
    private let reservation: RadrootsFileMaintenanceReservation
    private let directory: RadrootsAtomicFile.Directory
    private let stream: UnsafeMutablePointer<DIR>
    private let lock = NSLock()
    private let scanID = UUID()
    private var invalidated = false

    init(reservation: RadrootsFileMaintenanceReservation, relativePath: String) throws {
        let parts = relativePath.isEmpty ? [] : relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw RadrootsAppleFileError.invalidRequest
        }
        try reservation.validate()
        let directory = try RadrootsAtomicFile.Directory.open(reservation.gate.directory.parts + parts, create: false)
        var owned = false
        defer {
            if !owned {
                Darwin.close(directory.descriptor)
            }
        }
        let copy = Darwin.fcntl(directory.descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw RadrootsAppleFileError.permanentFailure }
        guard let stream = Darwin.fdopendir(copy) else {
            Darwin.close(copy)
            throw RadrootsAppleFileError.permanentFailure
        }
        do {
            try reservation.validate()
            try directory.validate()
        } catch {
            Darwin.closedir(stream)
            throw error
        }
        self.reservation = reservation
        self.directory = directory
        self.stream = stream
        owned = true
    }

    deinit {
        Darwin.closedir(stream)
        Darwin.close(directory.descriptor)
    }

    /// At most 64 directory entries per call, including entries not returned.
    /// The caller owns total work budgets and must not infer absence from a prefix.
    /// An I/O or identity error invalidates this scan; begin a fresh inventory.
    public func next(limit: Int = 64) throws -> RadrootsFileMaintenancePage {
        guard (1 ... 64).contains(limit) else { throw RadrootsAppleFileError.invalidRequest }
        return try perform {
            try validate()
            var entries: [RadrootsFileMaintenanceEntry] = []
            var scanned = 0
            var reachedEnd = false
            for _ in 0 ..< limit {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    guard errno == 0 else { throw RadrootsAppleFileError.permanentFailure }
                    reachedEnd = true
                    break
                }
                scanned += 1
                let count = Int(entry.pointee.d_namlen)
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String? in
                    guard count <= bytes.count else { return nil }
                    return String(bytes: bytes.prefix(count), encoding: .utf8)
                }
                // Unrepresentable names are an incomplete inventory, not absence.
                guard let name else { throw RadrootsAppleFileError.permanentFailure }
                if name == "." || name == ".." || name == RadrootsFileMaintenanceGate.name {
                    continue
                }
                var value = stat()
                let found = name.withCString { Darwin.fstatat(directory.descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }
                if found != 0, errno == ENOENT {
                    continue
                }
                guard found == 0 else { throw RadrootsAppleFileError.permanentFailure }
                entries.append(RadrootsFileMaintenanceEntry(name: name, value: value, scanID: scanID))
            }
            try validate()
            return RadrootsFileMaintenancePage(entries: entries, scannedEntries: scanned, reachedEnd: reachedEnd)
        }
    }

    /// Only an unchanged, singly linked regular file from this scan is eligible.
    /// The host must prove reference absence and grace under this reservation.
    /// False means retained/absent. Errors after unlink are ambiguous: inspect
    /// again; never assume an error means the file remains or reuse an old proof.
    public func remove(_ entry: RadrootsFileMaintenanceEntry) throws -> Bool {
        guard entry.scanID == scanID else { throw RadrootsAppleFileError.invalidRequest }
        return try perform {
            try validate()
            guard entry.kind == .regularFile, entry.identity.links == 1,
                  entry.name != RadrootsFileMaintenanceGate.name else { return false }
            var current = stat()
            let found = entry.name.withCString { Darwin.fstatat(directory.descriptor, $0, &current, AT_SYMLINK_NOFOLLOW) }
            if found != 0, errno == ENOENT {
                return false
            }
            guard found == 0 else { throw RadrootsAppleFileError.permanentFailure }
            guard RadrootsFileMaintenanceIdentity(current) == entry.identity else { return false }
            guard entry.name.withCString({ Darwin.unlinkat(directory.descriptor, $0, 0) }) == 0 else {
                throw RadrootsAppleFileError.permanentFailure
            }
            guard Darwin.fsync(directory.descriptor) == 0 else { throw RadrootsAppleFileError.permanentFailure }
            try validate()
            return true
        }
    }

    private func validate() throws {
        try reservation.validate()
        try directory.validate()
    }

    private func perform<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard !invalidated else { throw RadrootsAppleFileError.permanentFailure }
            do {
                return try operation()
            } catch {
                invalidated = true
                throw error
            }
        }
    }
}
