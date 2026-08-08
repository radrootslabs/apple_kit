import RadrootsKit
import RadrootsKitTesting
import Testing

@Test func recordingTelemetryStoresEventsInOrderAndFiltersByLevel() async throws {
    let telemetry = RadrootsRecordingTelemetry(minimumLevel: .warning)
    let debug = try RadrootsTelemetryEvent(name: "field_ios.startup.debug", level: .debug)
    let warning = try RadrootsTelemetryEvent(name: "field_ios.relay.warning", level: .warning)
    let critical = try RadrootsTelemetryEvent(name: "field_ios.identity.critical", level: .critical)

    await telemetry.record(debug)
    await telemetry.record(warning)
    await telemetry.record(critical)

    #expect(await telemetry.recordedEventCount == 2)
    #expect(await telemetry.recordedEventNames == [
        "field_ios.relay.warning",
        "field_ios.identity.critical",
    ])
    #expect(await telemetry.events(named: "field_ios.relay.warning").count == 1)

    await telemetry.reset()

    #expect(await telemetry.recordedEventCount == 0)
}
