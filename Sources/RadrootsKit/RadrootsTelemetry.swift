import Foundation

public enum RadrootsTelemetryError: Error, Equatable, Sendable {
    case invalidRequest(String)
}

extension RadrootsTelemetryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        }
    }
}

public enum RadrootsTelemetryLevel: String, Sendable, Equatable, Hashable, CaseIterable, Comparable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.severity < rhs.severity
    }

    public var severity: Int {
        switch self {
        case .trace:
            0
        case .debug:
            1
        case .info:
            2
        case .notice:
            3
        case .warning:
            4
        case .error:
            5
        case .critical:
            6
        }
    }
}

public enum RadrootsTelemetryFieldValue: Sendable, Equatable, Hashable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case stringList([String])

    public var renderedValue: String {
        switch self {
        case let .string(value):
            value
        case let .integer(value):
            String(value)
        case let .double(value):
            String(value)
        case let .bool(value):
            value ? "true" : "false"
        case let .stringList(value):
            value.joined(separator: ",")
        }
    }

    fileprivate func redacted(
        key: String,
        policy: RadrootsTelemetryRedactionPolicy
    ) -> RadrootsTelemetryFieldValue {
        switch self {
        case let .string(value):
            return .string(policy.redactedString(value, key: key))
        case .integer, .double, .bool:
            return policy.shouldRedactKey(key) ? .string(policy.replacement) : self
        case let .stringList(values):
            if policy.shouldRedactKey(key) {
                return .string(policy.replacement)
            }
            return .stringList(values.map { policy.redactedString($0, key: key) })
        }
    }
}

public struct RadrootsTelemetryField: Sendable, Equatable, Hashable {
    public let key: String
    public let value: RadrootsTelemetryFieldValue

    public init(key: String, value: RadrootsTelemetryFieldValue) throws {
        let normalizedKey = try RadrootsTelemetryValidation.normalizedIdentifier(
            key,
            field: "telemetry field key",
            maximumLength: 80
        )
        try RadrootsTelemetryValidation.validate(value)
        self.key = normalizedKey
        self.value = value
    }

    public static func string(_ key: String, _ value: String) throws -> Self {
        try Self(key: key, value: .string(value))
    }

    public static func integer(_ key: String, _ value: Int) throws -> Self {
        try Self(key: key, value: .integer(Int64(value)))
    }

    public static func integer(_ key: String, _ value: Int64) throws -> Self {
        try Self(key: key, value: .integer(value))
    }

    public static func double(_ key: String, _ value: Double) throws -> Self {
        try Self(key: key, value: .double(value))
    }

    public static func bool(_ key: String, _ value: Bool) throws -> Self {
        try Self(key: key, value: .bool(value))
    }

    public static func stringList(_ key: String, _ value: [String]) throws -> Self {
        try Self(key: key, value: .stringList(value))
    }

    fileprivate init(validatedKey: String, value: RadrootsTelemetryFieldValue) {
        key = validatedKey
        self.value = value
    }

    fileprivate func redacted(policy: RadrootsTelemetryRedactionPolicy) -> Self {
        Self(validatedKey: key, value: value.redacted(key: key, policy: policy))
    }
}

public struct RadrootsTelemetryEvent: Sendable, Equatable, Hashable {
    public let name: String
    public let category: String
    public let level: RadrootsTelemetryLevel
    public let message: String?
    public let fields: [RadrootsTelemetryField]
    public let occurredAt: Date

    public init(
        name: String,
        category: String = "app",
        level: RadrootsTelemetryLevel = .info,
        message: String? = nil,
        fields: [RadrootsTelemetryField] = [],
        occurredAt: Date = Date()
    ) throws {
        let normalizedName = try RadrootsTelemetryValidation.normalizedIdentifier(
            name,
            field: "telemetry event name",
            maximumLength: 120
        )
        let normalizedCategory = try RadrootsTelemetryValidation.normalizedIdentifier(
            category,
            field: "telemetry event category",
            maximumLength: 80
        )
        let normalizedMessage = try RadrootsTelemetryValidation.normalizedMessage(message)
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RadrootsTelemetryError.invalidRequest("telemetry event timestamp must be finite")
        }
        let duplicateFieldKeys = Set(fields.map(\.key)).count != fields.count
        guard !duplicateFieldKeys else {
            throw RadrootsTelemetryError.invalidRequest("telemetry event field keys must be unique")
        }
        self.name = normalizedName
        self.category = normalizedCategory
        self.level = level
        self.message = normalizedMessage
        self.fields = fields
        self.occurredAt = occurredAt
    }

    fileprivate init(
        validatedName: String,
        validatedCategory: String,
        level: RadrootsTelemetryLevel,
        message: String?,
        fields: [RadrootsTelemetryField],
        occurredAt: Date
    ) {
        name = validatedName
        category = validatedCategory
        self.level = level
        self.message = message
        self.fields = fields
        self.occurredAt = occurredAt
    }
}

public struct RadrootsTelemetryRedactionPolicy: Sendable, Equatable, Hashable {
    public let replacement: String
    public let maximumStringLength: Int

