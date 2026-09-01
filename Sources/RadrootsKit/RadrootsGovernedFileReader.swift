import Darwin
import Foundation

enum RadrootsGovernedFileReadError: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case invalidObject
    case tooLarge
    case changedDuringRead
    case ioFailure
}

struct RadrootsGovernedFileReader {
    private static let readBufferByteCount = 16 * 1024

    static func read(
        root: URL,
        relativePath: String,
        maximumBytes: Int
    ) throws -> Data {
        try read(
            root: root,
            relativePath: relativePath,
            maximumBytes: maximumBytes,
            afterAdmission: nil
        )
    }

    static func readForTesting(
        root: URL,
        relativePath: String,
        maximumBytes: Int,
        afterAdmission: @escaping () throws -> Void
    ) throws -> Data {
        try read(
            root: root,
            relativePath: relativePath,
            maximumBytes: maximumBytes,
            afterAdmission: afterAdmission
        )
    }

    private static func read(
        root: URL,
        relativePath: String,
        maximumBytes: Int,
        afterAdmission: (() throws -> Void)?
    ) throws -> Data {
        guard root.isFileURL,
            root.path.hasPrefix("/"),
            maximumBytes >= 0,
            maximumBytes < Int.max
        else {
            throw RadrootsGovernedFileReadError.invalidRequest
        }

        let rootComponents = try components(ofAbsoluteRoot: root)
        let relativeComponents = try components(ofRelativePath: relativePath)
        let directoryComponents = rootComponents + Array(relativeComponents.dropLast())
        let leaf = relativeComponents[relativeComponents.index(before: relativeComponents.endIndex)]

        let admittedTraversal = try openDirectoryTraversal(directoryComponents)
        defer { close(admittedTraversal.descriptor) }

        let fileDescriptor = try openComponent(
            leaf,
            relativeTo: admittedTraversal.descriptor,
            expectingDirectory: false
        )
        defer { close(fileDescriptor) }

        let admittedFile = try fileIdentity(of: fileDescriptor)
        guard admittedFile.isRegularFile else {
            throw RadrootsGovernedFileReadError.invalidObject
        }
        guard admittedFile.byteCount <= UInt64(maximumBytes) else {
            throw RadrootsGovernedFileReadError.tooLarge
        }

        do {
            try afterAdmission?()
        } catch {
            throw RadrootsGovernedFileReadError.ioFailure
        }
        let bytes = try readBounded(
            fileDescriptor,
            admittedByteCount: admittedFile.byteCount,
            maximumBytes: maximumBytes
        )

        let finalFile = try fileIdentity(of: fileDescriptor)
        guard finalFile == admittedFile,
            UInt64(bytes.count) == admittedFile.byteCount
        else {
            throw RadrootsGovernedFileReadError.changedDuringRead
        }

        try validateCurrentBinding(
            directoryComponents: Array(directoryComponents),
            admittedDirectories: admittedTraversal.identities,
            leaf: leaf,
            admittedFile: admittedFile
        )
        return Data(bytes)
    }

