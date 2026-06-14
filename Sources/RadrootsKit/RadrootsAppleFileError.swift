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
        case .invalidRequest(let message):
            message
        case .notFound(let message):
            message
        case .permissionDenied(let message):
            message
        case .transientFailure(let message):
            message
        case .permanentFailure(let message):
            message
        }
    }
}
