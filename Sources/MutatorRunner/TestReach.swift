import Foundation
import MutatorCore

/// Which tests reached which switch, recorded in one baseline run (`--select-tests reach`).
///
/// The instrumented code redirects the standard error of the test process into the trace file
/// (`Instrumenter.testTraceEnvironmentVariable`), so the lines that XCTest and Swift Testing print when a test
/// starts and ends, and the reach records of the helper (`__xcmutate R <ID>`), end up in one file in the order
/// in which they happened. A reach record belongs to the test that is running when it is written.
///
/// The rule behind narrowing is "a test that did not evaluate the switch cannot be changed by the mutant". It does
/// not hold for a value that is computed once and then kept: the tests that read the kept value do not evaluate
/// the switch. `ReachSelector` therefore does not narrow a switch that only one test evaluated, and the executor
/// does not narrow a mutant that a shared process found to be evaluated before the tests or unevenly. A value
/// that several tests compute and others read from a cache is not covered by either rule (docs/usage.md).
///
/// Attribution is used only where it is certain; everything else falls back to running the whole selection:
/// - a record written while no test is known to be running (`outside`: before the first test boundary was
///   captured, during app launch, in a Swift Testing test that is not in a suite)
/// - Swift Testing tests that overlap (in-process parallelism): `reliable` becomes false and nothing is narrowed
public struct TestReach: Sendable, Equatable {
    public var reached: Set<Int> = []
    /// Switch ID → names of the suites (XCTest class, or outermost Swift Testing suite as printed) whose tests reached it.
    public var suites: [Int: Set<String>] = [:]
    /// Switch ID → tests that reached it, as `Suite/test` (names as printed, for reports), in order of first reach.
    public var tests: [Int: [String]] = [:]
    public var outside: Set<Int> = []
    public var reliable = true

