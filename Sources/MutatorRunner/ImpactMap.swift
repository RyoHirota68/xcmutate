import Foundation
import MutatorCore

/// `--write-impact-map` and `--select-tests impact`: which suites ran the code of which file, recorded by one run
/// (a nightly run of whole files) and used by a later run to choose its tests.
///
/// Only the choice of tests is taken from the map. Every verdict of the later run comes from its own runs, with its
/// own baseline, so the map can make a run look at fewer tests, never give it a wrong Killed. What it can do is leave
/// out a test that would have reached or detected a mutant: such a run reports among the selected tests, as
/// `--only-testing` does, and a full run stays the reference.
public struct ImpactMap: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    /// A file whose code ran outside any test (at app launch), or that a suite reached that cannot be named for
    /// certain: every test may depend on it.
    public static let everything = "*"

    public var version = formatVersion
    public var tool: String
    /// The commit the map was made at, and whether the working tree had changes then.
    public var commit: String
    public var dirty: Bool
    /// Every suite of that run's selection (`-only-testing:` identifiers).
    public var suites: [String]
    /// Mutated file (relative to the root) → the suites whose tests evaluated a switch in it, or [`everything`].
    public var files: [String: [String]]

    /// The map of a baseline with per-test reach.
    static func make(reach: TestReach, suites: [TestSuiteInfo], mutants: [Mutant], commit: String, dirty: Bool) -> ImpactMap {
        var files: [String: Set<String>] = [:]
        for mutant in mutants {
            if files[mutant.file] == nil { files[mutant.file] = [] }
            guard reach.reached.contains(mutant.id) else { continue }
            if reach.outside.contains(mutant.id) {
                files[mutant.file]?.insert(everything)
                continue
            }
            for name in reach.suites[mutant.id] ?? [] {
                let matches = suites.filter { $0.name == name || $0.identifier == name }
                if matches.count == 1, let suite = matches.first, !suite.identifier.isEmpty {
                    files[mutant.file]?.insert(suite.onlyTestingIdentifier)
                } else {
                    files[mutant.file]?.insert(everything)
                }
            }
        }
        return ImpactMap(tool: ToolInfo.version, commit: commit, dirty: dirty,
                         suites: Array(Set(suites.filter { !$0.identifier.isEmpty }.map(\.onlyTestingIdentifier))).sorted(),
                         files: files.mapValues { $0.contains(everything) ? [everything] : $0.sorted() })
    }

    /// The tests a later run selects for files changed since the map's commit, or why it runs all of them.
    /// - Parameters:
    ///   - changed: files changed since the map's commit (committed, uncommitted and untracked), relative to the root.
    ///   - source: the current contents of a file, nil if it no longer exists.
    ///   - testTargets: the test targets of the current selection (to name a suite that the map does not know yet).
    public func selection(changed: [String], source: (String) -> String?, testTargets: [String]) -> Selection {
        var chosen: Set<String> = []
        var reasons: [String] = []
        var newSuites: [String] = []
        for file in changed.sorted() {
            if Self.outsideTheBuild(file) { continue }
            guard file.hasSuffix(".swift") else {
                reasons.append("\(file) is not a Swift file: resources, storyboards and project settings can change what any test sees")
                continue
            }
            if TestSelector.isTestPath(file) {
                guard let text = source(file) else { continue }   // a test file that was removed: its tests are gone
                let declarations = TestDeclarations.scan(source: text)
                guard declarations.declaresTests, declarations.topLevelTests.isEmpty else {
                    reasons.append(declarations.declaresTests
                                   ? "\(file) declares tests outside a type, which cannot be selected by suite"
                                   : "\(file) is a test helper that declares no tests: any suite may use it")
                    continue
                }
                for type in declarations.types.keys {
                    let known = suites.filter { $0.hasSuffix("/" + type) }
                    if !known.isEmpty {
                        chosen.formUnion(known)
                    } else if testTargets.count == 1, declarations.types[type]?.isEmpty == false || type.hasSuffix("Tests") {
                        // A suite that the map does not know (added since): named in the one test target
                        chosen.insert("\(testTargets[0])/\(type)")
                        newSuites.append(type)
                    }
                }
                continue
            }
            guard let suitesOfFile = files[file] else {
                reasons.append("\(file) is not in the map (a new file, or one without mutants when the map was made)")
                continue
            }
            if suitesOfFile.contains(Self.everything) {
                reasons.append("code of \(file) runs outside the tests (app launch), or a suite that reaches it cannot be named for certain")
                continue
            }
            chosen.formUnion(suitesOfFile)
        }
        if !reasons.isEmpty { return .all(reasons: reasons) }
        return .suites(chosen.sorted(), newSuites: newSuites.sorted())
    }

    public enum Selection: Equatable, Sendable {
        /// Run these suites (empty: nothing that the map covers changed).
        case suites([String], newSuites: [String])
        /// Run the whole selection, for these reasons.
        case all(reasons: [String])
    }

    /// Files that are not part of what is built: documentation and CI settings.
    static func outsideTheBuild(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasPrefix(".github/") || lower.hasPrefix("docs/") || lower == "license"
    }
}

extension JSONEncoder {
    /// Sorted keys and indentation: a file that people diff and keep as an artifact.
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
