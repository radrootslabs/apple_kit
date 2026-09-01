import Foundation

public enum RadrootsBackgroundTaskKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case appRefresh
    case processing
}

public enum RadrootsBackgroundTaskError: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case schedulerFailure
}

extension RadrootsBackgroundTaskError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The background task request is invalid."
        case .unavailable: "Background tasks are unavailable."
        case .schedulerFailure: "The background task could not be scheduled."
        }
    }
}

public struct RadrootsBackgroundTaskIdentifier: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: String

    public init(_ value: String) throws {
        rawValue = try RadrootsBackgroundTaskValidation.normalizedIdentifier(value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RadrootsBackgroundTaskRequest: Sendable, Equatable, Hashable {
    public let identifier: RadrootsBackgroundTaskIdentifier
    public let kind: RadrootsBackgroundTaskKind
    public let earliestBeginDate: Date?
    public let requiresNetworkConnectivity: Bool
    public let requiresExternalPower: Bool

    public init(
        identifier: RadrootsBackgroundTaskIdentifier,
        kind: RadrootsBackgroundTaskKind,
        earliestBeginDate: Date? = nil,
        requiresNetworkConnectivity: Bool = false,
        requiresExternalPower: Bool = false
    ) throws {
        try RadrootsBackgroundTaskValidation.validate(
            kind: kind,
            earliestBeginDate: earliestBeginDate,
            requiresNetworkConnectivity: requiresNetworkConnectivity,
            requiresExternalPower: requiresExternalPower
        )
        self.identifier = identifier
        self.kind = kind
        self.earliestBeginDate = earliestBeginDate
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.requiresExternalPower = requiresExternalPower
    }

    public init(
        identifier: String,
        kind: RadrootsBackgroundTaskKind,
        earliestBeginDate: Date? = nil,
        requiresNetworkConnectivity: Bool = false,
        requiresExternalPower: Bool = false
    ) throws {
        try self.init(
            identifier: RadrootsBackgroundTaskIdentifier(identifier),
            kind: kind,
            earliestBeginDate: earliestBeginDate,
            requiresNetworkConnectivity: requiresNetworkConnectivity,
            requiresExternalPower: requiresExternalPower
        )
    }
}

public struct RadrootsBackgroundTaskSnapshot: Sendable, Equatable, Hashable {
    public let identifier: RadrootsBackgroundTaskIdentifier
    public let kind: RadrootsBackgroundTaskKind
    public let earliestBeginDate: Date?
    public let submittedAt: Date
    public let requiresNetworkConnectivity: Bool
    public let requiresExternalPower: Bool

    public init(
        identifier: RadrootsBackgroundTaskIdentifier,
        kind: RadrootsBackgroundTaskKind,
        earliestBeginDate: Date? = nil,
        submittedAt: Date = Date(),
        requiresNetworkConnectivity: Bool = false,
        requiresExternalPower: Bool = false
    ) throws {
        try RadrootsBackgroundTaskValidation.validate(
            kind: kind,
            earliestBeginDate: earliestBeginDate,
            requiresNetworkConnectivity: requiresNetworkConnectivity,
            requiresExternalPower: requiresExternalPower
        )
        guard submittedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsBackgroundTaskError.invalidRequest
        }
        self.identifier = identifier
        self.kind = kind
        self.earliestBeginDate = earliestBeginDate
        self.submittedAt = submittedAt
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.requiresExternalPower = requiresExternalPower
    }

    public init(request: RadrootsBackgroundTaskRequest, submittedAt: Date = Date()) throws {
        try self.init(
            identifier: request.identifier,
            kind: request.kind,
            earliestBeginDate: request.earliestBeginDate,
            submittedAt: submittedAt,
            requiresNetworkConnectivity: request.requiresNetworkConnectivity,
            requiresExternalPower: request.requiresExternalPower
        )
    }
}

public protocol RadrootsBackgroundTaskScheduler: Sendable {
    func submit(_ request: RadrootsBackgroundTaskRequest) async throws
        -> RadrootsBackgroundTaskSnapshot
    func cancel(_ identifier: RadrootsBackgroundTaskIdentifier) async throws
    func cancelAll() async throws
    func pendingTasks() async throws -> [RadrootsBackgroundTaskSnapshot]
}

public struct RadrootsUnavailableBackgroundTaskScheduler: RadrootsBackgroundTaskScheduler, Sendable {
    public init() {}

    public func submit(_: RadrootsBackgroundTaskRequest) async throws
        -> RadrootsBackgroundTaskSnapshot
    {
        throw RadrootsBackgroundTaskError.unavailable
    }

    public func cancel(_: RadrootsBackgroundTaskIdentifier) async throws {
        throw RadrootsBackgroundTaskError.unavailable
    }

    public func cancelAll() async throws {
        throw RadrootsBackgroundTaskError.unavailable
    }

    public func pendingTasks() async throws -> [RadrootsBackgroundTaskSnapshot] {
        throw RadrootsBackgroundTaskError.unavailable
    }
}

public enum RadrootsBackgroundTaskValidation {
    public static func normalizedIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw RadrootsBackgroundTaskError.invalidRequest
        }
        guard trimmed.count <= 255 else {
            throw RadrootsBackgroundTaskError.invalidRequest
        }
        guard
            trimmed.range(
            of: "^[a-z0-9][a-z0-9._-]*[a-z0-9]$|^[a-z0-9]$",
            options: .regularExpression
            ) != nil
        else {
            throw RadrootsBackgroundTaskError.invalidRequest
        }
        guard !trimmed.contains("..") else {
            throw RadrootsBackgroundTaskError.invalidRequest
        }
        return trimmed
    }

    public static func validate(
        kind: RadrootsBackgroundTaskKind,
        earliestBeginDate: Date?,
        requiresNetworkConnectivity: Bool,
        requiresExternalPower: Bool
    ) throws {
        if let earliestBeginDate {
            guard earliestBeginDate.timeIntervalSinceReferenceDate.isFinite else {
                throw RadrootsBackgroundTaskError.invalidRequest
            }
        }
        guard kind == .processing || (!requiresNetworkConnectivity && !requiresExternalPower) else {
            throw RadrootsBackgroundTaskError.invalidRequest
        }
    }
}
