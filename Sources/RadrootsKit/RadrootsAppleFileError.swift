import Darwin
import Foundation

public enum RadrootsAppleFileError: Error, Equatable, Sendable {
    case invalidRequest
    case notFound
    case permissionDenied
    case transientFailure
    case permanentFailure
    /// Capacity is exhausted. Earlier installation may still require reconciliation.
    case spaceInsufficient
}

extension RadrootsAppleFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The file request is invalid."
        case .notFound: "The file was not found."
        case .permissionDenied: "File access was denied."
        case .transientFailure: "The file operation could not be completed temporarily."
        case .permanentFailure: "The file operation could not be completed."
        case .spaceInsufficient: "There is not enough storage space to complete the file operation."
        }
    }
}

extension RadrootsAppleFileError {
    /// Call only with errno captured from an actually failed system call.
    static func posix(_ code: Int32) -> Self {
        code == ENOSPC || code == EDQUOT ? .spaceInsufficient : .permanentFailure
    }

    static func classified(_ error: any Error) -> Self {
        if let typed = error as? Self { return typed }
        var current = error as NSError
        // Foundation may wrap a POSIX failure. Bound traversal even for a
        // malformed/cyclic error chain; never retain paths or diagnostic text.
        for _ in 0 ..< 8 {
            if current.domain == NSPOSIXErrorDomain,
               current.code == Int(ENOSPC) || current.code == Int(EDQUOT) {
                return .spaceInsufficient
            }
            if current.domain == NSCocoaErrorDomain,
               current.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return .spaceInsufficient
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return .permanentFailure
    }
}
