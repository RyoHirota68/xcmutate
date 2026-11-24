import CryptoKit
import Foundation
import MutatorCore

/// Results of earlier runs that a later run may take over instead of running the mutant again (`--reuse`).
///
/// Only **Killed** is reused, and only while nothing that the verdict rests on can have changed:
///
/// | Condition | How it is checked |
/// |---|---|
/// | The same tool and the same way of building and testing | Tool version, Xcode version, scheme, destination, test plan, build and test arguments, build settings, prepare command and test selection are hashed into `environment` |
/// | No product code changed, anywhere | `productState` hashes every file of the repository that is not on the test side. One changed byte in any of them and nothing is reused |
/// | No shared test code changed | `supportState` hashes the test-side files that declare no tests (helpers, mocks, resources) |
/// | The mutant is the same | Same stable key, and the same tokens in the declaration that encloses it |
/// | A test that killed it is unchanged and still runs | Every file that declares or extends the test's type or one of its superclasses is byte-identical, and the baseline of this run ran a test with that identifier |
///
/// Survived, NotReached, Crash, Timeout and everything else are run again: a new test can reach or kill a mutant
/// that no earlier test did, and that cannot be known without running.
///
/// What is assumed and not checked: that a test does not depend on code in another file that declares tests (a
/// helper function written next to other tests); that tests do not depend on each other's order or leftovers; and
/// that nothing outside the repository changed (the toolchain is covered by the Xcode version, the operating system
/// and the simulator runtime are not). A full run without `--reuse` is the way to be sure, and should be made
/// regularly.
public struct ReuseStore: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public struct Killer: Codable, Sendable, Equatable {
        public var test: String
        /// Files that declare the test's type and its superclasses (relative to the copied root) → SHA-256.
        public var files: [String: String]
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// SHA-256 of the tokens of the enclosing declaration.
        public var declaration: String
        public var killers: [Killer]
        public var recordedAt: String
        public var commit: String?
    }

    public var version = formatVersion
    public var toolVersion: String
    public var environment: String
    public var productState: String
    public var supportState: String
    /// Stable key → entry.
    public var entries: [String: Entry] = [:]

    static func load(_ url: URL) -> ReuseStore? {
        guard let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(ReuseStore.self, from: data),
              store.version == formatVersion else { return nil }
        return store
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The state of the working tree that reuse depends on.
public struct ReuseState: Sendable, Equatable {
    public var productState: String
    public var supportState: String
    /// Test-side Swift files that declare tests or types → SHA-256.
    public var testFiles: [String: String]
    /// Type name → test-side files that declare or extend a type of that name.
    public var declaringFiles: [String: Set<String>]
    /// Type name → names in the inheritance clauses of its declarations.
    public var inherited: [String: Set<String>]
    /// `@Test` functions at file level → files.
    public var topLevelTests: [String: Set<String>]

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A file of the test side: in a directory named like a test target, named like a test file, or importing a
    /// test framework.
    static func isTestSide(_ path: String, source: () -> String?) -> Bool {
        if TestSelector.isTestPath(path) || FileSelector.conventionalTestDirectory(of: path) != nil { return true }
        guard path.hasSuffix(".swift"), let text = source() else { return false }
        return FileSelector.importsTestFramework(text)
    }

    /// Reads every file under `root` (as the work copy would copy it) once.
    /// - Parameter ignoring: absolute paths left out (the reports this tool writes).
    public static func scan(root: URL, ignoring: Set<String> = []) -> ReuseState {
        let files = ((try? WorkCopy.listFiles(root: root)) ?? []).sorted()
        return scan(paths: files.filter { !ignoring.contains(root.appendingPathComponent($0).standardizedFileURL.path) }) {
            try? Data(contentsOf: root.appendingPathComponent($0))
        }
    }

    static func scan(paths: [String], read: (String) -> Data?) -> ReuseState {
        var product = SHA256()
        var support = SHA256()
        var state = ReuseState(productState: "", supportState: "", testFiles: [:], declaringFiles: [:], inherited: [:], topLevelTests: [:])
        for path in paths.sorted() {
            guard let data = read(path) else { continue }
            let hash = sha256(data)
            let text = path.hasSuffix(".swift") ? String(decoding: data, as: UTF8.self) : nil
            func add(_ hasher: inout SHA256) {
                hasher.update(data: Data(path.utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: Data(hash.utf8))
            }
            guard isTestSide(path, source: { text }) else {
                add(&product)
                continue
            }
            guard let text else {
                add(&support)
                continue
            }
            let declarations = TestDeclarations.scan(source: text)
            guard declarations.declaresTests else {
                add(&support)
                continue
            }
            state.testFiles[path] = hash
            for (type, parents) in declarations.types {
                state.declaringFiles[type, default: []].insert(path)
                state.inherited[type, default: []].formUnion(parents)
            }
            for name in declarations.topLevelTests { state.topLevelTests[name, default: []].insert(path) }
        }
        state.productState = product.finalize().map { String(format: "%02x", $0) }.joined()
        state.supportState = support.finalize().map { String(format: "%02x", $0) }.joined()
        return state
    }

    /// The files that a test with this identifier is declared in (`Suite/test()`, `Outer/Inner/test(x:)`, or a
    /// `@Test` function at file level), with the files of the superclasses of its types; nil if the identifier
    /// cannot be traced to files, and then nothing is reused on its account.
    public func files(ofTest identifier: String) -> [String: String]? {
        var components = identifier.split(separator: "/").map(String.init)
        guard let function = components.popLast() else { return nil }
        var paths: Set<String> = []
        if components.isEmpty {
            let name = String(function.prefix { $0 != "(" })
            guard let declared = topLevelTests[name], !declared.isEmpty else { return nil }
            paths = declared
        }
        var pending = components
        var seen: Set<String> = []
        while let type = pending.popLast() {
            guard seen.insert(type).inserted else { continue }
            guard let declared = declaringFiles[type], !declared.isEmpty else {
                // A type of the identifier itself must be found; a superclass outside the test side (XCTestCase) need not
                if components.contains(type) { return nil }
                continue
            }
            paths.formUnion(declared)
            pending += Array(inherited[type] ?? [])
        }
        guard !paths.isEmpty else { return nil }
        var result: [String: String] = [:]
        for path in paths {
            guard let hash = testFiles[path] else { return nil }
            result[path] = hash
        }
        return result
    }
}

public enum Reuse {
    /// Hash of everything about the tool and the way of building and testing that a verdict depends on.
    static func environment(config: RunConfiguration, xcodeVersion: String) -> String {
        let x = config.xcode
        let parts = [
            "tool=\(ToolInfo.version)", "xcode=\(xcodeVersion)",
            "container=\(x.container)", "scheme=\(x.scheme ?? "")", "destination=\(x.destination)", "testPlan=\(x.testPlan ?? "")",
            "build=\(x.extraBuildArguments)", "test=\(x.extraTestArguments)", "only=\(x.onlyTesting)", "skip=\(x.skipTesting)",
            "settings=\(x.buildSettings)", "cwd=\(x.workingDirectory ?? "")", "prepare=\(config.prepareCommand ?? "")",
            "selectTests=\(config.selectTestsAutomatically)|\(config.selectTestsByReach)",
        ]
        return ReuseState.sha256(Data(parts.joined(separator: "\u{0}").utf8))
    }

    static func declarationHash(source: String, mutant: Mutant) -> String {
        ReuseState.sha256(Data(TestDeclarations.tokenText(source: source, lines: mutant.scope.lines).utf8))
    }

    public struct Decision: Equatable, Sendable {
        /// Stable key → the tests that killed the mutant and are unchanged.
        public var reusable: [String: [String]] = [:]
        /// Why nothing at all is reused (nil when the store as a whole is usable).
        public var refusal: String?
    }

    /// Which of `mutants` take over the Killed of the store.
    /// - Parameter declarations: stable key → hash of the enclosing declaration now.
    /// - Parameter baselineTests: identifiers of the tests that the baseline of this run ran; nil if not known.
    public static func decide(store: ReuseStore?, environment: String, state: ReuseState, declarations: [String: String],
                              baselineTests: Set<String>?) -> Decision {
        guard let store else { return Decision(refusal: "there are no results of an earlier run with --reuse in this work directory") }
        guard store.toolVersion == ToolInfo.version, store.environment == environment else {
            return Decision(refusal: "the tool, Xcode or the options for building and testing differ from the earlier run")
        }
        guard store.productState == state.productState else {
            return Decision(refusal: "files outside the tests changed since the earlier run (any such change can alter any result)")
        }
        guard store.supportState == state.supportState else {
            return Decision(refusal: "test-side files that declare no tests (helpers, resources) changed since the earlier run")
        }
        guard let baselineTests else {
            return Decision(refusal: "the tests that the baseline ran could not be listed")
        }
        var decision = Decision()
        for (key, hash) in declarations {
            guard let entry = store.entries[key], entry.declaration == hash else { continue }
            let valid = entry.killers.filter { killer in
                !killer.files.isEmpty && baselineTests.contains(killer.test) && state.files(ofTest: killer.test) == killer.files
            }
            if !valid.isEmpty { decision.reusable[key] = valid.map(\.test).sorted() }
        }
        return decision
    }

    /// The store after a run: the earlier entries while they describe the same state, without the mutants that were
    /// run again, plus the mutants that this run killed.
    public static func updated(_ earlier: ReuseStore?, environment: String, state: ReuseState, results: [MutantResult],
                               declarations: [String: String], commit: String?, now: Date = Date()) -> ReuseStore {
        var store = ReuseStore(toolVersion: ToolInfo.version, environment: environment, productState: state.productState, supportState: state.supportState)
        if let earlier, earlier.toolVersion == store.toolVersion, earlier.environment == environment,
           earlier.productState == state.productState, earlier.supportState == state.supportState {
            store.entries = earlier.entries
        }
        let date = ISO8601DateFormatter().string(from: now)
        for result in results where result.reused != true {
            let key = result.mutant.key
            store.entries[key] = nil
            guard result.status == .killed, let declaration = declarations[key] else { continue }
            let killers = result.killedBy.compactMap { test -> ReuseStore.Killer? in
                state.files(ofTest: test).map { ReuseStore.Killer(test: test, files: $0) }
            }
            guard !killers.isEmpty else { continue }
            store.entries[key] = ReuseStore.Entry(declaration: declaration, killers: killers, recordedAt: date, commit: commit)
        }
        return store
    }
}

/// The identifiers of the tests in a result bundle (`Suite/test()`), as `killedBy` names them.
enum TestCaseList {
    static func load(_ bundle: URL) -> Set<String>? {
        guard let result = try? Subprocess.capture(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle.path, "--compact"], timeout: 300),
              result.status == 0, let start = result.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any] else { return nil }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> Set<String> {
        var identifiers: Set<String> = []
        func walk(_ node: [String: Any]) {
            if node["nodeType"] as? String == "Test Case", let identifier = node["nodeIdentifier"] as? String { identifiers.insert(identifier) }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for node in json["testNodes"] as? [[String: Any]] ?? [] { walk(node) }
        return identifiers
    }
}
