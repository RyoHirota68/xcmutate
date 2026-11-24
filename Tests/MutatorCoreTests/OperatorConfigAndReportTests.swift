import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

@Suite("Operators: empty-body, compound-assignment, switch-case-removal, try-optional-nil, condition-constant, guard-removal")
struct BodyAndConditionOperatorTests {
    func only(_ op: MutationOperator, _ source: String) -> FileResult {
        let result = process(source, options: GeneratorOptions(operators: [op]))
        expectValidInstrumentation(result)
        return result
    }

    @Test func emptyBodyWrapsTheWholeBody() {
        let source = """
        final class Model {
            var loading = false
            var count = 0
            func start() {
                loading = true
                count = 1 // trailing comment
            }
            func oneLine() { loading = false }
        }

        """
        let result = only(.emptyBody, source)
        #expect(result.mutants.map(\.original) == ["body of start()", "body of oneLine()"])
        #expect(result.mutants.allSatisfy { $0.isStatement && $0.mutatedExpression.isEmpty })
        #expect(result.instrumented.contains("func start() {if !__xcmutate.isOn(0) { \n"))
        #expect(result.instrumented.contains("func oneLine() {if !__xcmutate.isOn(1) {  loading = false  }}"))
        // The line of every original statement is unchanged.
        #expect(result.instrumented.split(separator: "\n", omittingEmptySubsequences: false)[5].contains("count = 1 // trailing comment"))
    }

    @Test func emptyBodyIsNotMadeWhereItAddsNothing() {
        let source = """
        class Base { func setUp() {} }
        final class Model: Base {
            var value = 0
            func onlyCalls() { a(); b() }
            override func setUp() { super.setUp() }
            func guardAndCall() { guard value > 0 else { return }; a() }
            func empty() {}
            func justReturn() { return }
            func returning() -> Int { value = 1; return value }
            func explicitVoid() -> Void { value = 2 }
            init(value: Int) { self.value = value }
            deinit { value = 0 }
            func a() { print("a") }
            func b() { print("b") }
            var computed: Int { get { value } set { value = newValue } }
        }

        """
        let result = only(.emptyBody, source)
        #expect(result.mutants.map(\.original) == ["body of explicitVoid()"])
        #expect(result.ignored.isEmpty)
    }

    @Test func emptyBodyYieldsToAStatementMutantWithTheSameRange() {
        // `{x += 1}` without spaces: the interior is exactly the statement.
        let source = "final class C { var x = 0\n    func f() {x += 1}\n}\n"
        let result = process(source, options: GeneratorOptions(operators: [.emptyBody, .compoundAssignment]))
        expectValidInstrumentation(result)
        #expect(result.mutants.map(\.operator) == [.compoundAssignment])
        #expect(result.ignored.map(\.reason) == [.sameRangeAsStatement])
    }

    @Test func compoundAssignmentIsOffByDefaultAndSkipsLiterals() {
        let source = """
        func f(_ xs: [Int], _ suffix: String) -> String {
            var total = 0
            var text = ""
            var list: [Int] = []
            for x in xs {
                total += x
                total -= 1
                total *= 2
                total /= 3
            }
            text += "literal"
            list += [1]
            text += suffix
            return text + String(total) + String(list.count)
        }

        """
        #expect(!GeneratorOptions().operators.contains(.compoundAssignment))
        let result = only(.compoundAssignment, source)
        #expect(result.mutants.map { "\($0.original)>\($0.replacement)" } == ["+=>-=", "-=>+=", "*=>/=", "/=>*=", "+=>-="])
        #expect(result.mutants.allSatisfy { $0.operator.replacesStatement })
        #expect(result.instrumented.contains("if __xcmutate.isOn(0) { total -= x } else { total += x }"))
    }

    @Test func switchCaseRemovalGuardsEveryPattern() {
        let source = """
        enum K { case a, b, c, d, e }
        func f(_ k: K, _ n: Int) -> Int {
            switch k {
            case .a: return 1
            case .b, .c:
                return 2
            case .d where n > 0: return 3
            case .e: return 0
            default: return 0
            }
        }

        """
        let result = only(.switchCaseRemoval, source)
        #expect(result.mutants.map(\.original) == ["case .a", "case .b, .c"])
        #expect(result.mutants[1].guardOffsets?.count == 2)
        #expect(result.mutants[1].mutatedExpression == ".b where false, .c where false")
        #expect(result.instrumented.contains("case .a where !__xcmutate.isOn(0): return 1"))
        #expect(result.instrumented.contains("case .b where !__xcmutate.isOn(1), .c where !__xcmutate.isOn(1):"))
        // The same ID twice is expected for a case with two patterns, and only there.
        let wrong = InstrumentationVerifier.verify(original: source, instrumented: result.instrumented, expectedIDs: [0, 1])
        #expect(wrong.duplicatedIDs == [1])
    }

    @Test func switchCaseRemovalNeedsAPlainDefault() {
        let exhaustive = "enum K { case a, b }\nfunc f(_ k: K) -> Int { switch k { case .a: return 1\n case .b: return 2 } }\n"
        #expect(only(.switchCaseRemoval, exhaustive).mutants.isEmpty)
        let unknownDefault = "enum K { case a, b }\nfunc f(_ k: K) -> Int { switch k { case .a: return 1\n case .b: return 2\n @unknown default: return 0 } }\n"
        #expect(only(.switchCaseRemoval, unknownDefault).mutants.isEmpty)
        let fallthroughIntoDefault = "func f(_ n: Int) -> Int { switch n { case 1: return 1\n case 2: fallthrough\n default: return 0 } }\n"
        #expect(only(.switchCaseRemoval, fallthroughIntoDefault).mutants.map(\.original) == ["case 1"])
    }