    public static func parse(_ text: String) -> TestReach {
        var result = TestReach()
        var xcTest: (suite: String, test: String)?
        var suiteStack: [String] = []
        var swiftTest: String?
        // The redirect starts at the first switch evaluation, so the line that announced the test running at that
        // moment (and its suite) is not in the file. If the file starts with reach records that are followed
        // directly by the end of a test — no other boundary in between — those records belong to that test.
        var sawBoundary = false
        var leading: [Int] = []
        /// Records attributed to a Swift Testing test whose suite start was also lost: (IDs, test name).
        var awaitingSuite: [(ids: [Int], test: String)] = []
        let marker = Instrumenter.testTraceMarker + " R "

        func attribute(_ id: Int, suite: String, test: String) {
            result.suites[id, default: []].insert(suite)
            let name = suite + "/" + test
            if result.tests[id]?.contains(name) != true { result.tests[id, default: []].append(name) }
        }
        func unquoted(_ name: Substring) -> String {
            name.count >= 2 && name.hasPrefix("\"") && name.hasSuffix("\"") ? String(name.dropFirst().dropLast()) : String(name)
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            // XCTest prefixes lines it relays with a barrier token (and a zero-width space between repeats)
            var line = Substring(raw.replacingOccurrences(of: "XCTestOutputBarrier", with: "").replacingOccurrences(of: "\u{200B}", with: ""))
            if let range = line.range(of: marker) {
                guard let id = Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) else { continue }
                result.reached.insert(id)
                if let current = xcTest {
                    attribute(id, suite: current.suite, test: current.test)
                } else if let test = swiftTest, let suite = suiteStack.first {
                    attribute(id, suite: suite, test: test)
                } else if let test = swiftTest {
                    // In a test whose suite did not start in the file: the suite began before the redirect
                    awaitingSuite.append(([id], test))
                } else if !sawBoundary {
                    leading.append(id)
                } else {
                    result.outside.insert(id)
                }
                continue
            }
            // XCTest: Test Case '-[Module.Class method]' started. / passed (0.001 seconds). / failed (…).
            if let start = line.range(of: "Test Case '-["), let end = line.range(of: "]' ", range: start.upperBound..<line.endIndex) {
                let parts = line[start.upperBound..<end.lowerBound].split(separator: " ", maxSplits: 1)
                let state = line[end.upperBound...]
                guard parts.count == 2 else { continue }
                let type = parts[0].split(separator: ".").last.map(String.init) ?? String(parts[0])
                if state.hasPrefix("started") {
                    result.outside.formUnion(leading)
                    leading = []
                    xcTest = (type, String(parts[1]))
                } else if state.hasPrefix("passed") || state.hasPrefix("failed") || state.hasPrefix("skipped") {
                    if xcTest == nil, !sawBoundary { for id in leading { attribute(id, suite: type, test: String(parts[1])) } } else { result.outside.formUnion(leading) }
                    leading = []
                    xcTest = nil
                }
                sawBoundary = true
                continue
            }
            if line.contains("Test Suite '") { result.outside.formUnion(leading); leading = []; sawBoundary = true; continue }
            // Swift Testing: "◇ Suite X started." "◇ Test f() started." "✔ Test f() passed after …" "✘ Suite X failed after …"
            guard let first = line.unicodeScalars.first, !first.isASCII else { continue }
            line = line.drop { !$0.isASCII || $0 == " " }
            if line.hasPrefix("Test run ") { result.outside.formUnion(leading); leading = []; sawBoundary = true; continue }
            for (kind, isSuite) in [("Suite ", true), ("Test ", false)] where line.hasPrefix(kind) {
                let rest = line.dropFirst(kind.count)
                if rest.hasPrefix("case passing ") { break }
                if rest.hasSuffix(" started.") {
                    let name = unquoted(rest.dropLast(" started.".count))
                    result.outside.formUnion(leading)
                    leading = []
                    sawBoundary = true
                    if isSuite {
                        suiteStack.append(name)
                    } else {
                        // A start while another test is open: the end line of the previous test was lost (output
                        // of the test glued onto it). Treat the previous test as over. Real overlap (parallel
                        // tests) shows up below, as the end of a test that is not the current one.
                        swiftTest = name
                    }
                } else if let end = [" passed after ", " failed after ", " skipped", " recorded "].compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
                          !rest[end.lowerBound...].hasPrefix(" recorded ") {
                    var raw = rest[..<end.lowerBound]
                    // A parameterized test ends with "Test f(x:) with 3 test cases passed after …"
                    if let cases = raw.range(of: " with ", options: .backwards), raw[cases.upperBound...].contains(" test case") {
                        raw = raw[..<cases.lowerBound]
                    }
                    let name = unquoted(raw)
                    if isSuite {
                        if let index = suiteStack.lastIndex(of: name) {
                            suiteStack.removeSubrange(index...)
                        } else {
                            // The suite started before the redirect: it is the suite of the tests seen so far without one
                            for entry in awaitingSuite { for id in entry.ids { attribute(id, suite: name, test: entry.test) } }
                            awaitingSuite = []
                        }
                    } else if rest[end.lowerBound...].hasPrefix(" skipped"), swiftTest != name {
                        // A skipped test has no start line; it says nothing about the test that is running
                    } else if let current = swiftTest {
                        if current == name { swiftTest = nil } else { result.reliable = false }
                    } else if !sawBoundary, !leading.isEmpty {
                        if let suite = suiteStack.first {
                            for id in leading { attribute(id, suite: suite, test: name) }
                        } else {
                            awaitingSuite.append((leading, name))
                        }
                        leading = []
                    }
                    result.outside.formUnion(leading)
                    leading = []
                    sawBoundary = true
                }
            }
        }
        result.outside.formUnion(leading)
        // Tests whose suite never showed up (a test outside any suite): not attributable
        for entry in awaitingSuite { result.outside.formUnion(entry.ids) }
        return result
    }
}

