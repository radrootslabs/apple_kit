import Foundation

public enum RadrootsExternalActionDestinationKind: String, Sendable, Equatable, Hashable,
    CaseIterable
{
    case appSettings
    case web
    case nostr
    case appleMaps
}

public struct RadrootsExternalActionDestination: Sendable, Equatable, Hashable {
    public let kind: RadrootsExternalActionDestinationKind
    public let url: URL?

    private init(kind: RadrootsExternalActionDestinationKind, url: URL?) {
        self.kind = kind
        self.url = url
    }

    public static let appSettings = RadrootsExternalActionDestination(kind: .appSettings, url: nil)

    public static func web(_ value: String) throws -> Self {
        try Self(kind: .web, url: RadrootsExternalActionValidation.normalizedWebURL(value))
    }

    public static func nostr(_ value: String) throws -> Self {
        try Self(kind: .nostr, url: RadrootsExternalActionValidation.normalizedNostrURI(value))
    }

    public static func appleMaps(_ value: String) throws -> Self {
        try Self(kind: .appleMaps, url: RadrootsExternalActionValidation.normalizedAppleMapsURL(value))
    }

    public static func appleMaps(
        coordinate: RadrootsLocationCoordinate,
        label: String? = nil
    ) throws -> Self {
        try Self(
            kind: .appleMaps,
            url: RadrootsExternalActionValidation.appleMapsURL(coordinate: coordinate, label: label)
        )
    }
}

public struct RadrootsExternalActionRequest: Sendable, Equatable, Hashable {
    public let destination: RadrootsExternalActionDestination

    public init(destination: RadrootsExternalActionDestination) {
        self.destination = destination
    }
}

public struct RadrootsExternalActionCapability: Sendable, Equatable, Hashable {
    public let destination: RadrootsExternalActionDestination
    public let canOpen: Bool

    public init(destination: RadrootsExternalActionDestination, canOpen: Bool) {
        self.destination = destination
        self.canOpen = canOpen
    }
}

public enum RadrootsExternalActionError: Error, Equatable, Sendable {
    case invalidRequest
    case blockedByPolicy
    case unavailable
    case transientFailure
    case permanentFailure
}

extension RadrootsExternalActionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The external action request is invalid."
        case .blockedByPolicy: "The external action is blocked by policy."
        case .unavailable: "The external action is unavailable."
        case .transientFailure: "The external action could not be completed temporarily."
        case .permanentFailure: "The external action could not be completed."
        }
    }
}

public protocol RadrootsExternalActions: Sendable {
    func canOpen(_ destination: RadrootsExternalActionDestination) async
        -> RadrootsExternalActionCapability
    func open(_ request: RadrootsExternalActionRequest) async throws
}

public enum RadrootsExternalActionValidation {
    public static func normalizedWebURL(_ value: String) throws -> URL {
        let trimmed = try trimmedNonEmpty(value, field: "web url")
        try rejectWhitespaceOrControl(trimmed, field: "web url")
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else {
            throw RadrootsExternalActionError.blockedByPolicy
        }
        return url
    }

    public static func normalizedNostrURI(_ value: String) throws -> URL {
        let trimmed = try trimmedNonEmpty(value, field: "nostr uri")
        try rejectWhitespaceOrControl(trimmed, field: "nostr uri")
        guard trimmed.lowercased().hasPrefix("nostr:") else {
            throw RadrootsExternalActionError.blockedByPolicy
        }
        let payload = String(trimmed.dropFirst("nostr:".count))
        guard !payload.isEmpty else {
            throw RadrootsExternalActionError.invalidRequest
        }
        guard payload.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw RadrootsExternalActionError.invalidRequest
        }
        let normalizedPayload = payload.lowercased()
        if normalizedPayload.hasPrefix("nsec") {
            throw RadrootsExternalActionError.blockedByPolicy
        }
        let allowedPrefixes = ["npub1", "nprofile1", "note1", "nevent1", "naddr1", "nrelay1"]
        guard allowedPrefixes.contains(where: { normalizedPayload.hasPrefix($0) }) else {
            throw RadrootsExternalActionError.blockedByPolicy
        }
        guard let url = URL(string: "nostr:\(normalizedPayload)") else {
            throw RadrootsExternalActionError.invalidRequest
        }
        return url
    }

    public static func normalizedAppleMapsURL(_ value: String) throws -> URL {
        let trimmed = try trimmedNonEmpty(value, field: "apple maps url")
        try rejectWhitespaceOrControl(trimmed, field: "apple maps url")
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "maps.apple.com",
              components.user == nil,
              components.password == nil,
              let url = components.url
        else {
            throw RadrootsExternalActionError.blockedByPolicy
        }
        return url
    }

    public static func appleMapsURL(
        coordinate: RadrootsLocationCoordinate,
        label: String? = nil
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        var queryItems = [
            URLQueryItem(
                name: "ll",
                value: "\(coordinate.latitude),\(coordinate.longitude)"
            )
        ]
        if let label {
            let normalizedLabel = try normalizedOptionalLabel(label)
            if let normalizedLabel {
                queryItems.append(URLQueryItem(name: "q", value: normalizedLabel))
            }
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw RadrootsExternalActionError.permanentFailure
        }
        return url
    }

    static func trimmedNonEmpty(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsExternalActionError.invalidRequest
        }
        return trimmed
    }

    static func rejectWhitespaceOrControl(_ value: String, field: String) throws {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw RadrootsExternalActionError.invalidRequest
        }
    }

    static func normalizedOptionalLabel(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let forbidden = CharacterSet.controlCharacters
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw RadrootsExternalActionError.invalidRequest
        }
        return trimmed
    }
}
