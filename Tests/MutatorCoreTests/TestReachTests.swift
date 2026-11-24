import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

@Suite("Tests that reach each mutant")
struct TestReachTests {
    /// What the trace file looks like on the simulator (XCTest relays lines with a barrier token).
    static let trace = """
    \(Instrumenter.testTraceMarker) R 9
    Test Case '-[AppTests.CartTests testTotal]' started.

    \(Instrumenter.testTraceMarker) R 1

    \(Instrumenter.testTraceMarker) R 2
    Test Case '-[AppTests.CartTests testTotal]' passed (0.001 seconds).
    Test Case '-[AppTests.CartTests testEmpty]' started.

    \(Instrumenter.testTraceMarker) R 1
    /src/CartTests.swift:9: error: -[AppTests.CartTests testEmpty] : XCTAssertEqual failed
    Test Case '-[AppTests.CartTests testEmpty]' failed (0.002 seconds).
    Test Suite 'CartTests' passed at 2026-11-20 10:00:00.000.

    \(Instrumenter.testTraceMarker) R 8
    XCTestOutputBarrier◇ Test run started.
    XCTestOutputBarrier◇ Suite Price rules started.
    XCTestOutputBarrier◇ Test 割引は合計から引く started.
    XCTestOutputBarrier
    \(Instrumenter.testTraceMarker) R 2

    \(Instrumenter.testTraceMarker) R 3
    ✔ Test 割引は合計から引く passed after 0.001 seconds.
    XCTestOutputBarrier◇ Test rounding(value:) started.
    XCTestOutputBarrier\u{200B}XCTestOutputBarrier◇ Test case passing 1 argument value → 1 to rounding(value:) started.

    \(Instrumenter.testTraceMarker) R 4
    ✘ Test rounding(value:) recorded an issue at PriceTests.swift:9:5: Expectation failed
    ✔ Test case passing 1 argument value → 1 to rounding(value:) passed after 0.001 seconds.
    XCTestOutputBarrier\u{200B}XCTestOutputBarrier◇ Test case passing 1 argument value → 2 to rounding(value:) started.
    ✘ Test rounding(value:) with 2 test cases failed after 0.002 seconds with 1 issue.
    XCTestOutputBarrier◇ Test known() started.
    ━ Test known() recorded a known issue at PriceTests.swift:20:5: Issue recorded
    ━ Test known() passed after 0.001 seconds with 1 known issue.
    XCTestOutputBarrier✔ Suite Price rules passed after 0.005 seconds.
    XCTestOutputBarrier◇ Test freeFunction() started.

    \(Instrumenter.testTraceMarker) R 5
    ✔ Test freeFunction() passed after 0.001 seconds.
    some log line R 77
    """

    @Test func reachIsAttributedToTheRunningTest() {
        let reach = TestReach.parse(Self.trace)
        #expect(reach.reliable)
        #expect(reach.reached == [1, 2, 3, 4, 5, 8, 9])
        #expect(reach.suites[1] == ["CartTests"])
        #expect(reach.suites[2] == ["CartTests", "Price rules"])
        #expect(reach.suites[3] == ["Price rules"])
        #expect(reach.suites[4] == ["Price rules"])
        #expect(reach.tests[1] == ["CartTests/testTotal", "CartTests/testEmpty"])
        #expect(reach.tests[2] == ["CartTests/testTotal", "Price rules/割引は合計から引く"])
        #expect(reach.tests[4] == ["Price rules/rounding(value:)"])
        // Before a test start, between tests, and in a Swift Testing test outside any suite:
        // not attributable, so these mutants are run against everything.
        #expect(reach.outside == [5, 8, 9])
    }

