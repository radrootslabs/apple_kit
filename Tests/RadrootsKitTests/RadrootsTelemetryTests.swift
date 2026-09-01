import Foundation
import Testing

@testable import RadrootsKit

@Test func telemetryEventNormalizesSafeIdentifiersAndFields() throws {
    let event = try RadrootsTelemetryEvent(
        name: "field_ios.startup.begin",
        category: "field_ios",
        level: .notice,
        message: " Startup began ",
        fields: [
            .integer("configured_relay_count", 3),
            .bool("has_identity", true),
            .string("relay_light", "green"),
        ],
        occurredAt: Date(timeIntervalSince1970: 42)
    )

    #expect(event.name == "field_ios.startup.begin")
    #expect(event.category == "field_ios")
    #expect(event.level == .notice)
    #expect(event.message == "Startup began")
    #expect(event.fields.map(\.key) == ["configured_relay_count", "has_identity", "relay_light"])
    #expect(event.occurredAt == Date(timeIntervalSince1970: 42))
}

@Test func telemetryEventRejectsUnsafeShape() throws {
    #expect(throws: RadrootsTelemetryError.invalidRequest) {
        _ = try RadrootsTelemetryEvent(name: "FieldIos.Startup")
    }
    #expect(throws: RadrootsTelemetryError.invalidRequest) {
        _ = try RadrootsTelemetryField.string("Relay Light", "green")
    }
    #expect(throws: RadrootsTelemetryError.invalidRequest) {
        _ = try RadrootsTelemetryField.double("elapsed_seconds", .infinity)
    }
    #expect(throws: RadrootsTelemetryError.invalidRequest) {
        _ = try RadrootsTelemetryEvent(
            name: "field_ios.relay.status",
            fields: [
                .integer("connected_count", 1),
                .integer("connected_count", 2),
            ]
        )
    }
}

@Test func telemetryRedactionPolicyRedactsSecretsPathsAndUnsafeKeys() throws {
    let policy = RadrootsTelemetryRedactionPolicy.default
    let secretHex = String(repeating: "a", count: 64)
    let event = try RadrootsTelemetryEvent(
        name: "field_ios.nsec_startup",
        category: "field_ios",
        level: .error,
        message: "failed with nsec1secretvalue",
        fields: [
            .string("relay_error", "path /Users/person/container"),
            .string("selected_secret_key_name", "field identity"),
            .string("public_reason", "event id \(secretHex)"),
            .integer("absolute_path_count", 1),
            .stringList("relay_urls", ["wss://radroots.org", "nsec1relay"]),
        ]
    )

    let redacted = policy.redacted(event)

    #expect(redacted.name == "redacted")
    #expect(redacted.category == "field_ios")
    #expect(redacted.message == "[redacted]")
    #expect(redacted.fields[0].value == .string("[redacted]"))
    #expect(redacted.fields[1].value == .string("[redacted]"))
    #expect(redacted.fields[2].value == .string("[redacted]"))
    #expect(redacted.fields[3].value == .string("[redacted]"))
    #expect(redacted.fields[4].value == .stringList(["wss://radroots.org", "[redacted]"]))
}

@Test func redactingTelemetryRecordsOnlyRedactedEvents() async throws {
    let recorder = RadrootsTelemetryProbe()
    let telemetry = RadrootsRedactingTelemetry(sink: recorder)
    let event = try RadrootsTelemetryEvent(
        name: "field_ios.identity.import",
        message: "imported nsec1secret",
        fields: [
            .string("identity_state", "imported")
        ]
    )

    await telemetry.record(event)

    let events = await recorder.recordedEvents
    #expect(events.count == 1)
    #expect(events[0].message == "[redacted]")
    #expect(events[0].fields[0].value == .string("imported"))
}

@Test func multiplexTelemetryForwardsToAllSinks() async throws {
    let first = RadrootsTelemetryProbe()
    let second = RadrootsTelemetryProbe()
    let telemetry = RadrootsMultiplexTelemetry([first, second])
    let event = try RadrootsTelemetryEvent(name: "field_ios.startup.success")

    await telemetry.record(event)

    #expect(await first.recordedEventNames == ["field_ios.startup.success"])
    #expect(await second.recordedEventNames == ["field_ios.startup.success"])
}

private actor RadrootsTelemetryProbe: RadrootsTelemetry {
    private var eventsValue: [RadrootsTelemetryEvent] = []

    func record(_ event: RadrootsTelemetryEvent) async {
        eventsValue.append(event)
    }

    var recordedEvents: [RadrootsTelemetryEvent] {
        eventsValue
    }

    var recordedEventNames: [String] {
        eventsValue.map(\.name)
    }
}