/// The suites of a test run, read from the result bundle (`xcresulttool get test-results tests`).
/// Console output names suites and tests by display name; this maps a name to what `-only-testing:` takes.
public struct TestSuiteInfo: Sendable, Equatable {
    /// Test bundle (the target name in `-only-testing:<target>/<suite>`).
    public var bundle: String
    /// Name as shown (the display name of a Swift Testing suite, the class name for XCTest).
    public var name: String
    /// Identifier of the suite (the type name), taken from the identifiers of its tests.
    public var identifier: String
    public var testCount: Int
    /// Seconds the tests of the suite took in that run; nil if the result bundle does not say.
    public var seconds: Double?

    public var onlyTestingIdentifier: String { "\(bundle)/\(identifier)" }

    /// `0,0012s`, `1.5s`, `2m 3s` of the result bundle's JSON as seconds.
    static func seconds(_ text: String) -> Double? {
        var total = 0.0
        var seen = false
        for part in text.split(separator: " ") {
            let unit = part.last
            guard let value = Double(part.dropLast().replacingOccurrences(of: ",", with: ".")) else { return nil }
            switch unit {
            case "s": total += value
            case "m": total += value * 60
            case "h": total += value * 3600
            default: return nil
            }
            seen = true
        }
        return seen ? total : nil
    }

    static func load(_ bundle: URL) -> [TestSuiteInfo]? {
        guard let result = try? Subprocess.capture(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle.path, "--compact"], timeout: 300),
              result.status == 0, let start = result.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any] else { return nil }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> [TestSuiteInfo] {
        var suites: [TestSuiteInfo] = []
        func cases(_ node: [String: Any]) -> [String] {
            if node["nodeType"] as? String == "Test Case" { return [node["nodeIdentifier"] as? String ?? ""] }
            return (node["children"] as? [[String: Any]] ?? []).flatMap(cases)
        }
        /// The time of the test cases under a node; nil if one of them has none.
        func time(_ node: [String: Any]) -> Double? {
            if node["nodeType"] as? String == "Test Case" {
                if let seconds = node["durationInSeconds"] as? Double { return seconds }
                return (node["duration"] as? String).flatMap(TestSuiteInfo.seconds)
            }
            var total = 0.0
            for child in node["children"] as? [[String: Any]] ?? [] {
                guard let seconds = time(child) else { return nil }
                total += seconds
            }
            return total
        }
        func walk(_ node: [String: Any], bundle: String?) {
            let type = node["nodeType"] as? String ?? ""
            let children = node["children"] as? [[String: Any]] ?? []
            if type.hasSuffix("test bundle") {
                for child in children { walk(child, bundle: node["name"] as? String) }
            } else if type == "Test Suite", let bundle {
                let identifiers = cases(node)
                // "Suite/test()" → "Suite"; nested suites "Outer/Inner/test()" → the outermost suite "Outer"
                let own = Set(identifiers.compactMap { $0.split(separator: "/").first.map(String.init) })
                if own.count == 1, let identifier = own.first {
                    suites.append(TestSuiteInfo(bundle: bundle, name: node["name"] as? String ?? "", identifier: identifier, testCount: identifiers.count, seconds: time(node)))
                } else {
                    suites.append(TestSuiteInfo(bundle: bundle, name: node["name"] as? String ?? "", identifier: "", testCount: identifiers.count, seconds: time(node)))
                }
            } else if type == "Test Case", let bundle {
                // a test outside any suite
                suites.append(TestSuiteInfo(bundle: bundle, name: "", identifier: "", testCount: 1, seconds: time(node)))
            } else {
                for child in children { walk(child, bundle: bundle) }
            }
        }
        for node in json["testNodes"] as? [[String: Any]] ?? [] { walk(node, bundle: nil) }
        return suites
    }
}

/// Turns the reach of one mutant into the tests to run for it.
public struct ReachSelector: Sendable {
    public var reach: TestReach
    public var suites: [TestSuiteInfo]
    /// False when the suites of the result bundle do not add up to the number of tests that ran, or the trace
    /// showed overlapping tests: then nothing is narrowed.
    public var usable: Bool