    /// The redirect starts inside the first test that evaluates a switch, so the start lines of that test and of
    /// its suite are missing. The records at the head of the file belong to the test whose end comes first.
    @Test func theTestThatWasRunningWhenTheRedirectStartedIsRecovered() {
        let swiftTesting = """

        \(Instrumenter.testTraceMarker) R 1

        \(Instrumenter.testTraceMarker) R 2
        ✔ Test "空の入力は .none を返す" passed after 0.002 seconds.
        ◇ Test "second" started.
        \(Instrumenter.testTraceMarker) R 2
        ◇ Test case passing 1 argument code → "✔ Test "second" with 2 test cases passed after 0.001 seconds.
        ◇ Test third() started.
        \(Instrumenter.testTraceMarker) R 3
        ➜ Test "device only" skipped: "not on the simulator"
        ✔ Test third() passed after 0.001 seconds.
        ✔ Suite "Checker Tests" passed after 0.025 seconds.
        ◇ Suite OtherTests started.
        ◇ Test other() started.
        \(Instrumenter.testTraceMarker) R 3
        ✔ Test other() passed after 0.001 seconds.
        ✔ Suite OtherTests passed after 0.001 seconds.
        """
        let reach = TestReach.parse(swiftTesting)
        #expect(reach.reliable)
        #expect(reach.outside.isEmpty)
        #expect(reach.suites[1] == ["Checker Tests"])
        #expect(reach.tests[1] == ["Checker Tests/空の入力は .none を返す"])
        // The suite is known only once its end line arrives; the tests that ran before that are attributed then.
        #expect(reach.suites[2] == ["Checker Tests"])
        #expect(reach.tests[2] == ["Checker Tests/空の入力は .none を返す", "Checker Tests/second"])
        #expect(reach.suites[3] == ["Checker Tests", "OtherTests"])

        let xcTest = """
        \(Instrumenter.testTraceMarker) R 7
        Test Case '-[AppTests.CartTests testTotal]' passed (0.001 seconds).
        Test Case '-[AppTests.CartTests testEmpty]' started.
        \(Instrumenter.testTraceMarker) R 8
        Test Case '-[AppTests.CartTests testEmpty]' passed (0.001 seconds).
        """
        let recovered = TestReach.parse(xcTest)
        #expect(recovered.tests[7] == ["CartTests/testTotal"])
        #expect(recovered.outside.isEmpty)

        // Reached while the app was launching: the test runner announces itself afterwards, so nothing is recovered.
        let launch = """
        \(Instrumenter.testTraceMarker) R 7
        Test Suite 'All tests' started at 2026-11-20 10:00:00.000.
        Test Case '-[AppTests.CartTests testTotal]' started.
        Test Case '-[AppTests.CartTests testTotal]' passed (0.001 seconds).
        """
        #expect(TestReach.parse(launch).outside == [7])
        #expect(TestReach.parse(launch).suites[7] == nil)
    }

    @Test func overlappingSwiftTestingTestsMakeTheTraceUnreliable() {
        let parallel = """
        ◇ Suite A started.
        ◇ Test one() started.
        ◇ Test two() started.
        \(Instrumenter.testTraceMarker) R 1
        ✔ Test one() passed after 0.001 seconds.
        ✔ Test two() passed after 0.001 seconds.
        ✔ Suite A passed after 0.002 seconds.
        """
        #expect(!TestReach.parse(parallel).reliable)
    }

    static var tree: [String: Any] { [
        "testNodes": [[
            "nodeType": "Test Plan", "name": "App",
            "children": [[
                "nodeType": "Unit test bundle", "name": "AppTests",
                "children": [
                    ["nodeType": "Test Suite", "name": "CartTests", "children": [
                        ["nodeType": "Test Case", "name": "testTotal()", "nodeIdentifier": "CartTests/testTotal()"],
                        ["nodeType": "Test Case", "name": "testEmpty()", "nodeIdentifier": "CartTests/testEmpty()"],
                    ]],
                    ["nodeType": "Test Suite", "name": "Price rules", "children": [
                        ["nodeType": "Test Case", "name": "割引は合計から引く", "nodeIdentifier": "PriceTests/discount()"],
                        ["nodeType": "Test Case", "name": "rounding(value:)", "nodeIdentifier": "PriceTests/rounding(value:)", "children": [
                            ["nodeType": "Arguments", "name": "1"],
                        ]],
                    ]],
                    ["nodeType": "Test Case", "name": "freeFunction()", "nodeIdentifier": "freeFunction()"],
                ],
            ]],
        ]],
    ] }

    @Test func suitesAreMappedFromDisplayNamesToIdentifiers() {
        let suites = TestSuiteInfo.parse(Self.tree)
        #expect(suites.map(\.name) == ["CartTests", "Price rules", ""])
        #expect(suites.map(\.identifier) == ["CartTests", "PriceTests", ""])
        #expect(suites.map(\.testCount) == [2, 2, 1])
        #expect(suites[1].onlyTestingIdentifier == "AppTests/PriceTests")
    }

