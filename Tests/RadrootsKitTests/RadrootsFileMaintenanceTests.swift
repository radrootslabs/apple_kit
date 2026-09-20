import Darwin
import Foundation
@testable import RadrootsKit
import Testing

@Test func fileMaintenanceSharedUseExcludesMaintenanceUntilLastRelease() throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    var first = try #require(try f.coordinator.reserveUse())
    var second = try f.coordinator.reserveUse()
    #expect(second != nil)
    try first.validate()
    #expect(try f.coordinator.reserveMaintenance() == nil)
    second = nil
    #expect(second == nil)
    #expect(try f.coordinator.reserveMaintenance() == nil)
    // Retain first explicitly through the final contention observation.
    withExtendedLifetime(first) {}
    // A distinct root remains independent.
    first = try #require(try RadrootsAppleFileMaintenance(root: f.base.appendingPathComponent("other")).reserveUse())
    let maintenance = try #require(try f.coordinator.reserveMaintenance())
    #expect(try f.coordinator.reserveUse() == nil)
    #expect(try f.coordinator.reserveMaintenance() == nil)
    try maintenance.validate()
    withExtendedLifetime((first, maintenance)) {}
}

@Test func fileMaintenanceScanRetainsExclusiveOwnerAndRejectsCrossScanEntry() throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    try f.write("blob")
    var reservation = try f.coordinator.reserveMaintenance()
    var scan: RadrootsFileMaintenanceScan? = try #require(reservation).openDirectory()
    reservation = nil
    #expect(try f.coordinator.reserveUse() == nil)
    let entry = try #require(scan).next().entries.first
    let captured = try #require(entry)
    scan = nil
    let next = try #require(try f.coordinator.reserveMaintenance())
    let newScan = try next.openDirectory()
    #expect(throws: RadrootsAppleFileError.invalidRequest) { _ = try newScan.remove(captured) }
    #expect(FileManager.default.fileExists(atPath: f.path("blob").path))
}

@Test func fileMaintenanceBoundedTraversalAndInterruptedCollectionResume() throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    for index in 0 ..< 150 {
        try f.write("blob-\(index)")
    }
    do {
        let reservation = try #require(try f.coordinator.reserveMaintenance())
        let scan = try reservation.openDirectory()
        #expect(throws: RadrootsAppleFileError.invalidRequest) { _ = try scan.next(limit: 0) }
        #expect(throws: RadrootsAppleFileError.invalidRequest) { _ = try scan.next(limit: 65) }
        let page = try scan.next(limit: 7)
        #expect(page.scannedEntries == 7 && !page.reachedEnd)
        #expect(page.entries.count <= 7)
        for entry in page.entries {
            #expect(try scan.remove(entry))
        }
    }
    let reservation = try #require(try f.coordinator.reserveMaintenance())
    let scan = try reservation.openDirectory()
    var names: Set<String> = []
    var ended = false
    for _ in 0 ..< 30 {
        let page = try scan.next(limit: 7)
        #expect(page.scannedEntries <= 7 && page.entries.count <= 7)
        for entry in page.entries {
            #expect(names.insert(entry.name).inserted)
            #expect(entry.kind == .regularFile && entry.sizeBytes == 3)
        }
        if page.reachedEnd {
            ended = true; break
        }
    }
    #expect(ended && names.count >= 143 && names.count < 150)
    #expect(try scan.next().reachedEnd)
    #expect(!names.contains(RadrootsFileMaintenanceGate.name))
}

@Test func fileMaintenanceRetainsReplacedChangedHardlinkedAndNonregularFiles() throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    for name in ["changed", "replaced", "hardlink", "removed", "eligible"] {
        try f.write(name)
    }
    try FileManager.default.linkItem(at: f.path("hardlink"), to: f.path("alias"))
    try FileManager.default.createDirectory(at: f.path("directory"), withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: f.path("symlink"), withDestinationURL: f.path("eligible"))
    let reservation = try #require(try f.coordinator.reserveMaintenance())
    let scan = try reservation.openDirectory()
    let entries = try Dictionary(uniqueKeysWithValues: scan.next().entries.map { ($0.name, $0) })
    try Data("different bytes".utf8).write(to: f.path("changed"))
    try Data("new".utf8).write(to: f.path("replaced"), options: .atomic)
    try FileManager.default.removeItem(at: f.path("removed"))
    for name in ["changed", "replaced", "hardlink", "alias", "directory", "symlink", "removed"] {
        #expect(try !scan.remove(#require(entries[name])))
    }
    #expect(try scan.remove(#require(entries["eligible"])))
    #expect(try !scan.remove(#require(entries["eligible"])))
    #expect(try Data(contentsOf: f.path("replaced")) == Data("new".utf8))
    #expect(try Data(contentsOf: f.path("changed")) == Data("different bytes".utf8))
}

@Test func fileMaintenanceRejectsChangedParentsCoordinationAndUnsafePaths() throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    try f.write("blob")
    let reservation = try #require(try f.coordinator.reserveMaintenance())
    for path in ["..", "../root", "/root", "root//child", "root/", "\0"] {
        #expect(throws: RadrootsAppleFileError.invalidRequest) { _ = try reservation.openDirectory(relativePath: path) }
    }
    try FileManager.default.createSymbolicLink(at: f.path("link"), withDestinationURL: f.base)
    #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try reservation.openDirectory(relativePath: "link") }
    let scan = try reservation.openDirectory()
    let blob = try #require(try scan.next().entries.first { $0.name == "blob" })
    try Data().write(to: f.path(RadrootsFileMaintenanceGate.name), options: .atomic)
    #expect(throws: RadrootsAppleFileError.permanentFailure) { try reservation.validate() }
    #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try scan.remove(blob) }
    #expect(FileManager.default.fileExists(atPath: f.path("blob").path))
    try FileManager.default.moveItem(at: f.root, to: f.base.appendingPathComponent("moved"))
    try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
    #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try scan.next() }
}

