import Darwin
import Foundation
import Testing

@testable import RadrootsKit

@Test func governedFileReaderReadsAnExactBoundedRegularFile() throws {
    try withGovernedFileFixture { root in
        let directory = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let payload = Data("governed".utf8)
        try payload.write(to: directory.appendingPathComponent("control.json"))

        #expect(
            try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: "config/control.json",
                maximumBytes: payload.count
            ) == payload
        )
    }
}

@Test(arguments: ["", "/absolute", ".", "..", "config/", "config//control", "config/../control"])
func governedFileReaderRejectsInvalidRelativePaths(_ relativePath: String) throws {
    try withGovernedFileFixture { root in
        #expect(throws: RadrootsGovernedFileReadError.invalidRequest) {
            _ = try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: relativePath,
                maximumBytes: 16
            )
        }
    }
}

@Test func governedFileReaderRejectsRootIntermediateAndLeafSymlinks() throws {
    try withGovernedFileFixture { root in
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try Data("value".utf8).write(to: actual.appendingPathComponent("control"))

        let rootLink = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-link")
        defer { try? FileManager.default.removeItem(at: rootLink) }
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        #expect(throws: RadrootsGovernedFileReadError.invalidObject) {
            _ = try RadrootsGovernedFileReader.read(
                root: rootLink,
                relativePath: "actual/control",
                maximumBytes: 16
            )
        }

        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: actual)
        #expect(throws: RadrootsGovernedFileReadError.invalidObject) {
            _ = try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: "directory-link/control",
                maximumBytes: 16
            )
        }

        let leafLink = root.appendingPathComponent("leaf-link")
        try FileManager.default.createSymbolicLink(
            at: leafLink,
            withDestinationURL: actual.appendingPathComponent("control")
        )
        #expect(throws: RadrootsGovernedFileReadError.invalidObject) {
            _ = try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: "leaf-link",
                maximumBytes: 16
            )
        }
    }
}

@Test func governedFileReaderRejectsDirectoriesFifosAndOversizedFiles() throws {
    try withGovernedFileFixture { root in
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(throws: RadrootsGovernedFileReadError.invalidObject) {
            _ = try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: "directory",
                maximumBytes: 16
            )
        }

        let fifo = root.appendingPathComponent("control.fifo")
        let fifoResult = fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) }
        #expect(fifoResult == 0)
        #expect(throws: RadrootsGovernedFileReadError.invalidObject) {
            _ = try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: "control.fifo",
                maximumBytes: 16
            )
        }

        try Data(repeating: 0x41, count: 17).write(to: root.appendingPathComponent("oversized"))
        #expect(throws: RadrootsGovernedFileReadError.tooLarge) {
            _ = try RadrootsGovernedFileReader.read(
                root: root,
                relativePath: "oversized",
                maximumBytes: 16
            )
        }
    }
}

@Test func governedFileReaderRejectsLeafReplacementAfterAdmission() throws {
    try withGovernedFileFixture { root in
        let file = root.appendingPathComponent("control")
        let retained = root.appendingPathComponent("retained")
        try Data("original".utf8).write(to: file)

        #expect(throws: RadrootsGovernedFileReadError.changedDuringRead) {
            _ = try RadrootsGovernedFileReader.readForTesting(
                root: root,
                relativePath: "control",
                maximumBytes: 16
            ) {
                try FileManager.default.moveItem(at: file, to: retained)
                try Data("foreign".utf8).write(to: file)
            }
        }
    }
}

@Test func governedFileReaderRejectsDirectoryReplacementAfterAdmission() throws {
    try withGovernedFileFixture { root in
        let directory = root.appendingPathComponent("config", isDirectory: true)
        let retained = root.appendingPathComponent("retained", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: directory.appendingPathComponent("control"))

        #expect(throws: RadrootsGovernedFileReadError.changedDuringRead) {
            _ = try RadrootsGovernedFileReader.readForTesting(
                root: root,
                relativePath: "config/control",
                maximumBytes: 16
            ) {
                try FileManager.default.moveItem(at: directory, to: retained)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false)
                try Data("foreign".utf8).write(to: directory.appendingPathComponent("control"))
            }
        }
    }
}

@Test func governedFileReaderRejectsInPlaceMutationAfterAdmission() throws {
    try withGovernedFileFixture { root in
        let file = root.appendingPathComponent("control")
        try Data("original".utf8).write(to: file)

        #expect(throws: RadrootsGovernedFileReadError.changedDuringRead) {
            _ = try RadrootsGovernedFileReader.readForTesting(
                root: root,
                relativePath: "control",
                maximumBytes: 16
            ) {
                try Data("mutated-longer".utf8).write(to: file)
            }
        }
    }
}

@Test func governedFileReaderErrorsContainNoPathOrContent() throws {
    let canaries = ["/private/sensitive/control.json", "secret-canary"]
    let errors: [RadrootsGovernedFileReadError] = [
        .invalidRequest,
        .unavailable,
        .invalidObject,
        .tooLarge,
        .changedDuringRead,
        .ioFailure,
    ]
    for error in errors {
        let rendered = String(reflecting: error)
        #expect(canaries.allSatisfy { !rendered.contains($0) })
    }
}

private func withGovernedFileFixture(
    _ body: (URL) throws -> Void
) throws {
    let unresolvedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("radroots-governed-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: false)
    guard let resolvedPointer = unresolvedRoot.path.withCString({ Darwin.realpath($0, nil) }) else {
        throw RadrootsGovernedFileReadError.ioFailure
    }
    defer { Darwin.free(resolvedPointer) }
    let root = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
