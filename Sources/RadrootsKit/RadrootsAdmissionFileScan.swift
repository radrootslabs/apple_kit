import Darwin
import Foundation

/// One bounded pass over native reservation metadata, not a statement about
/// transfer completion or global absence. New entries may require another pass.
public struct RadrootsAdmissionCleanupResult: Sendable, Equatable {
    public let scannedEntries: Int
    public let removedFiles: Int
    public let reachedEnd: Bool
}

/// Owns two descriptors. The mutex serializes stream position and validation;
/// deinitialization runs only after all method borrows finish. No callbacks or
/// asynchronous work execute under this lock.
final class RadrootsAdmissionFileScan: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: RadrootsAtomicFile.Directory
    private let stream: UnsafeMutablePointer<DIR>

    init(url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw RadrootsAppleFileError.invalidRequest }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw RadrootsAppleFileError.invalidRequest }
        let directory = try RadrootsAtomicFile.Directory.open(parts, create: false)
        let copy = Darwin.fcntl(directory.descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else {
            Darwin.close(directory.descriptor)
            throw RadrootsAppleFileError.permanentFailure
        }
        guard let stream = Darwin.fdopendir(copy) else {
            Darwin.close(copy)
            Darwin.close(directory.descriptor)
            throw RadrootsAppleFileError.permanentFailure
        }
        self.directory = directory
        self.stream = stream
    }

    deinit {
        Darwin.closedir(stream)
        Darwin.close(directory.descriptor)
    }

    func next(limit: Int) throws -> (names: [String], scanned: Int, reachedEnd: Bool) {
        try lock.withLock {
            try directory.validate()
            var names: [String] = []
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
                if let name {
                    names.append(name)
                }
            }
            try directory.validate()
            return (names, scanned, reachedEnd)
        }
    }

    func removeInactive(name: String, coordination: Int32) throws -> Bool {
        try lock.withLock {
            try directory.validate()
            var held = stat()
            var gate = stat()
            guard Darwin.fstat(coordination, &held) == 0,
                  Darwin.fstatat(directory.descriptor, ".coordination.lock", &gate, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_dev == gate.st_dev, held.st_ino == gate.st_ino
            else {
                throw RadrootsAppleFileError.permanentFailure
            }
            var value = stat()
            guard name.withCString({ Darwin.fstatat(directory.descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0,
                  value.st_mode & S_IFMT == S_IFREG, value.st_size == 0 else { return false }
            guard let descriptor = try RadrootsAtomicFile.acquireExclusiveLock(in: directory, name: name, create: false) else {
                return false
            }
            defer { Darwin.close(descriptor) }
            return try RadrootsAtomicFile.removeEmptyLockedFile(in: directory, name: name, descriptor: descriptor)
        }
    }
}
