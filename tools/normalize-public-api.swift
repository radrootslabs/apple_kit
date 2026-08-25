import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("api_baseline_invalid: \(message)\n".utf8))
    exit(1)
}

private func string(_ object: [String: Any], _ key: String, _ context: String) -> String {
    guard let value = object[key] as? String else {
        fail("\(context) omits \(key)")
    }
    return value
}

private func escaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
}

private func fields(_ values: [String]) -> String {
    values
        .map { "\($0.utf8.count):\(escaped($0))" }
        .joined(separator: "\t")
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    fail("at least one symbol graph is required")
}

var modules = Set<String>()
var rows = Set<String>()

for path in paths.sorted() {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("symbol graph could not be read")
    }
    guard
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let module = root["module"] as? [String: Any],
        let symbols = root["symbols"] as? [[String: Any]],
        let relationships = root["relationships"] as? [[String: Any]]
    else {
        fail("symbol graph shape is invalid")
    }

    let moduleName = string(module, "name", "module")
    modules.insert(moduleName)

    func record(_ row: String) {
        rows.insert(row)
    }

    for symbol in symbols {
        guard
            let kind = symbol["kind"] as? [String: Any],
            let identifier = symbol["identifier"] as? [String: Any],
            let names = symbol["names"] as? [String: Any]
        else {
            fail("symbol shape is invalid")
        }
        let declaration = (symbol["declarationFragments"] as? [[String: Any]] ?? [])
            .map { string($0, "spelling", "declaration fragment") }
            .joined()
        record(fields([
            "symbol",
            moduleName,
            string(kind, "identifier", "symbol kind"),
            string(identifier, "precise", "symbol identifier"),
            string(names, "title", "symbol names"),
            declaration,
        ]))
    }

    for relationship in relationships {
        record(fields([
            "relationship",
            moduleName,
            string(relationship, "kind", "relationship"),
            string(relationship, "source", "relationship"),
            string(relationship, "target", "relationship"),
            relationship["targetFallback"] as? String ?? "",
        ]))
    }
}

guard modules == ["RadrootsKit", "RadrootsKitTesting"] else {
    fail("module inventory is not exact")
}

print("radroots.apple-kit.public-api.v1")
let sortedRows = rows.sorted()
for row in sortedRows {
    print(row)
}
