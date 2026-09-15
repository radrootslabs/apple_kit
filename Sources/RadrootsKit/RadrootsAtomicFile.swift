import Darwin
import Foundation

/// Synchronous, descriptor-relative installation. An error before publication
/// preserves the prior destination; an error after publication is ambiguous and
/// callers must inspect/recover the exact destination before acknowledging it.
enum RadrootsAtomicFile {
    enum Mode { case replace, create }
    enum Phase: CaseIterable { case afterWriteChunk, afterWrite, beforeFileSync, beforeInstall, beforeDirectorySync }
    static let maximumBytes = 512 * 1024 * 1024

    /// A short, synchronous cross-owner transaction. Contention fails closed
    /// instead of blocking a cooperative executor or awaiting under a lock.
    static func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        guard let descriptor = try acquireExclusiveLock(at: url) else {
            throw RadrootsAppleFileError.permanentFailure
        }
        defer { Darwin.close(descriptor) }
        return try body()
    }

    /// The caller owns and closes the returned descriptor. Nil denotes only
    /// active contention; invalid paths and I/O failures remain errors.
    static func acquireExclusiveLock(at url: URL) throws -> Int32? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.isFileURL, !url.path.utf8.contains(0), let leaf = parts.last,
              parts.allSatisfy({ $0 != "." && $0 != ".." })
        else { throw RadrootsAppleFileError.invalidRequest }
        let directory = try Directory.open(Array(parts.dropLast()), create: true)
        defer { Darwin.close(directory.descriptor) }
        let descriptor = leaf.withCString {
            Darwin.openat(
                directory.descriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_EXLOCK,
                0o600
            )
        }
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK {
                return nil
            }
            throw RadrootsAppleFileError.permanentFailure
        }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG
        else {
            Darwin.close(descriptor)
            throw RadrootsAppleFileError.permanentFailure
        }
        do {
            try directory.validate()
        } catch {
            Darwin.close(descriptor); throw error
        }
        return descriptor
    }

    static func install(_ data: Data, at url: URL, mode: Mode = .replace, readOnly: Bool = false) throws {
        try install(data, at: url, mode: mode, readOnly: readOnly, fault: nil)
    }

    static func installForTesting(
        _ data: Data, at url: URL, mode: Mode = .replace, fault: @escaping (Phase) throws -> Void
    ) throws {
        try install(data, at: url, mode: mode, readOnly: false, fault: fault)
    }

    static func remove(at url: URL) throws {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard url.isFileURL, !url.path.utf8.contains(0), let leaf = parts.last,
              parts.allSatisfy({ $0 != "." && $0 != ".." })
        else { throw RadrootsAppleFileError.invalidRequest }
        let directory = try Directory.open(Array(parts.dropLast()), create: false)
        defer { Darwin.close(directory.descriptor) }
        var value = stat()
        guard leaf.withCString({ Darwin.fstatat(directory.descriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0,
              value.st_mode & S_IFMT == S_IFREG
        else { throw RadrootsAppleFileError.permanentFailure }
        try directory.validate()
        guard leaf.withCString({ Darwin.unlinkat(directory.descriptor, $0, 0) }) == 0,
              Darwin.fsync(directory.descriptor) == 0
        else { throw RadrootsAppleFileError.permanentFailure }
        try directory.validate()
    }

    static func synchronizeExisting(at url: URL) throws {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard url.isFileURL, !url.path.utf8.contains(0), let leaf = parts.last,
              parts.allSatisfy({ $0 != "." && $0 != ".." })
        else { throw RadrootsAppleFileError.invalidRequest }
        let directory = try Directory.open(Array(parts.dropLast()), create: false)
        defer { Darwin.close(directory.descriptor) }
        let descriptor = leaf.withCString {
            Darwin.openat(directory.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw RadrootsAppleFileError.permanentFailure }
        defer { Darwin.close(descriptor) }
        var before = stat()
        var after = stat()
        guard Darwin.fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              Darwin.fsync(descriptor) == 0, Darwin.fsync(directory.descriptor) == 0,
              leaf.withCString({ Darwin.fstatat(directory.descriptor, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size
        else { throw RadrootsAppleFileError.permanentFailure }
        try directory.validate()
    }

    private static func install(
        _ data: Data, at url: URL, mode: Mode, readOnly: Bool, fault: ((Phase) throws -> Void)?
    ) throws {
        guard data.count <= maximumBytes, url.isFileURL, url.path.hasPrefix("/"),
              !url.path.utf8.contains(0)
        else { throw RadrootsAppleFileError.invalidRequest }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leaf = parts.last, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RadrootsAppleFileError.invalidRequest
        }
        let directory = try Directory.open(Array(parts.dropLast()), create: true)
        defer { Darwin.close(directory.descriptor) }
        let temporary = ".radroots_pending_" + UUID().uuidString.lowercased()
        let descriptor = temporary.withCString {
            Darwin.openat(directory.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw RadrootsAppleFileError.permanentFailure }
        defer { Darwin.close(descriptor) }
        // Keep interrupted files identifiable. Normal failure cleanup is safe;
        // abrupt process loss leaves the same reserved temporary prefix.
        defer { _ = temporary.withCString { Darwin.unlinkat(directory.descriptor, $0, 0) } }
        try writeAll(data, to: descriptor, fault: fault)
        try fault?(.afterWrite)
        if readOnly, Darwin.fchmod(descriptor, 0o400) != 0 {
            throw RadrootsAppleFileError.permanentFailure
        }
        try fault?(.beforeFileSync)
        guard Darwin.fsync(descriptor) == 0 else { throw RadrootsAppleFileError.permanentFailure }
        try directory.validate()
        try fault?(.beforeInstall)
        try directory.validate()
        let installed = temporary.withCString { source in
            leaf.withCString { destination in
                switch mode {
                case .replace:
                    Darwin.renameat(directory.descriptor, source, directory.descriptor, destination)
                case .create:
                    Darwin.renameatx_np(
                        directory.descriptor,
                        source,
                        directory.descriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard installed == 0 else { throw RadrootsAppleFileError.permanentFailure }
        try fault?(.beforeDirectorySync)
        guard Darwin.fsync(directory.descriptor) == 0 else { throw RadrootsAppleFileError.permanentFailure }
        try directory.validate()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, fault: ((Phase) throws -> Void)?) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw RadrootsAppleFileError.invalidRequest }
                let count = Darwin.write(descriptor, base.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw RadrootsAppleFileError.permanentFailure }
                offset += count
                try fault?(.afterWriteChunk)
            }
        }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ descriptor: Int32) throws {
            var value = stat()
            guard Darwin.fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
                throw RadrootsAppleFileError.permanentFailure
            }
            device = value.st_dev
            inode = value.st_ino
        }
    }

    private struct Directory {
        let descriptor: Int32
        let parts: [String]
        let identities: [Identity]

        static func open(_ parts: [String], create: Bool) throws -> Self {
            var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw RadrootsAppleFileError.permanentFailure }
            do {
                var identities = try [Identity(descriptor)]
                for part in parts {
                    if create {
                        let result = part.withCString { Darwin.mkdirat(descriptor, $0, 0o700) }
                        guard result == 0 || errno == EEXIST else { throw RadrootsAppleFileError.permanentFailure }
                        if result == 0, Darwin.fsync(descriptor) != 0 {
                            throw RadrootsAppleFileError.permanentFailure
                        }
                    }
                    let next = part.withCString {
                        Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    }
                    guard next >= 0 else { throw RadrootsAppleFileError.permanentFailure }
                    Darwin.close(descriptor)
                    descriptor = next
                    try identities.append(Identity(descriptor))
                }
                return Self(descriptor: descriptor, parts: parts, identities: identities)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        func validate() throws {
            let current = try Self.open(parts, create: false)
            defer { Darwin.close(current.descriptor) }
            guard current.identities == identities else { throw RadrootsAppleFileError.permanentFailure }
        }
    }
}