    private static func components(ofAbsoluteRoot root: URL) throws -> [String] {
        let path = root.path
        guard path.hasPrefix("/"),
            !path.utf8.contains(0)
        else {
            throw RadrootsGovernedFileReadError.invalidRequest
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(
            String.init)
        guard components.allSatisfy(isOrdinaryComponent) else {
            throw RadrootsGovernedFileReadError.invalidRequest
        }
        return components
    }

    private static func components(ofRelativePath relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.utf8.contains(0)
        else {
            throw RadrootsGovernedFileReadError.invalidRequest
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(
            String.init)
        guard !components.isEmpty,
            components.allSatisfy(isOrdinaryComponent)
        else {
            throw RadrootsGovernedFileReadError.invalidRequest
        }
        return components
    }

    private static func isOrdinaryComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
    }

    private static func openDirectoryTraversal(
        _ components: [String]
    ) throws -> (descriptor: Int32, identities: [FileIdentity]) {
        let rootDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard rootDescriptor >= 0 else {
            throw RadrootsGovernedFileReadError.ioFailure
        }

        var currentDescriptor = rootDescriptor
        var identities: [FileIdentity]
        do {
            identities = [try fileIdentity(of: rootDescriptor)]
        } catch {
            close(rootDescriptor)
            throw error
        }
        do {
            for component in components {
                let nextDescriptor = try openComponent(
                    component,
                    relativeTo: currentDescriptor,
                    expectingDirectory: true
                )
                close(currentDescriptor)
                currentDescriptor = nextDescriptor
                identities.append(try fileIdentity(of: nextDescriptor))
            }
            return (currentDescriptor, identities)
        } catch {
            close(currentDescriptor)
            throw error
        }
    }

    private static func openComponent(
        _ component: String,
        relativeTo parentDescriptor: Int32,
        expectingDirectory: Bool
    ) throws -> Int32 {
        var flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        if expectingDirectory {
            flags |= O_DIRECTORY
        }
        let descriptor = component.withCString { pointer in
            Darwin.openat(parentDescriptor, pointer, flags)
        }
        guard descriptor >= 0 else {
            throw classifiedOpenError(errno)
        }
        do {
            let identity = try fileIdentity(of: descriptor)
            if expectingDirectory, !identity.isDirectory {
                throw RadrootsGovernedFileReadError.invalidObject
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func classifiedOpenError(_ code: Int32) -> RadrootsGovernedFileReadError {
        switch code {
        case ENOENT:
            .unavailable
        case ELOOP, ENOTDIR:
            .invalidObject
        default:
            .ioFailure
        }
    }

    private static func fileIdentity(of descriptor: Int32) throws -> FileIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_dev >= 0,
            metadata.st_size >= 0
        else {
            throw RadrootsGovernedFileReadError.ioFailure
        }
        return FileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            mode: UInt32(metadata.st_mode),
            byteCount: UInt64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private static func readBounded(
        _ descriptor: Int32,
        admittedByteCount: UInt64,
        maximumBytes: Int
    ) throws -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(admittedByteCount))
        var buffer = [UInt8](repeating: 0, count: readBufferByteCount)
        let maximumPlusOne = maximumBytes + 1

        while true {
            let remaining = maximumPlusOne - bytes.count
            guard remaining > 0 else {
                throw RadrootsGovernedFileReadError.tooLarge
            }
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requested)
            }
            if count == 0 {
                return bytes
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw RadrootsGovernedFileReadError.ioFailure
            }
            bytes.append(contentsOf: buffer.prefix(count))
            if bytes.count > maximumBytes {
                throw RadrootsGovernedFileReadError.tooLarge
            }
        }
    }

    private static func validateCurrentBinding(
        directoryComponents: [String],
        admittedDirectories: [FileIdentity],
        leaf: String,
        admittedFile: FileIdentity
    ) throws {
        let currentTraversal: (descriptor: Int32, identities: [FileIdentity])
        do {
            currentTraversal = try openDirectoryTraversal(directoryComponents)
        } catch {
            throw RadrootsGovernedFileReadError.changedDuringRead
        }
        defer { close(currentTraversal.descriptor) }
        guard currentTraversal.identities.count == admittedDirectories.count,
            zip(currentTraversal.identities, admittedDirectories).allSatisfy({ current, admitted in
                current.isSameDirectoryObject(as: admitted)
            })
        else {
            throw RadrootsGovernedFileReadError.changedDuringRead
        }

        let currentFileDescriptor: Int32
        do {
            currentFileDescriptor = try openComponent(
                leaf,
                relativeTo: currentTraversal.descriptor,
                expectingDirectory: false
            )
        } catch {
            throw RadrootsGovernedFileReadError.changedDuringRead
        }
        defer { close(currentFileDescriptor) }
        guard try fileIdentity(of: currentFileDescriptor) == admittedFile else {
            throw RadrootsGovernedFileReadError.changedDuringRead
        }
    }

    private static func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let byteCount: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var isDirectory: Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
    }

    var isRegularFile: Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFREG)
    }

    func isSameDirectoryObject(as other: FileIdentity) -> Bool {
        isDirectory && other.isDirectory && device == other.device && inode == other.inode
    }
}