    @Test func switchCaseRemovalSkipsCasesThatDifferFromDefaultOnlyByLogging() {
        let source = """
        func f(_ code: Int) -> Int {
            var n = 0
            switch code {
            case 1: break
            case 2: n = 2
            case 3: print("three")
            default: Crashlytics.record(code)
            }
            return n
        }

        """
        var options = GeneratorOptions(operators: [.switchCaseRemoval])
        #expect(process(source, options: options).mutants.map(\.original) == ["case 1", "case 2", "case 3"])
        options.aridCallPatterns = ["Crashlytics"]
        let result = process(source, options: options)
        expectValidInstrumentation(result)
        #expect(result.mutants.map(\.original) == ["case 2"])
    }

    @Test func tryOptionalNil() {
        let source = """
        func load(_ s: String) throws -> Int { s.count }
        func a(_ s: String) -> Int {
            let n = try? load(s)
            guard let v = try? load(s) else { return -1 }
            _ = try? load(s)
            try? print(load(s))
            return (n ?? 0) + v + ((try? load(s)) ?? 0)
        }
        func explicit(_ s: String) -> Int? {
            return try? load(s)
        }
        func implicit(_ s: String) -> Int? { try? load(s) }
        func nonOptional(_ s: String) throws -> Int { try load(s) }

        """
        let result = only(.tryOptionalNil, source)
        #expect(result.mutants.map(\.start.line) == [3, 4, 7, 10, 12])
        #expect(result.mutants.allSatisfy { $0.replacement == "nil" })
        // With return-value on, `return try? load(s)` in an Optional function is left to return-value.
        let both = process(source, options: GeneratorOptions(operators: [.tryOptionalNil, .returnValue]))
        expectValidInstrumentation(both)
        #expect(both.mutants.filter { $0.start.line == 10 }.map(\.operator) == [.returnValue])
    }

    @Test func conditionConstantAndGuardRemovalAreOneWay() {
        let source = """
        func f(_ a: Int, _ b: Int?, _ flag: Bool) -> Int {
            guard a > 0 else { return 0 }
            guard a > 1, flag else { return 1 }
            guard let b else { return 2 }
            if a > b { return 3 }
            if flag, let c = Optional(a), c > 2 { return 4 } else if a == 9 { return 5 }
            if true { return 6 }
            while a > 100 { return 7 }
            if a == 7 { print("seven") }
            if a == 8 { print("eight") } else { return 9 }
            return 8
        }

        """
        // `if` -> false: one per `if`, the last plain condition; not for an `if` that only logs.
        let ifs = only(.conditionConstant, source)
        #expect(ifs.mutants.map { "\($0.start.line):\($0.original)>\($0.replacement)" }
            == ["5:a > b>false", "6:c > 2>false", "6:a == 9>false", "10:a == 8>false"])
        // `guard` -> true: only single-condition guards. On by default (1 of 76 reached mutants equivalent on real code).
        let guards = only(.guardRemoval, source)
        #expect(guards.mutants.map { "\($0.start.line):\($0.original)>\($0.replacement)" } == ["2:a > 0>true"])
        #expect(GeneratorOptions().operators.contains(.guardRemoval))
        #expect(GeneratorOptions().operators.contains(.conditionConstant))
        // No overlap with condition-removal (which handles lists of two or more conditions by turning each into `true`).
        let all = process(source, options: GeneratorOptions(operators: [.conditionConstant, .guardRemoval, .conditionRemoval]))
        expectValidInstrumentation(all)
        #expect(!all.ignored.contains { $0.reason == .duplicate })
        #expect(Set(all.mutants.map { "\($0.region)\($0.mutatedExpression)" }).count == all.mutants.count)
    }

    @Test func everyOperatorHasATestObligation() {
        for op in MutationOperator.allCases { #expect(op.testObligation.count > 40, "\(op.rawValue)") }
    }
}

@Suite("Disable comments")
struct DisableCommentTests {
    /// The marker in a string literal is not a directive; in any kind of comment it is.
    @Test func theMarkerInAStringLiteralIsNotADirective() {
        let source = """
        func f(_ a: Int) -> Bool {
            let hint = "// xcmutate:disable boundary"
            let other = "// xcmutate:disable-nxt"
            return a > 1 && hint.count > 2 && other.count > 3
        }
        func g(_ a: Int) -> Bool {
            /* xcmutate:disable-next-line boundary -- a block comment works too */
            return a > 1
        }

        """
        let result = MutantGenerator(options: GeneratorOptions(operators: [.boundary])).generate(source: source, filePath: "T.swift")
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        #expect(result.mutants.map(\.start.line) == [4, 4, 4])
        #expect(result.ignored.filter { $0.reason == .disabledByComment }.map(\.start.line) == [8])
    }

    @Test func operatorsCanBeNamed() {
        let source = """
        func f(_ a: Int, _ b: Int) -> Bool {
            // xcmutate:disable-next-line boundary -- covered elsewhere
            let x = a > b && a != 0
            let y = a < b || a == 1 // xcmutate:disable-line equality-flip, logical-connector
            // xcmutate:disable boundary
            let z = a >= b && a == 2
            // xcmutate:enable boundary
            let w = a <= b
            /* xcmutate:disable-next-line */
            let v = a > 9 && a != 3
            return x && y && z && w && v
        }

        """
        let options = GeneratorOptions(operators: [.boundary, .equalityFlip, .logicalConnector])
        let result = generate(source, options: options)
        let made = result.mutants.map { "\($0.start.line):\($0.original)" }
        #expect(made == ["3:&&", "3:!=", "4:<", "6:&&", "6:==", "8:<=", "11:&&", "11:&&", "11:&&", "11:&&"])
        #expect(result.ignored.allSatisfy { $0.reason == .disabledByComment })
        #expect(result.ignored.map { "\($0.start.line):\($0.original)" } == ["3:>", "4:||", "4:==", "6:>=", "10:>", "10:&&", "10:!="])
        #expect(result.warnings.isEmpty)
    }