    @Test func selectionNarrowsOnlyWhenItIsCertain() {
        let reach = TestReach.parse(Self.trace)
        let suites = TestSuiteInfo.parse(Self.tree)
        let selector = ReachSelector(reach: reach, suites: suites, totalTestCount: 5)
        #expect(selector.usable)
        #expect(selector.selection(for: 1)?.onlyTesting == ["AppTests/CartTests"])
        #expect(selector.selection(for: 1)?.testCount == 2)
        #expect(selector.selection(for: 2)?.onlyTesting == ["AppTests/CartTests", "AppTests/PriceTests"])
        #expect(selector.selection(for: 2)?.testCount == 4)
        // Evaluated by one test only: it may be code that runs once per process (a `static let`, a singleton's
        // init), which the tests of other suites depend on without evaluating it. Not narrowed.
        #expect(reach.tests[3]?.count == 1)
        #expect(selector.selection(for: 3) == nil)
        // With the evidence of a shared process (the switch is evaluated in every run of the tests), it is narrowed
        #expect(selector.selection(for: 3, evenlyEvaluated: true)?.onlyTesting == ["AppTests/PriceTests"])
        var twice = reach
        twice.tests[3]?.append("Price rules/another()")
        #expect(ReachSelector(reach: twice, suites: suites, totalTestCount: 5).selection(for: 3)?.onlyTesting == ["AppTests/PriceTests"])
        // Reached outside a known test, or never reached: no narrowing.
        #expect(selector.selection(for: 5) == nil)
        #expect(selector.selection(for: 9) == nil)
        #expect(selector.selection(for: 42) == nil)

        // The suites do not add up to the tests that ran: nothing is narrowed.
        #expect(!ReachSelector(reach: reach, suites: suites, totalTestCount: 6).usable)
        #expect(ReachSelector(reach: reach, suites: suites, totalTestCount: 6).selection(for: 1) == nil)
        // Two suites with the same display name: that name is not narrowed.
        var ambiguous = suites
        ambiguous.append(TestSuiteInfo(bundle: "OtherTests", name: "CartTests", identifier: "CartTests", testCount: 1))
        let other = ReachSelector(reach: reach, suites: ambiguous, totalTestCount: 6)
        #expect(other.selection(for: 1) == nil)
        #expect(ReachSelector(reach: twice, suites: ambiguous, totalTestCount: 6).selection(for: 3)?.onlyTesting == ["AppTests/PriceTests"])
        // An unreliable trace: nothing is narrowed.
        var unreliable = reach
        unreliable.reliable = false
        #expect(ReachSelector(reach: unreliable, suites: suites, totalTestCount: 5).selection(for: 1) == nil)
    }

    /// The helper really writes the per-test trace: stderr goes into the file and a switch is recorded again
    /// after something else (a test boundary) was written.
    @Test(.enabled(if: ExecutionOracleTests.available))
    func helperRecordsReachPerTest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcmutate-s8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = """
        import Foundation
        func isBig(_ x: Int) -> Bool { x > 10 }
        func isSmall(_ x: Int) -> Bool { x < 3 }
        func boundary(_ text: String) { FileHandle.standardError.write(Data((text + "\\n").utf8)) }
        _ = isBig(1)
        boundary("Test Case '-[M.ATests testOne]' started.")
        _ = isBig(1); _ = isBig(2); _ = isSmall(1)
        boundary("Test Case '-[M.ATests testOne]' passed (0.001 seconds).")
        boundary("Test Case '-[M.BTests testTwo]' started.")
        _ = isBig(3)
        boundary("Test Case '-[M.BTests testTwo]' passed (0.001 seconds).")

        """
        let result = FileProcessor(options: GeneratorOptions(operators: [.boundary])).process(source: source, file: "main.swift", firstID: 0)
        expectValidInstrumentation(result)
        let file = dir.appendingPathComponent("main.swift")
        try result.instrumented.write(to: file, atomically: true, encoding: .utf8)
        let exe = dir.appendingPathComponent("main").path
        let compile = try #require(runProcess("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-warnings-as-errors", "-o", exe, file.path]))
        try #require(compile.status == 0, "\(compile.output)")
        let trace = dir.appendingPathComponent("tests.trace").path
        let run = try #require(runProcess(exe, [], environment: [Instrumenter.traceEnvironmentVariable: trace, Instrumenter.testTraceEnvironmentVariable: "1"]))
        #expect(run.status == 0)
        let reach = TestReach.parse(try String(contentsOfFile: trace, encoding: .utf8))
        let big = try #require(result.mutants.first { $0.start.line == 2 }).id
        let small = try #require(result.mutants.first { $0.start.line == 3 }).id
        #expect(reach.suites[big] == ["ATests", "BTests"])
        #expect(reach.suites[small] == ["ATests"])
        // The very first evaluation happens before any test: the next boundary is a test start, so it stays unattributed.
        #expect(reach.outside == [big])
        #expect(reach.tests[big] == ["ATests/testOne", "BTests/testTwo"])

        // Without the per-test variable the trace keeps its old form, one line per switch.
        let plain = dir.appendingPathComponent("plain.trace")
        _ = runProcess(exe, [], environment: [Instrumenter.traceEnvironmentVariable: plain.path])
        #expect(Trace.read(plain).reached == [big, small])
        #expect(try String(contentsOf: plain, encoding: .utf8).split(separator: "\n").count == 2)
    }
}
