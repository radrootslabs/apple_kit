import Foundation

public enum RadrootsAppleSecurityError: Error, Equatable, Sendable {
    case invalidRequest
    case notFound
    case permissionDenied
    case userCancelled
    case transientFailure
    case unavailable
    case permanentFailure
    case keychainFailure
}

extension RadrootsAppleSecurityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The secure-store request is invalid."
        case .notFound: "The secure-store item was not found."
        case .permissionDenied: "Secure-store access was denied."
        case .userCancelled: "Secure-store access was cancelled."
        case .transientFailure: "The secure-store operation could not be completed temporarily."
        case .unavailable: "The secure store is unavailable."
        case .permanentFailure: "The secure-store operation could not be completed."
        case .keychainFailure: "The secure-store operation failed."
        }
    }
}