    @Test func unknownNamesAreReportedAndDisableNothing() {
        let source = """
        func f(_ a: Int) -> Bool {
            // xcmutate:disable-next-line boundry
            let x = a > 1
            // xcmutate:disable-next-line because the reason is written without the two dashes
            let y = a > 2
            // xcmutate:disabel
            let z = a > 3
            return x && y && z
        }

        """
        let result = generate(source, options: GeneratorOptions(operators: [.boundary]))
        #expect(result.mutants.count == 3)
        #expect(result.ignored.isEmpty)
        #expect(result.warnings.map(\.line) == [2] + Array(repeating: 4, count: 9) + [6])
        #expect(result.warnings.first?.message.contains("unknown operator `boundry`") == true)
        #expect(result.warnings.last?.message.contains("unknown directive") == true)
        #expect(DisableComments.marker == "xcmutate:")
    }

    @Test func blockWithoutNamesDisablesEverythingUntilEnable() {
        let source = "// xcmutate:disable\nlet a = 1 > 0\n// xcmutate:enable\nlet b = 2 > 1\n"
        let result = generate(source, options: GeneratorOptions(operators: [.boundary]))
        #expect(result.mutants.map(\.start.line) == [4])
        #expect(result.ignored.map(\.start.line) == [2])
    }
}

@Suite("File selection")
struct FileSelectionTests {
    static let files: [String: String] = [
        "App/Cart.swift": "struct Cart {}",
        "App/ABTest.swift": "enum ABTest { static let on = 1 > 0 }",
        "App/SplitTests/Split.swift": "enum Split {}",
        "AppTests/CartTests.swift": "import XCTest\n@testable import App\nfinal class CartTests: XCTestCase {}",
        "AppTests/Helpers/Mock.swift": "struct Mock {}",
        "AppTests/SwiftTestingTests.swift": "import Foundation\n  import Testing\n@Suite struct S {}",
        "Tests/LibTests/Support.swift": "@testable import Lib\nlet x = 1",
        "App/Generated/Strings.swift": "// swiftlint:disable all\n// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen\nenum L10n {}",
        "App/Legacy.swift": "// swiftlint:disable all\nstruct Legacy {}",
        "App/Proto.pb.swift": "// DO NOT EDIT.\n// swift-format-ignore-file\nstruct Proto {}",
        "App/Late.swift": String(repeating: "\n", count: 30) + "// DO NOT EDIT\nstruct Late {}",
        "App/NotAComment.swift": "let message = \"Generated by hand; do not edit\"\n",
        "Package.swift": "// swift-tools-version: 6.0",
        "Pods/Lib/Lib.swift": "struct Lib {}",
        "fastlane/Fastfile.swift": "class Fastfile {}",
        "Vendor/Deep/Thing.swift": "struct Thing {}",
        "Vendor/Keep.swift": "struct Keep {}",
    ]

    func select(_ patterns: [String] = []) -> FileSelector.Selection {
        FileSelector.select(paths: Array(Self.files.keys), patterns: patterns) { Self.files[$0] }
    }

    @Test func defaultRulesNeverGoByNameAlone() {
        let selection = select()
        let reasons = Dictionary(uniqueKeysWithValues: selection.excluded.map { ($0.file, $0.reason) })
        #expect(reasons == [
            "AppTests/CartTests.swift": "test-code",
            "AppTests/SwiftTestingTests.swift": "test-code",
            "AppTests/Helpers/Mock.swift": "test-directory",
            "Tests/LibTests/Support.swift": "test-code",
            "App/Generated/Strings.swift": "generated-code",
            "App/Proto.pb.swift": "generated-code",
            "Package.swift": "package-manifest",
            "Pods/Lib/Lib.swift": "build-or-dependency-directory",
        ])
        // Product code with a test-like name, a `…Tests` directory without tests, `swiftlint:disable all` alone,
        // a marker far from the top and a marker outside a comment are all mutated.
        #expect(selection.included == ["App/ABTest.swift", "App/Cart.swift", "App/Late.swift", "App/Legacy.swift", "App/NotAComment.swift",
                                       "App/SplitTests/Split.swift", "Vendor/Deep/Thing.swift", "Vendor/Keep.swift", "fastlane/Fastfile.swift"])
    }

    @Test func configPatternsAreAppliedInOrderAndCanNegate() {
        let selection = select(["Vendor/**", "!Vendor/Keep.swift", "fastlane", "*Test.swift", "!App/Generated/Strings.swift"])
        #expect(selection.included.contains("Vendor/Keep.swift"))
        #expect(!selection.included.contains("Vendor/Deep/Thing.swift"))
        #expect(!selection.included.contains("fastlane/Fastfile.swift"))
        #expect(!selection.included.contains("App/ABTest.swift"))
        // `!` also brings back a file that a default rule excluded.
        #expect(selection.included.contains("App/Generated/Strings.swift"))
        #expect(selection.excluded.first { $0.file == "App/ABTest.swift" } == ExcludedFile(file: "App/ABTest.swift", reason: "config-exclude", detail: "*Test.swift"))
        // The last matching pattern wins.
        #expect(!select(["!Vendor/Keep.swift", "Vendor/**"]).included.contains("Vendor/Keep.swift"))
    }

    @Test(arguments: [
        ("*.swift", "a/b/C.swift", true),
        ("Generated", "App/Generated/Strings.swift", true),
        ("Generated/", "App/Generated/Strings.swift", true),
        ("App/*.swift", "App/Cart.swift", true),
        ("App/*.swift", "App/Sub/Cart.swift", false),
        ("App/**/*.swift", "App/Sub/Deep/Cart.swift", true),
        ("App/**/*.swift", "App/Cart.swift", true),
        ("**/Mocks/**", "Sources/Mocks/A.swift", true),
        ("/App", "App/Cart.swift", true),
        ("/App", "Other/App/Cart.swift", false),
        ("Sources/A?.swift", "Sources/AB.swift", true),
        ("Sources/A?.swift", "Sources/A/B.swift", false),
        ("Sources/A+B.swift", "Sources/A+B.swift", true),
        ("Sources/A+B.swift", "Sources/AAB.swift", false),
        ("", "Sources/A.swift", false),
    ])
    func glob(pattern: String, path: String, matches: Bool) {
        #expect(GlobPattern(pattern).matches(path) == matches)
    }
}