    public init(reach: TestReach, suites: [TestSuiteInfo], totalTestCount: Int) {
        self.reach = reach
        self.suites = suites
        usable = reach.reliable && !suites.isEmpty && suites.reduce(0) { $0 + $1.testCount } == totalTestCount
    }

    /// The `-only-testing:` identifiers and the number of tests they hold, or nil to run the whole selection.
    /// - Parameter evenlyEvaluated: a shared process has shown that the switch is evaluated equally often in two runs
    ///   of the tests in one process (the driver runs a mutant only then), so it is not code that runs once per process.
    public func selection(for id: Int, evenlyEvaluated: Bool = false) -> (onlyTesting: [String], testCount: Int)? {
        guard usable, !reach.outside.contains(id), let names = reach.suites[id], !names.isEmpty else { return nil }
        // A switch that exactly one test evaluated may be in code that runs once per process: the initial value of
        // a `static let` or a global, a `lazy var` of an object that lives on, the `init` of a singleton and what
        // it calls. The test that touched it first evaluated it; the tests that use the stored value did not, and
        // they can be in other suites. Syntax cannot tell such code from code that one test calls, and neither can
        // one run of the tests: without the evidence of a shared process, neither is narrowed.
        guard evenlyEvaluated || (reach.tests[id]?.count ?? 0) > 1 else { return nil }
        var chosen: [TestSuiteInfo] = []
        for name in names.sorted() {
            // A name must mean exactly one suite, with a usable identifier
            let matches = suites.filter { $0.name == name || $0.identifier == name }
            guard matches.count == 1, let suite = matches.first, !suite.identifier.isEmpty,
                  suites.filter({ $0.bundle == suite.bundle && $0.identifier == suite.identifier }).count == 1 else { return nil }
            chosen.append(suite)
        }
        // The suites that reach the mutant are all the suites there are: that is the whole selection, not a narrowed one
        // (nothing to mark as resting on narrowed tests, and nothing to run again against "the whole selection")
        let count = chosen.reduce(0) { $0 + $1.testCount }
        if Set(chosen.map(\.onlyTestingIdentifier)) == Set(suites.map(\.onlyTestingIdentifier)) { return nil }
        return (chosen.map(\.onlyTestingIdentifier).sorted(), count)
    }

    /// Seconds that each suite took in the baseline, by `-only-testing:` identifier; nil unless the time of every
    /// test is known (then no timeout is narrowed).
    public var suiteSeconds: [String: Double]? {
        guard usable else { return nil }
        var result: [String: Double] = [:]
        var all = true
        for suite in suites {
            guard let seconds = suite.seconds else { all = false; continue }
            if !suite.identifier.isEmpty { result[suite.onlyTestingIdentifier, default: 0] += seconds }
        }
        return all ? result : nil
    }

    /// The suites of failed tests as `-only-testing:` identifiers. A failed test is named `Suite/test()` in a
    /// report; a name that does not mean exactly one suite is left out.
    public func suiteIdentifiers(ofFailedTests tests: [String]) -> [String] {
        var result: Set<String> = []
        for test in tests {
            guard let name = test.split(separator: "/").first.map(String.init) else { continue }
            let matches = suites.filter { !$0.identifier.isEmpty && ($0.identifier == name || $0.name == name) }
            if matches.count == 1, let suite = matches.first { result.insert(suite.onlyTestingIdentifier) }
        }
        return result.sorted()
    }

    /// Number of tests in the suites with these `-only-testing:` identifiers; nil if one is not a known suite.
    public func testCount(of identifiers: [String]) -> Int? {
        var count = 0
        for identifier in identifiers {
            guard let suite = suites.first(where: { $0.onlyTestingIdentifier == identifier }) else { return nil }
            count += suite.testCount
        }
        return count
    }
}
