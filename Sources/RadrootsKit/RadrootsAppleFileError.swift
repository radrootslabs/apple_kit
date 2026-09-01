import Foundation

public enum RadrootsAppleFileError: Error, Equatable, Sendable {
    case invalidRequest
    case notFound
    case permissionDenied
    case transientFailure
    case permanentFailure
}

extension RadrootsAppleFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The file request is invalid."
        case .notFound: "The file was not found."
        case .permissionDenied: "File access was denied."
        case .transientFailure: "The file operation could not be completed temporarily."
        case .permanentFailure: "The file operation could not be completed."
        }
    }
}
