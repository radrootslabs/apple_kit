import Foundation

public enum RadrootsAppleFileError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case notFound(String)
    case permissionDenied(String)
    case transientFailure(String)
    case permanentFailure(String)
}

extension RadrootsAppleFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        case let .notFound(message):
            message
        case let .permissionDenied(message):
            message
        case let .transientFailure(message):
            message
        case let .permanentFailure(message):
            message
        }
    }
}
