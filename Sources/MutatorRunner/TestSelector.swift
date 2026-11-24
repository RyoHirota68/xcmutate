import Foundation
import MutatorCore

/// `--select-tests auto`: finds the tests (`FooTests`, etc.) corresponding to a changed file `Foo.swift` and
/// builds the identifiers passed to `-only-testing`.
///
/// How the correspondence is made (decided by naming conventions only; type information and call relationships are not examined):
/// 1. Among the test files (the path contains a `…Tests` directory, or the name ends with `Tests.swift` / `Test.swift`),
///    the test types declared in files named `FooTests.swift` / `FooTest.swift` / `FooSpec.swift`
/// 2. In any test file, types declared with the name `FooTests` / `FooTest` / `FooSpec` (XCTest classes, Swift Testing `@Suite` types)
///
/// Symbols such as `+` are removed when comparing (`UIView+Layout.swift` → `UIViewLayoutTests`).
public enum TestSelector {
    public struct Match: Codable, Sendable, Hashable {
        public var sourceFile: String
        public var testFile: String
        public var typeName: String
    }

    static let suffixes = ["Tests", "Test", "Spec"]

    static func normalize(_ name: String) -> String {
        String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" })
    }

    static func isTestPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        let name = components.last ?? path
        if suffixes.contains(where: { name.hasSuffix("\($0).swift") }) { return true }
        return components.dropLast().contains { $0.hasSuffix("Tests") || $0 == "Tests" || $0.hasSuffix("Specs") }
    }

    /// Among the names of the types (class / struct / actor / enum) declared in a test file, those that look like tests.
    static func testTypeNames(in source: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|open|nonisolated)\s+)*(?:class|struct|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let ns = source as NSString
        return pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let name = ns.substring(with: match.range(at: 1))
            return suffixes.contains(where: { name.hasSuffix($0) }) ? name : nil
        }
    }

    /// - Parameters:
    ///   - testFiles: Test files (paths relative to root) and their contents.
    public static func matches(sourceFiles: [String], testFiles: [(path: String, source: String)]) -> [Match] {
        var result: [Match] = []
        let declared = testFiles.map { (path: $0.path, types: testTypeNames(in: $0.source)) }
        for file in sourceFiles {
            let base = normalize(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
            guard !base.isEmpty else { continue }
            let wanted = Set(suffixes.map { base + $0 })
            for test in declared {
                let testBase = normalize(URL(fileURLWithPath: test.path).deletingPathExtension().lastPathComponent)
                let fileMatches = wanted.contains(testBase)
                for type in test.types where fileMatches || wanted.contains(type) {
                    result.append(Match(sourceFile: file, testFile: test.path, typeName: type))
                }
            }
        }
        return Array(Set(result)).sorted { ($0.sourceFile, $0.testFile, $0.typeName) < ($1.sourceFile, $1.testFile, $1.typeName) }
    }

    /// A test target in the xctestrun (its name and whether it is a UI test).
    public struct TestTarget: Sendable, Hashable {
        public var name: String
        public var isUITest: Bool
    }

    static func testTargets(xctestrun: URL) -> [TestTarget] {
        guard let data = try? Data(contentsOf: xctestrun),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var targets: [[String: Any]] = []
        if let configurations = plist["TestConfigurations"] as? [[String: Any]] {
            for c in configurations { targets += c["TestTargets"] as? [[String: Any]] ?? [] }
        } else {
            for (key, value) in plist where !key.hasPrefix("__") { if let t = value as? [String: Any] { targets.append(t) } }
        }
        let result = targets.compactMap { t -> TestTarget? in
            guard let name = (t["BlueprintName"] as? String) ?? (t["ProductModuleName"] as? String) else { return nil }
            return TestTarget(name: name, isUITest: (t["IsUITestBundle"] as? Bool) ?? false)
        }
        return Array(Set(result)).sorted { $0.name < $1.name }
    }

    /// Assigns the test types to the test targets of the xctestrun and turns them into `Target/Type` identifiers.
    /// If the test file's path has a directory named after a target, that target is used; otherwise, if there is exactly one
    /// non-UI-test target, that one is used. `nil` if it cannot be decided (falls back to all tests).
    public static func identifiers(for matches: [Match], targets: [TestTarget]) -> [String]? {
        let unitTargets = targets.filter { !$0.isUITest }
        var ids: Set<String> = []
        for match in matches {
            let components = Set(match.testFile.split(separator: "/").map(String.init))
            if let target = targets.first(where: { components.contains($0.name) }) {
                ids.insert("\(target.name)/\(match.typeName)")
            } else if unitTargets.count == 1 {
                ids.insert("\(unitTargets[0].name)/\(match.typeName)")
            } else {
                return nil
            }
        }
        return ids.isEmpty ? nil : ids.sorted()
    }
}

/// `xcmutate.accepted.json`: mutants accepted as equivalent mutants (committed and reviewed just like code).
public struct AcceptedFile: Codable, Sendable {
    public static let defaultName = ToolNaming.acceptedFileName
    public var version = 1
    /// The scheme of the keys in the file (`MutantKeyScheme.version`), written by `save`.
    public var keyVersion: Int?
    public var accepted: [Entry]

    public struct Entry: Codable, Sendable {
        public var key: String
        public var reason: String
        /// The position and rewrite at the time of acceptance (`file:line:col original -> replacement`). Information for human readers.
        public var location: String?
        public var acceptedAt: String

        public init(key: String, reason: String, location: String?, acceptedAt: String) {
            self.key = key
            self.reason = reason
            self.location = location
            self.acceptedAt = acceptedAt
        }
    }

    public init(accepted: [Entry] = []) { self.accepted = accepted }

    public static func load(_ url: URL) throws -> AcceptedFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return AcceptedFile() }
        return try JSONDecoder().decode(AcceptedFile.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var current = self
        current.keyVersion = MutantKeyScheme.version
        var data = try encoder.encode(current)
        data.append(0x0A)
        try data.write(to: url)
    }

    public var keys: Set<String> { Set(accepted.map(\.key)) }
}

/// When the mutant cannot be identified from the build diagnostics, finds one offending mutant by bisection.
public enum CompileBisector {
    /// - Parameters:
    ///   - base: Mutants known to build when included.
    ///   - suspects: Mutants that include the cause (`base ∪ suspects` fails to build).
    ///   - builds: Whether the build passes with only the specified mutants included.
    /// - Returns: One `c` such that `base' ∪ {c}` fails and `base'` passes (`base'` is base plus those found to pass along the way).
    public static func findCulprit<M>(base: [M], suspects: [M], builds: ([M]) throws -> Bool) rethrows -> M? {
        var known = base
        var remaining = suspects
        while remaining.count > 1 {
            let half = Array(remaining.prefix(remaining.count / 2))
            if try builds(known + half) {
                known += half
                remaining.removeFirst(half.count)
            } else {
                remaining = half
            }
        }
        return remaining.first
    }
}