@Test func fileMaintenanceSupportsBoundedSubdirectoryInspection() throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    try FileManager.default.createDirectory(at: f.path("staging"), withIntermediateDirectories: false)
    try f.write("staging/blob")
    let reservation = try #require(try f.coordinator.reserveMaintenance())
    let scan = try reservation.openDirectory(relativePath: "staging")
    let blob = try #require(try scan.next().entries.first)
    #expect(blob.name == "blob")
    #expect(try scan.remove(blob))
    #expect(FileManager.default.fileExists(atPath: f.path(RadrootsFileMaintenanceGate.name).path))
}

@Test func fileMaintenanceCancellationDoesNotReleaseUndrainedUse() async throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    let latch = FileMaintenanceLatch()
    let task = try holdMaintenanceUse(#require(try f.coordinator.reserveUse()), latch: latch)
    task.cancel()
    #expect(try f.coordinator.reserveMaintenance() == nil)
    await latch.open()
    try await task.value
    #expect(try f.coordinator.reserveMaintenance() != nil)
}

private func holdMaintenanceUse(_ lease: RadrootsFileUseReservation, latch: FileMaintenanceLatch) throws -> Task<Void, Error> {
    try lease.validate()
    return Task {
        defer { withExtendedLifetime(lease) {} }
        await latch.wait()
        try lease.validate()
    }
}

@Test func fileMaintenanceConcurrentReadersAndCollectorsNeverOverlap() async throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    let probe = FileMaintenanceProbe()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for owner in 0 ..< 8 {
            group.addTask {
                for _ in 0 ..< 30 {
                    if owner < 6 {
                        if let lease = try f.coordinator.reserveUse() {
                            await probe.enter(exclusive: false)
                            await Task.yield()
                            await probe.leave(exclusive: false)
                            withExtendedLifetime(lease) {}
                        }
                    } else if let maintenance = try f.coordinator.reserveMaintenance() {
                        await probe.enter(exclusive: true)
                        await Task.yield()
                        await probe.leave(exclusive: true)
                        withExtendedLifetime(maintenance) {}
                    }
                    await Task.yield()
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(await probe.violations == 0)
    #expect(await probe.completed > 0)
    #expect(try f.coordinator.reserveMaintenance() != nil)
}

@Test func fileMaintenanceRejectsInvalidCoordinationAndReplacedParent() throws {
    for variant in ["nonempty", "symlink", "hardlink", "parent"] {
        let f = try FileMaintenanceFixture()
        defer { f.remove() }
        try f.write("blob")
        let gate = f.path(RadrootsFileMaintenanceGate.name)
        switch variant {
        case "nonempty": try Data("unknown".utf8).write(to: gate)
        case "symlink": try FileManager.default.createSymbolicLink(at: gate, withDestinationURL: f.path("blob"))
        case "hardlink":
            try Data().write(to: gate)
            try FileManager.default.linkItem(at: gate, to: f.path("alias"))
        default:
            let reservation = try #require(try f.coordinator.reserveMaintenance())
            let scan = try reservation.openDirectory()
            let entry = try #require(try scan.next().entries.first)
            try FileManager.default.moveItem(at: f.root, to: f.base.appendingPathComponent("moved"))
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
            #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try scan.remove(entry) }
            #expect(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("moved/blob").path))
            continue
        }
        #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try f.coordinator.reserveUse() }
        #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try f.coordinator.reserveMaintenance() }
    }
}

private actor FileMaintenanceProbe {
    private var readers = 0
    private var writers = 0
    private(set) var violations = 0
    private(set) var completed = 0
    func enter(exclusive: Bool) {
        if writers != 0 || exclusive && readers != 0 {
            violations += 1
        }
        if exclusive {
            writers += 1
        } else {
            readers += 1
        }
    }

    func leave(exclusive: Bool) {
        if exclusive {
            writers -= 1
        } else {
            readers -= 1
        }
        completed += 1
    }
}

@Test func fileMaintenanceFailedScanCannotResumeAfterParentRestoration() throws {
    let f = try FileMaintenanceFixture()
    defer { f.remove() }
    try f.write("blob")
    let reservation = try #require(try f.coordinator.reserveMaintenance())
    let scan = try reservation.openDirectory()
    _ = try scan.next(limit: 1)
    let moved = f.base.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: f.root, to: moved)
    try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
    #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try scan.next() }
    try FileManager.default.removeItem(at: f.root)
    try FileManager.default.moveItem(at: moved, to: f.root)
    try reservation.validate()
    #expect(throws: RadrootsAppleFileError.permanentFailure) { _ = try scan.next() }
    let fresh = try reservation.openDirectory()
    #expect(try fresh.next().entries.map(\.name) == ["blob"])
}

private actor FileMaintenanceLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct FileMaintenanceFixture: Sendable {
    let base: URL
    let root: URL
    var coordinator: RadrootsAppleFileMaintenance {
        RadrootsAppleFileMaintenance(root: root)
    }

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let pointer = try #require(raw.path.withCString { Darwin.realpath($0, nil) })
        defer { Darwin.free(pointer) }
        base = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func write(_ name: String) throws {
        try Data("old".utf8).write(to: path(name))
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