@Suite("Config, journal, judgement, gates and reports")
struct ConfigJournalAndReportTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcmutate-s7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: config

    @Test func configReportsUnknownKeysAndBadJSON() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("xcmutate.config.json")
        try #"{"aridCalls": ["Log"], "exclude": ["Generated/**"], "disabledOperator": ["boundary"], "aridCall": []}"#.write(to: url, atomically: true, encoding: .utf8)
        let config = try MutatorConfig.load(url)
        #expect(config.exclude == ["Generated/**"])
        #expect(config.loadWarnings.count == 2)
        #expect(config.loadWarnings[0].contains("unknown key `aridCall`"))
        #expect(config.loadWarnings[1].contains("unknown key `disabledOperator`"))

        try #"{"aridCalls": ["Log"]"#.write(to: url, atomically: true, encoding: .utf8)
        #expect { try MutatorConfig.load(url) } throws: { "\($0)".contains("xcmutate.config.json") && "\($0)".contains("not valid JSON") }
        try #"{"aridCalls": "Log"}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect { try MutatorConfig.load(url) } throws: { "\($0)".contains("`aridCalls`") }
        try "[1]".write(to: url, atomically: true, encoding: .utf8)
        #expect { try MutatorConfig.load(url) } throws: { "\($0)".contains("JSON object") }
        #expect(try MutatorConfig.load(dir.appendingPathComponent("missing.json")).loadWarnings.isEmpty)
    }

    // MARK: journal

    static func observation(_ key: String, id: Int, attempt: Int = 1, failed: Int = 0, total: Int = 3, activated: Bool = true,
                            exit: Int32? = nil, timedOut: Bool = false) -> MutantObservation {
        MutantObservation(key: key, id: id, attempt: attempt, exitStatus: exit ?? (failed > 0 ? 65 : 0), timedOut: timedOut,
                          summary: timedOut ? nil : DefectRegressionTests.summary(failed: failed, total: total), activated: activated,
                          runnerErrorPattern: nil, durationSeconds: 1.5, timeoutSeconds: 60)
    }

    @Test func journalSurvivesATruncatedLastLine() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal/observations.jsonl")
        let journal = Journal(url: url)
        #expect(!journal.load())
        try journal.start(fingerprint: "abc")
        try journal.record(baseline: BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0))
        try journal.record(compileError: "k-compile", detail: "A.swift:1:1: nope")
        try journal.record(Self.observation("k1", id: 1, failed: 1))
        try journal.record(Self.observation("k2", id: 2))
        journal.close()

        // The process died in the middle of writing the next record.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"observation":{"key":"k3","id":3,"att"#.utf8))
        try handle.close()

        let reloaded = Journal(url: url)
        #expect(reloaded.load())
        #expect(reloaded.header?.fingerprint == "abc")
        #expect(reloaded.header?.toolVersion == ToolInfo.version)
        #expect(reloaded.baseline == BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0))
        #expect(reloaded.compileErrors == ["k-compile": "A.swift:1:1: nope"])
        #expect(Set(reloaded.observations.keys) == ["k1", "k2"])
        #expect(reloaded.observations["k1"]?.first == Self.observation("k1", id: 1, failed: 1))
        // The damaged tail was cut off, so appending continues with whole lines.
        try reloaded.record(Self.observation("k3", id: 3))
        reloaded.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        #expect(text.split(separator: "\n").count == 6)
        let again = Journal(url: url)
        #expect(again.load())
        #expect(again.observations.count == 3)

        // Starting again discards the earlier run.
        try again.start(fingerprint: "def")
        again.close()
        let fresh = Journal(url: url)
        #expect(fresh.load())
        #expect(fresh.header?.fingerprint == "def")
        #expect(fresh.observations.isEmpty)
    }

    @Test func fingerprintChangesWithSourcesAndOptions() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "let a = 1\n".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        let first = RunFingerprint.compute(copyRoot: dir, parts: ["scheme=App", "mutants=0:k"])
        #expect(first == RunFingerprint.compute(copyRoot: dir, parts: ["scheme=App", "mutants=0:k"]))
        #expect(first != RunFingerprint.compute(copyRoot: dir, parts: ["scheme=Other", "mutants=0:k"]))
        // A report written by the tool itself does not change the fingerprint (an interrupted run writes one).
        let reportPath = dir.appendingPathComponent("mutation.json")
        try "{}".write(to: reportPath, atomically: true, encoding: .utf8)
        #expect(first != RunFingerprint.compute(copyRoot: dir, parts: ["scheme=App", "mutants=0:k"]))
        #expect(first == RunFingerprint.compute(copyRoot: dir, parts: ["scheme=App", "mutants=0:k"], ignoring: [reportPath.standardizedFileURL.path]))
        try "let a = 2\n".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        #expect(first != RunFingerprint.compute(copyRoot: dir, parts: ["scheme=App", "mutants=0:k"], ignoring: [reportPath.standardizedFileURL.path]))
    }

    // MARK: judgement

    @Test(arguments: [
        // (failed, total, skipped, crash message, activated, expected)
        (0, 3, 0, false, true, MutantStatus.survived),
        (0, 2, 0, false, true, .runnerError),      // fewer tests ran than in the baseline: not "all passed"
        (0, 4, 0, false, true, .runnerError),
        (0, 3, 1, false, true, .survived),         // a different number of skips is an effect of the mutant, not of the run
        (1, 3, 1, false, true, .killed),
        (1, 3, 0, false, true, .killed),
        (1, 2, 0, false, true, .runnerError),      // a failure, but among a different set of tests
        (1, 2, 0, true, true, .crash),             // a crash stops the remaining tests: still a detection
        (1, 2, 0, true, false, .runnerError),      // …but never without the activation record
        (0, 3, 0, false, false, .notActivated),
    ] as [(Int, Int, Int, Bool, Bool, MutantStatus)])
    func verdictNeedsTheSameTestsAsTheBaseline(failed: Int, total: Int, skipped: Int, crash: Bool, activated: Bool, expected: MutantStatus) {
        var summary = DefectRegressionTests.summary(failed: failed, total: total, message: crash ? "Crash: App at f()" : "XCTAssertEqual failed")
        summary.skippedTests = skipped
        let observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: failed > 0 ? 65 : 0, timedOut: false, summary: summary,
                                            activated: activated, runnerErrorPattern: nil, durationSeconds: 1, timeoutSeconds: 60)
        let baseline = BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0)
        let result = Judgement.classify(observation, baseline: baseline)
        #expect(result.status == expected)
        if expected == .runnerError, activated, total != 3 { #expect(result.detail?.contains("the baseline ran 3") == true) }
    }

    // MARK: reports and gates

    static func mutant(_ id: Int, file: String = "App/Cart.swift", op: MutationOperator = .boundary, line: Int = 3) -> Mutant {
        Mutant(id: id, key: "\(file)::Cart.total()::\(op.rawValue)::\(id)", operator: op, file: file, enclosingDecl: "Cart.total()",
               region: ByteRange(start: 10, end: 15), point: ByteRange(start: 12, end: 13),
               start: SourcePosition(line: line, column: 14), end: SourcePosition(line: line, column: 15),
               original: ">", replacement: ">=", originalExpression: "a > b", mutatedExpression: "a >= b",
               regionLines: LineSpan(start: line, end: line), scope: MutantScope(id: "Cart.total()", lines: LineSpan(start: 2, end: 5)))
    }

    static func report(_ statuses: [(MutantStatus, String)], root: String = "/repo") -> RunReport {
        var results: [MutantResult] = []
        for (index, (status, file)) in statuses.enumerated() {
            results.append(MutantResult(mutant: mutant(index, file: file), status: status,
                                        killedBy: status == .killed ? ["AppTests/CartTests/testTotal()"] : [],
                                        durationSeconds: 2, attempts: 1, detail: status == .runnerError ? "simulator <down>" : nil))
        }
        var report = RunReport(scope: "files", root: root, files: Array(Set(statuses.map(\.1))).sorted(), skippedFiles: [:], baseline: nil,
                               durations: RunDurations(), results: results, ignored: [], warnings: [])
        report.startedAt = "2026-11-20T10:00:00Z"
        report.finishedAt = "2026-11-20T10:05:00Z"
        report.commit = RunReport.Commit(sha: "0123456789abcdef", dirty: true)
        return report
    }

    @Test func bothScoresAndPerFileScores() {
        let report = Self.report([(.killed, "A.swift"), (.crash, "A.swift"), (.survived, "A.swift"), (.notReached, "A.swift"),
                                  (.notReached, "B.swift"), (.timeout, "B.swift"), (.compileError, "B.swift"), (.accepted, "B.swift"),
                                  (.runnerError, "C.swift")])
        #expect(report.score == 3.0 / 6.0)
        #expect(report.reachedScore == 3.0 / 4.0)
        let files = report.fileScores
        #expect(files.map(\.file) == ["A.swift", "B.swift", "C.swift"])
        #expect(files[0].score == 0.5)
        #expect(files[0].reachedScore == 2.0 / 3.0)
        #expect(files[1].score == 0.5)
        #expect(files[1].reachedScore == 1.0)
        #expect(files[2].score == nil)
        #expect(report.unevaluatedCount == 1)
        let json = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONReport(report: report))) as? [String: Any]
        #expect(json?["version"] as? Int == 2)
        #expect((json?["tool"] as? [String: Any])?["version"] as? String == ToolInfo.version)
        #expect(json?["startedAt"] as? String == "2026-11-20T10:00:00Z")
        #expect(json?["reachedScore"] as? Double == 0.75)
        #expect((json?["fileScores"] as? [[String: Any]])?.count == 3)
        #expect((json?["commit"] as? [String: Any])?["sha"] as? String == "0123456789abcdef")
    }

    @Test func gates() throws {
        let clean = Self.report([(.killed, "A.swift"), (.accepted, "A.swift")])
        let withSurvivors = Self.report([(.killed, "A.swift"), (.survived, "A.swift"), (.notReached, "A.swift"), (.killed, "A.swift")])
        #expect(Gate().evaluate(withSurvivors).isEmpty)
        #expect(Gate(failOnSurvived: true).evaluate(clean).isEmpty)
        #expect(Gate(failOnSurvived: true).evaluate(withSurvivors).map(\.exitCode) == [ExitCodes.survived])
        #expect(Gate(failUnder: 50).evaluate(withSurvivors).isEmpty)
        #expect(Gate(failUnder: 50.1).evaluate(withSurvivors).map(\.exitCode) == [ExitCodes.belowThreshold])
        #expect(Gate(failUnder: 80, failOnSurvived: true).evaluate(withSurvivors).map(\.exitCode) == [ExitCodes.survived, ExitCodes.belowThreshold])
        #expect(Gate(failUnder: 80).evaluate(Self.report([])).isEmpty)

        // Compared with an earlier report: only survivors that were not undetected before count.
        let earlier = try JSONEncoder().encode(JSONReport(report: withSurvivors))
        let known = try Gate.undetectedKeys(inReport: earlier)
        #expect(known == [withSurvivors.results[1].mutant.key, withSurvivors.results[2].mutant.key])
        #expect(Gate(earlierUndetected: known).evaluate(withSurvivors).isEmpty)
        let failures = Gate(earlierUndetected: [withSurvivors.results[1].mutant.key]).evaluate(withSurvivors)
        #expect(failures.map(\.exitCode) == [ExitCodes.newSurvivors])
        #expect(failures.first?.message.contains(withSurvivors.results[2].mutant.key) == true)
        #expect(throws: (any Error).self) { try Gate.undetectedKeys(inReport: Data("{}".utf8)) }

        // A gate is not reported as passed while some mutants could not be evaluated.
        let unevaluated = Self.report([(.killed, "A.swift"), (.runnerError, "A.swift")])
        #expect(Gate(failOnSurvived: true).evaluate(unevaluated).map(\.exitCode) == [ExitCodes.incomplete])
        // Nor does a run without a gate end with 0 then: its score is that of the mutants that were judged
        #expect(Gate().evaluate(unevaluated).map(\.exitCode) == [ExitCodes.incomplete])
    }

    @Test func xcodeAndMarkdownReports() {
        let report = Self.report([(.killed, "App/Cart.swift"), (.survived, "App/Cart.swift"), (.notReached, "App/Other.swift"), (.runnerError, "App/Cart.swift")])
        let xcode = XcodeReport.render(report).split(separator: "\n").map(String.init)
        #expect(xcode.count == 4)
        #expect(xcode[3].hasPrefix("warning: xcmutate: 1 of 4 mutants could not be run and are not in the score (RunnerError 1)"))
        #expect(xcode[0].hasPrefix("/repo/App/Cart.swift:3:14: warning: mutant survived: boundary `>` -> `>=`"))
        #expect(xcode[1].hasPrefix("/repo/App/Other.swift:3:14: warning: mutant not reached: "))
        #expect(xcode[2].contains("warning: mutant not evaluated (RunnerError)"))

        let markdown = MarkdownReport.render(report)
        #expect(markdown.contains("## Mutation testing (xcmutate \(ToolInfo.version))"))
        #expect(markdown.contains("| **33.3%** | 50.0% | 1 | 0 | 0 | 1 | 1 | 0 | 0 | 1 |"))
        #expect(markdown.contains("| `App/Cart.swift` | 50.0% | 50.0% | 1 | 1 | 0 |"))
        // The location has the column and the row ends with the stable key, so that two mutants of one line can be told apart
        #expect(markdown.contains("| `App/Other.swift:3:14` | NotReached | boundary | `>` -> `>=` | `App/Other.swift::Cart.total()::boundary::2` |"))
        #expect(markdown.contains("`0123456789` (with uncommitted changes)"))

        let text = TextReport.render(report)
        #expect(text.contains("mutation score: 33.3%"))
        #expect(text.contains("among reached:  50.0%"))
        #expect(text.contains("Per file"))
        #expect(!text.contains("not run against all tests"))
        #expect(!markdown.contains("not run against all tests"))
    }

    /// A Survived that rests on the narrowed tests alone (`--no-recheck-survivors`) is told apart in every report.
    @Test func survivorsThatWereNotRunAgainstAllTestsAreMarked() throws {
        var report = Self.report([(.killed, "App/Cart.swift"), (.survived, "App/Cart.swift"), (.survived, "App/Cart.swift")])
        report.results[1].narrowedOnly = true
        report.results[1].selectedTests = ["AppTests/CartTests"]
        report.testSelection = RunReport.TestSelection(mode: "reach", narrowedMutants: 2, unnarrowedMutants: 1, recheckSurvivors: false, survivedNarrowedOnly: 1,
                                                       fallback: false, onlyTesting: [], matches: [])
        let text = TextReport.render(report)
        #expect(text.contains("1 of the Survived passed only the tests that reach them and were not run against all tests (--no-recheck-survivors)"))
        #expect(text.contains("App/Cart.swift:3:14 [Survived, not run against all tests] boundary"))
        #expect(text.contains("App/Cart.swift:3:14 [Survived] boundary"))

        let markdown = MarkdownReport.render(report)
        #expect(markdown.contains("| `App/Cart.swift:3:14` | Survived (not run against all tests) | boundary |"))
        #expect(markdown.contains("| `App/Cart.swift:3:14` | Survived | boundary |"))
        #expect(markdown.contains("1 of the Survived are marked"))

        let xcode = XcodeReport.render(report).split(separator: "\n").map(String.init)
        #expect(xcode[0].contains("no test that reaches this code fails (not run against all tests: --no-recheck-survivors)"))
        #expect(xcode[1].contains("— no test fails ["))

        let agent = AgentReport(report: report)
        #expect(agent.gaps.map(\.narrowedOnly) == [true, nil])
        #expect(agent.fixes["narrowedOnly"]?.contains("--no-recheck-survivors") == true)
        #expect(AgentReport(report: Self.report([(.survived, "App/Cart.swift")])).fixes["narrowedOnly"] == nil)

        let stryker = String(decoding: try JSONEncoder().encode(StrykerReport(report: report)), as: UTF8.self)
        #expect(stryker.contains("not run against all tests (--no-recheck-survivors)"))

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONReport(report: report))) as? [String: Any]
        let results = json?["results"] as? [[String: Any]]
        #expect(results?.map { $0["narrowedOnly"] as? Bool } == [nil, true, nil])
        let selection = json?["testSelection"] as? [String: Any]
        #expect(selection?["recheckSurvivors"] as? Bool == false)
        #expect(selection?["survivedNarrowedOnly"] as? Int == 1)
    }

    @Test func strykerAndHTMLReports() throws {
        var report = Self.report([(.killed, "App/Cart.swift"), (.crash, "App/Cart.swift"), (.survived, "App/Cart.swift"), (.notReached, "App/Cart.swift"),
                                  (.timeout, "App/Cart.swift"), (.compileError, "App/Cart.swift"), (.accepted, "App/Cart.swift"), (.runnerError, "App/Cart.swift")])
        report.pendingKeys = ["App/Later.swift::f()::boundary::99"]
        report.ignored = [IgnoredMutant(operator: .boundary, file: "App/Cart.swift", enclosingDecl: "f()", point: ByteRange(start: 0, end: 1),
                                        start: SourcePosition(line: 2, column: 5), original: "<", replacement: "<=", reason: .pattern)]
        // Line 3 has a multi-byte character before the mutated column: the schema counts characters, not bytes.
        let source = "struct Cart {\n    // comment\n    let é = a > b\n}\n"
        let stryker = StrykerReport(report: report) { $0 == "App/Cart.swift" ? source : nil }
        #expect(stryker.schemaVersion == "2")
        let cart = try #require(stryker.files["App/Cart.swift"])
        #expect(cart.source == source)
        #expect(cart.language == "swift")
        #expect(cart.mutants.map(\.status) == ["Killed", "Killed", "Survived", "NoCoverage", "Timeout", "CompileError", "Ignored", "RuntimeError", "Ignored"])
        #expect(cart.mutants[1].statusReason?.hasPrefix("crash") == true)
        #expect(cart.mutants[7].statusReason?.hasPrefix("RunnerError") == true)
        #expect(cart.mutants[8].statusReason == "not generated: pattern")
        #expect(cart.mutants[0].location.start.line == 3)
        #expect(cart.mutants[0].location.start.column == 13)   // byte column 14, one two-byte character before it
        #expect(cart.mutants[0].killedBy == ["AppTests/CartTests/testTotal()"])
        #expect(stryker.testFiles["tests"]?.tests.map(\.id) == ["AppTests/CartTests/testTotal()"])
        #expect(stryker.files["App/Later.swift"]?.mutants.map(\.status) == ["Pending"])
        let decoded = try JSONSerialization.jsonObject(with: stryker.json()) as? [String: Any]
        #expect(decoded?["schemaVersion"] as? String == "2")
        #expect((decoded?["thresholds"] as? [String: Int]) == ["high": 80, "low": 60])

        let html = try HTMLReport.render(report)
        // A fixed version, checked by the browser (Subresource Integrity): the page holds the project's source
        #expect(html.contains("<script src=\"https://www.unpkg.com/mutation-testing-elements@3.9.0/dist/mutation-test-elements.js\" integrity=\"sha384-"))
        #expect(html.contains("crossorigin=\"anonymous\"></script>"))
        #expect(HTMLReport.elementsIntegrity.hasPrefix("sha384-") && HTMLReport.elementsIntegrity.count == 71)
        #expect(html.contains("<mutation-test-report-app"))
        #expect(html.contains("document.querySelector('mutation-test-report-app').report = {"))
        // `<` inside the embedded JSON (here in the detail "simulator <down>") cannot end the script element.
        #expect(html.contains("simulator \\u003cdown>"))
        #expect(!html.contains("simulator <down>"))
    }

    @Test func agentReportCarriesObligationsAndPutsUnreachedFunctionsFirst() throws {
        var report = Self.report([(.survived, "A.swift"), (.notReached, "B.swift"), (.killed, "A.swift")], root: "/nonexistent")
        report.results[1].mutant.scope = MutantScope(id: "Other.f()", lines: LineSpan(start: 1, end: 2))
        report.results[1].mutant.operator = .emptyBody
        let agent = AgentReport(report: report)
        #expect(agent.version == 5)
        #expect(agent.scopes.map(\.id) == ["Other.f()", "Cart.total()"])
        #expect(Set(agent.obligations.keys) == ["boundary", "empty-body"])
        #expect(agent.obligations["boundary"] == MutationOperator.boundary.testObligation)
        #expect(agent.reachedScore == 0.5)
        // The body of the function is in `source`; it is not repeated in the gap
        let emptyBody = try #require(agent.gaps.first { $0.mutator == "empty-body" })
        #expect(emptyBody.originalExpression == nil)
        // The expressions are given where they say more than `original` and `replacement` (`a > b` for `>`)
        let boundary = try #require(agent.gaps.first { $0.mutator == "boundary" })
        #expect(boundary.originalExpression == "a > b")
        #expect(boundary.mutatedExpression == "a >= b")
        report.results[0].mutant.originalExpression = report.results[0].mutant.original
        report.results[0].mutant.mutatedExpression = report.results[0].mutant.replacement
        let same = try #require(AgentReport(report: report).gaps.first { $0.mutator == "boundary" })
        #expect(same.originalExpression == nil)
        #expect(same.mutatedExpression == nil)
    }

    // MARK: work directories and layout

    @Test func layoutKeepsRootInsideTheCopyOfTheRepository() {
        let work = URL(fileURLWithPath: "/work")
        let nested = RunLayout(root: URL(fileURLWithPath: "/repo/ios/App"), copyRoot: URL(fileURLWithPath: "/repo"), workDirectory: work)
        #expect(nested.copyRoot.path == "/repo")
        #expect(nested.sourceDirectory.path == "/work/src")
        #expect(nested.rootInCopy.path == "/work/src/ios/App")
        let same = RunLayout(root: URL(fileURLWithPath: "/repo"), copyRoot: URL(fileURLWithPath: "/repo"), workDirectory: work)
        #expect(same.rootInCopy.path == "/work/src")
        let none = RunLayout(root: URL(fileURLWithPath: "/repo/ios"), copyRoot: nil, workDirectory: work)
        #expect(none.copyRoot.path == "/repo/ios")
        #expect(none.rootInCopy.path == "/work/src")
        // A copy root that does not contain the root is ignored.
        let outside = RunLayout(root: URL(fileURLWithPath: "/elsewhere/App"), copyRoot: URL(fileURLWithPath: "/repo"), workDirectory: work)
        #expect(outside.copyRoot.path == "/elsewhere/App")
    }

    @Test func workDirectoriesAreMarkedAndOnlyMarkedOnesAreRemovable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorkDirectoryInfo.defaultDirectory(forRoot: URL(fileURLWithPath: "/repo")).lastPathComponent.hasSuffix(".noindex"))
        #expect(WorkDirectoryInfo.defaultDirectory(forRoot: URL(fileURLWithPath: "/repo")) != WorkDirectoryInfo.defaultDirectory(forRoot: URL(fileURLWithPath: "/repo2")))
        #expect(WorkDirectoryInfo.isUnderCacheRoot(WorkDirectoryInfo.defaultDirectory(forRoot: URL(fileURLWithPath: "/repo"))))
        #expect(!WorkDirectoryInfo.isRemovable(dir))
        WorkDirectoryInfo.write(to: dir, root: URL(fileURLWithPath: "/nonexistent/root"))
        #expect(WorkDirectoryInfo.isRemovable(dir))
        let entry = WorkDirectoryInfo.entry(dir)
        #expect(entry.info?.root == "/nonexistent/root")
        #expect(entry.isOrphan)
        #expect(entry.sizeBytes > 0)
    }

    @Test func remainingTimeIsShortAndReadable() {
        #expect(RunSession.formatDuration(0) == "0s")
        #expect(RunSession.formatDuration(59.4) == "59s")
        #expect(RunSession.formatDuration(200) == "3m20s")
        #expect(RunSession.formatDuration(3725) == "1h02m")
    }

    // MARK: compile errors

    @Test func compileErrorsAreNarrowedBeforeBisecting() throws {
        let source = """
        final class C {
            var n = 0
            func f(_ a: Int) {
                let x = a > 0 ? 1 : 2
                n = x
                print(n)
            }
            func g(_ a: Int) -> Bool { a > 1 }
        }

        """
        let work = URL(fileURLWithPath: "/work")
        let options = GeneratorOptions(operators: [.boundary, .ternarySwap, .emptyBody])
        let mutants = FileProcessor(options: options).process(source: source, file: "C.swift", firstID: 0).mutants
        #expect(mutants.map(\.operator) == [.emptyBody, .boundary, .ternarySwap, .boundary])
        let xcode = XcodeOptions(container: [], scheme: nil, destination: "platform=macOS", testPlan: nil, extraBuildArguments: [],
                                 extraTestArguments: [], onlyTesting: [], skipTesting: [], buildSettings: [])
        let session = RunSession(config: RunConfiguration(root: URL(fileURLWithPath: "/repo"), files: ["C.swift"], changedLines: nil, onlyKeys: [],
                                                          xcode: xcode, prepareCommand: nil, workDirectory: work))
        func analyze(_ line: Int) -> (culprits: [Int], suspects: [Int], details: [String]) {
            let result = session.analyzeCompileErrors(in: "/work/src/C.swift:\(line):9: error: nope\n", mutants: mutants)
            return (result.culprits.map(\.0.id), result.suspects.map(\.id), result.culprits.map(\.1))
        }
        // On a mutated line: the mutants of that line, not the body-wide one that merely covers it.
        #expect(analyze(4).culprits == [1, 2])
        // In the same function but not on a mutated line: every mutant of that function (and only of that function).
        let widened = analyze(5)
        #expect(widened.culprits == [0, 1, 2])
        #expect(widened.suspects.isEmpty)
        #expect(widened.details.allSatisfy { $0.contains("excluded with the other mutants of C.f(_:)") })
        // Outside any mutated declaration: left for bisection over the file.
        let elsewhere = analyze(2)
        #expect(elsewhere.culprits.isEmpty)
        #expect(elsewhere.suspects == [0, 1, 2, 3])
        // Errors in files that are not mutated are not attributed.
        let other = session.analyzeCompileErrors(in: "/work/src/Other.swift:4:9: error: nope\n", mutants: mutants)
        #expect(other.culprits.isEmpty && other.suspects.isEmpty)
    }
}
