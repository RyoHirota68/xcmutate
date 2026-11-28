/// Decides the verdict for the run of one mutant (a pure function).
///
/// Rules:
/// - **No result without an activation record (`A <ID>`) is treated as a result of the mutant**. Even if tests fail or
///   time out it becomes RunnerError (subject to retry); if the tests pass it becomes NotActivated
/// - Timeout → Timeout (detected)
/// - One or more tests failed → Killed (Crash if the failure message has a crash marker)
/// - All tests passed → Survived
/// - **A run whose test count (the total including skipped tests) differs from the baseline gets no verdict** (RunnerError). Treating "all passed" as Survived
///   in a run where 0 tests or only some of the tests ran would create a false survivor. Even with failures, if the set of tests
///   that ran differs, it is unclear what is being compared, so it is not Killed. The exception is a crash: when the process dies,
///   the remaining tests do not run and the count drops, so with a crash marker it becomes Crash even if the count differs
/// - Anything else (no test ran, there is no xcresult, etc.) → RunnerError
public enum Judgement {
    public struct Result: Equatable, Sendable {
        public var status: MutantStatus
        public var killedBy: [String]
        public var detail: String?
    }

    public static func classify(_ o: MutantObservation, baseline: BaselineEvidence?) -> Result {
        // A failing run in a shared process is recorded only after the driver has compared its test count with a run
        // without mutants and the same tests have passed again without the mutant (`SharedProcess`). With narrowed tests
        // the driver's count is that of the narrowed selection, which is what `baseline` holds too.
        if o.sharedProcess == true, !o.timedOut, o.activated, let summary = o.summary, summary.failedTests > 0,
           baseline == nil || summary.totalTestCount == baseline?.testCount {
            let detection = summary.detection
            return Result(status: .killed, killedBy: detection.tests,
                          detail: detection.quoted.map { "\($0.test) failed in a shared process" })
        }
        // A run of all selected tests that the driver stopped at its first failing test: up to that test it is the run of
        // all tests (the same order), so the failure is the same evidence as in a run to the end. The count of tests
        // is that of the tests that ran; the other conditions of a Killed (the switch evaluated as active, the tests
        // passed without mutants on the destination since the last run that did not pass) are those of any run.
        if o.stoppedAtFirstFailure == true, !o.timedOut, o.activated, let summary = o.summary, summary.failedTests > 0 {
            let detection = summary.detection
            let ran = baseline.map { "\(summary.totalTestCount) of \($0.testCount) tests" } ?? "\(summary.totalTestCount) tests"
            return Result(status: .killed, killedBy: detection.tests,
                          detail: "\(detection.quoted?.test ?? "a test") failed; the run of all selected tests was stopped at its first failing test (\(ran) had run)")
        }
        // The host ended unexpectedly and the run was stopped there (`xcodebuild` would have started the host again for
        // every test that is left). No summary exists; the crash is what the log of xcodebuild said.
        if let test = o.crashedIn {
            // The log of xcodebuild names an XCTest test by class and method, which is its identifier, and a Swift
            // Testing test by its function alone or by its display name (`@Test("…")`), which is not: such a name
            // is said in the detail and not listed among the tests (`killedBy` holds identifiers, which --reuse
            // and -only-testing can use)
            let identified = Self.isTestIdentifier(test)
            var place = test.isEmpty ? (o.crashEvidence == nil ? o.limitNote.map { " (\($0))" } ?? "" : "") : identified ? " in \(test)" : " in the Swift Testing test \(test)"
            let tests = identified ? [test] : []
            // Known from a crash report, not from xcodebuild's log: the run was stopped by a limit, and the detail says so
            if let evidence = o.crashEvidence {
                place += ": " + evidence
                if o.activated, o.failedBeforeCrash != true { return Result(status: .crash, killedBy: tests, detail: "Crash: the test host ended unexpectedly\(place)") }
            }
            if o.activated, o.failedBeforeCrash == true {
                return Result(status: .killed, killedBy: tests, detail: "a test failed\(place), and the test host then ended unexpectedly; the run was stopped there")
            }
            return o.activated
                ? Result(status: .crash, killedBy: tests, detail: "Crash: the test host ended unexpectedly\(place); the run was stopped there")
                : Result(status: .runnerError, killedBy: [], detail: "the test host ended unexpectedly\(place) before the switch was evaluated as active")
        }
        var result = classify(exitStatus: o.exitStatus, timedOut: o.timedOut, summary: o.summary, activated: o.activated,
                              timeout: o.timeoutSeconds, runnerErrorPattern: o.runnerErrorPattern, baseline: baseline)
        // Which limit stopped the run, when it was not the limit of the whole run
        if result.status == .timeout, let note = o.limitNote { result.detail = note }
        return result
    }

    /// Whether a name taken from a log is the identifier of a test, `Suite/method()`.
    static func isTestIdentifier(_ name: String) -> Bool {
        name.contains("/") && name.hasSuffix("()") && !name.contains(" ") && !name.hasPrefix("\"")
    }

    public static func classify(exitStatus: Int32, timedOut: Bool, summary: TestSummary?, activated: Bool,
                                timeout: Double, logText: String) -> Result {
        classify(exitStatus: exitStatus, timedOut: timedOut, summary: summary, activated: activated, timeout: timeout,
                 runnerErrorPattern: RunnerErrorPatterns.match(in: logText), baseline: nil)
    }

    public static func classify(exitStatus: Int32, timedOut: Bool, summary: TestSummary?, activated: Bool,
                                timeout: Double, runnerErrorPattern: String?, baseline: BaselineEvidence?) -> Result {
        if timedOut {
            return activated
                ? Result(status: .timeout, killedBy: [], detail: "exceeded \(Int(timeout))s")
                : Result(status: .runnerError, killedBy: [], detail: "timed out before the switch was evaluated as active (exceeded \(Int(timeout))s)")
        }
        // Whether the same tests as in the baseline ran (compared by count)
        var sameTests = true
        var difference = ""
        // The number of skipped tests is not compared: a mutant can change a skip condition (XCTSkip), and that is the mutant's
        // effect itself (in BonMot there were 3 cases where a test that should have been skipped ran and failed = detected)
        if let summary, let baseline, summary.totalTestCount != baseline.testCount {
            sameTests = false
            difference = "\(summary.totalTestCount) tests ran, the baseline ran \(baseline.testCount)"
        }
        if exitStatus == 0, let summary, summary.failedTests == 0, summary.totalTestCount > 0 {
            guard sameTests else {
                return Result(status: .runnerError, killedBy: [], detail: "not judged: \(difference)")
            }
            return activated
                ? Result(status: .survived, killedBy: [], detail: nil)
                : Result(status: .notActivated, killedBy: [], detail: "tests passed but the switch was never evaluated as active")
        }
        if let summary, summary.failedTests > 0 {
            guard activated else {
                return Result(status: .runnerError, killedBy: [],
                              detail: "tests failed without the switch being activated: \(summary.failures.first?.message ?? "")")
            }
            guard sameTests || summary.hasCrash else {
                return Result(status: .runnerError, killedBy: [], detail: "not judged: tests failed, but \(difference)")
            }
            let detection = summary.detection
            return Result(status: summary.hasCrash ? .crash : .killed, killedBy: detection.tests,
                          detail: detection.quoted.map { "\($0.test): \($0.message)" })
        }
        return Result(status: .runnerError, killedBy: [],
                      detail: runnerErrorPattern ?? "xcodebuild exited with status \(exitStatus) and no test failures were recorded")
    }
}
