import Foundation

public enum RadrootsAppleSecurityError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case notFound(String)
    case permissionDenied(String)
    case userCancelled(String)
    case transientFailure(String)
    case unavailable(String)
    case permanentFailure(String)
    case keychainStatus(Int32, String)
}

extension RadrootsAppleSecurityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        case let .notFound(message):
            message
        case let .permissionDenied(message):
            message
        case let .userCancelled(message):
            message
        case let .transientFailure(message):
            message
        case let .unavailable(message):
            message
        case let .permanentFailure(message):
            message
        case let .keychainStatus(_, message):
            message
        }
    }
}
