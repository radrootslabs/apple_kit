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
        case .invalidRequest(let message):
            message
        case .notFound(let message):
            message
        case .permissionDenied(let message):
            message
        case .userCancelled(let message):
            message
        case .transientFailure(let message):
            message
        case .unavailable(let message):
            message
        case .permanentFailure(let message):
            message
        case .keychainStatus(_, let message):
            message
        }
    }
}