    public init(
        replacement: String = "[redacted]",
        maximumStringLength: Int = 160
    ) {
        let normalizedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        self.replacement = normalizedReplacement.isEmpty ? "[redacted]" : normalizedReplacement
        self.maximumStringLength = max(32, maximumStringLength)
    }

    public static let `default` = RadrootsTelemetryRedactionPolicy()

    public func redacted(_ event: RadrootsTelemetryEvent) -> RadrootsTelemetryEvent {
        RadrootsTelemetryEvent(
            validatedName: redactedIdentifier(event.name, fallback: "redacted"),
            validatedCategory: redactedIdentifier(event.category, fallback: "redacted"),
            level: event.level,
            message: event.message.map { redactedString($0, key: "message") },
            fields: event.fields.map { $0.redacted(policy: self) },
            occurredAt: event.occurredAt
        )
    }

    public func redactedString(_ value: String, key: String? = nil) -> String {
        if let key, shouldRedactKey(key) {
            return replacement
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }
        guard !containsUnsafeValue(trimmed) else {
            return replacement
        }
        guard trimmed.count > maximumStringLength else {
            return trimmed
        }
        return String(trimmed.prefix(maximumStringLength))
    }

    public func shouldRedactKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        let unsafeFragments = [
            "absolute_path",
            "body",
            "content",
            "document",
            "file_name",
            "filename",
            "keychain",
            "nsec",
            "password",
            "path",
            "private",
            "secret",
            "selected_secret",
            "text",
            "token",
        ]
        return unsafeFragments.contains { normalized.contains($0) }
    }

    public func containsUnsafeValue(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalized.contains("nsec") {
            return true
        }
        let unsafePathFragments = [
            "/users/",
            "/private/var/",
            "/var/mobile/containers/",
            "/var/folders/",
            "file:///",
        ]
        if unsafePathFragments.contains(where: { normalized.contains($0) }) {
            return true
        }
        return normalized.range(of: "[a-f0-9]{64}", options: .regularExpression) != nil
    }

    private func redactedIdentifier(_ value: String, fallback: String) -> String {
        let redacted = redactedString(value)
        return redacted == replacement ? fallback : redacted
    }
}

public protocol RadrootsTelemetry: Sendable {
    func record(_ event: RadrootsTelemetryEvent) async
}

public struct RadrootsNoopTelemetry: RadrootsTelemetry, Sendable {
    public init() {}

    public func record(_: RadrootsTelemetryEvent) async {}
}

public struct RadrootsRedactingTelemetry: RadrootsTelemetry, Sendable {
    private let sink: any RadrootsTelemetry
    private let policy: RadrootsTelemetryRedactionPolicy

    public init(
        sink: any RadrootsTelemetry,
        policy: RadrootsTelemetryRedactionPolicy = .default
    ) {
        self.sink = sink
        self.policy = policy
    }

    public func record(_ event: RadrootsTelemetryEvent) async {
        await sink.record(policy.redacted(event))
    }
}

public struct RadrootsMultiplexTelemetry: RadrootsTelemetry, Sendable {
    private let sinks: [any RadrootsTelemetry]

    public init(_ sinks: [any RadrootsTelemetry]) {
        self.sinks = sinks
    }

    public func record(_ event: RadrootsTelemetryEvent) async {
        for sink in sinks {
            await sink.record(event)
        }
    }
}

public enum RadrootsTelemetryValidation {
    public static func normalizedIdentifier(
        _ value: String,
        field: String,
        maximumLength: Int
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RadrootsTelemetryError.invalidRequest("\(field) must not be empty")
        }
        guard trimmed.count <= maximumLength else {
            throw RadrootsTelemetryError.invalidRequest("\(field) is too long")
        }
        guard trimmed.range(
            of: "^[a-z][a-z0-9._-]*$",
            options: .regularExpression
        ) != nil else {
            throw RadrootsTelemetryError.invalidRequest("\(field) must use lowercase safe identifier characters")
        }
        return trimmed
    }

    public static func normalizedMessage(_ value: String?) throws -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard doesNotContainControlCharacters(trimmed) else {
            throw RadrootsTelemetryError.invalidRequest("telemetry event message cannot contain control characters")
        }
        guard trimmed.count <= 500 else {
            throw RadrootsTelemetryError.invalidRequest("telemetry event message is too long")
        }
        return trimmed
    }

    public static func validate(_ value: RadrootsTelemetryFieldValue) throws {
        switch value {
        case let .string(string):
            try validateStringValue(string)
        case .integer:
            return
        case let .double(double):
            guard double.isFinite else {
                throw RadrootsTelemetryError.invalidRequest("telemetry double field must be finite")
            }
        case .bool:
            return
        case let .stringList(values):
            guard values.count <= 24 else {
                throw RadrootsTelemetryError.invalidRequest("telemetry string list field is too long")
            }
            for value in values {
                try validateStringValue(value)
            }
        }
    }

    private static func validateStringValue(_ value: String) throws {
        guard doesNotContainControlCharacters(value) else {
            throw RadrootsTelemetryError.invalidRequest("telemetry string field cannot contain control characters")
        }
        guard value.count <= 500 else {
            throw RadrootsTelemetryError.invalidRequest("telemetry string field is too long")
        }
    }

    private static func doesNotContainControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
