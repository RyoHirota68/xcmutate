import Foundation
import Testing
@testable import MutatorCore
@testable import MutatorRunner

/// What a run in CI needs. Annotations for GitHub, a limit on the number of mutants, a limit on the time.
@Suite("Annotations, --max-mutants, --time-limit, limits inside a run, reports")
struct LimitsAndReportingTests {
    // MARK: Annotations for GitHub Actions

    @Test func undetectedMutantsBecomeWarningsOnTheirLines() {
        let report = ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift"), (.notReached, "App/Other.swift"), (.survived, "App/Cart.swift"),
                                               (.runnerError, "App/Cart.swift")])
        let lines = GitHubReport.render(report, workspace: nil).split(separator: "\n").map(String.init)
        // First that mutants could not be run; then Survived, then NotReached; nothing for Killed
        #expect(lines == [
            "::warning title=xcmutate%3A incomplete::1 of 4 mutants could not be run and are not in the score (RunnerError 1). The score covers only the mutants that were judged.",
            "::warning file=App/Cart.swift,line=3,col=14,title=Mutant survived%3A boundary::`>` -> `>=`: no test fails with this change. Key: App/Cart.swift::Cart.total()::boundary::2",
            "::warning file=App/Other.swift,line=3,col=14,title=Mutant not reached%3A boundary::`>` -> `>=`: no test executes this code. Key: App/Other.swift::Cart.total()::boundary::1",
        ])
    }

    /// GitHub resolves `file` against the checkout; the root of a run can be a directory inside it.
    @Test func pathsAreRelativeToTheWorkspace() {
        let report = ConfigJournalAndReportTests.report([(.survived, "Sources/A.swift")], root: "/work/repo/Packages/Core")
        #expect(GitHubReport.render(report, workspace: "/work/repo").hasPrefix("::warning file=Packages/Core/Sources/A.swift,line=3,"))
        // A workspace that does not hold the root: the path relative to the root, as in the other reports
        #expect(GitHubReport.render(report, workspace: "/elsewhere").hasPrefix("::warning file=Sources/A.swift,line=3,"))
        #expect(GitHubReport.render(report, workspace: "/work/repo/Packages/Core").hasPrefix("::warning file=Sources/A.swift,line=3,"))
    }

    /// A message must not be able to end the command or start another one, and a property value must not be able to
    /// add a property.
    @Test func textIsEscapedForWorkflowCommands() {
        #expect(GitHubReport.data("50% of\r\nlines") == "50%25 of%0D%0Alines")
        #expect(GitHubReport.property("a,b: c%\n") == "a%2Cb%3A c%25%0A")
        var report = ConfigJournalAndReportTests.report([(.survived, "App/Odd, name: x.swift")])
        report.results[0].mutant.original = "a\n::error::injected"
        let line = GitHubReport.render(report, workspace: nil)
        #expect(line.split(separator: "\n").count == 1)
        #expect(line.hasPrefix("::warning file=App/Odd%2C name%3A x.swift,line=3,col=14,title="))
        #expect(!line.dropFirst(2).contains("\n"))
    }

    /// GitHub shows ten warnings per step: no more are written, and a notice says how many are missing.
    @Test func theNumberOfAnnotationsIsLimited() {
        let report = ConfigJournalAndReportTests.report(Array(repeating: (MutantStatus.survived, "App/Cart.swift"), count: 14))
        let lines = GitHubReport.render(report, workspace: nil).split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix("::warning ") }.count == GitHubReport.maxAnnotations)
        #expect(lines.last == "::notice title=\(ToolInfo.name)::4 more undetected mutants are not shown as annotations (GitHub shows 10 per step). The Markdown and JSON reports list all 14.")
        #expect(GitHubReport.render(ConfigJournalAndReportTests.report([(.killed, "A.swift")]), workspace: nil).isEmpty)
        // Exactly as many as GitHub shows: all of them, and no notice
        let ten = ConfigJournalAndReportTests.report(Array(repeating: (MutantStatus.survived, "App/Cart.swift"), count: GitHubReport.maxAnnotations))
        let all = GitHubReport.render(ten, workspace: nil).split(separator: "\n")
        #expect(all.count == GitHubReport.maxAnnotations)
        #expect(all.allSatisfy { $0.hasPrefix("::warning ") })
    }

    @Test func aSurvivorThatWasNotRunAgainstAllTestsSaysSoInItsAnnotation() {
        var report = ConfigJournalAndReportTests.report([(.survived, "App/Cart.swift")])
        report.results[0].narrowedOnly = true
        #expect(GitHubReport.render(report, workspace: nil).contains("no test that reaches this code fails with this change (not run against all tests: --no-recheck-survivors)"))
    }

    /// The marks of a survivor that was not run against all tests appear only for such a survivor.
    @Test func aSurvivorOfAllTestsCarriesNoMark() throws {
        var report = ConfigJournalAndReportTests.report([(.survived, "App/Cart.swift")])
        report.testSelection = RunReport.TestSelection(mode: "reach", narrowedMutants: 0, unnarrowedMutants: 1, recheckSurvivors: true, survivedNarrowedOnly: 0,
                                                       fallback: false, onlyTesting: [], matches: [])
        #expect(!TextReport.render(report).contains("not run against all tests"))
        #expect(!String(decoding: try JSONEncoder().encode(StrykerReport(report: report)), as: UTF8.self).contains("not run against all tests"))
        #expect(!GitHubReport.render(report, workspace: nil).contains("not run against all tests"))
    }

    // MARK: Test hosts started by the tool

    /// When a host that the tool started ends because XCTest refuses activities, the warning names that cause.
    @Test func theCauseOfAHostThatRefusesActivitiesIsNamed() {
        let output = "Test Case '-[AppTests.FlowTests testSteps]' started.\nXCTest/XCTContext_SwiftExtensions.swift:34: Fatal error: XCTContext.runActivity(named:block:) failed because activities are disallowed in the current configuration.\n"
        #expect(SharedProcess.knownCause(inHostOutput: output)?.contains("XCTContext.runActivity") == true)
        #expect(SharedProcess.knownCause(inHostOutput: "Test Case '-[AppTests.FlowTests testSteps]' started.\n") == nil)
        // The driver sets up what XCTest asks for, through names that are not public: they are looked up, not linked
        #expect(SharedProcessDriverSource.source.contains("NSClassFromString(\"XCTestConfiguration\")"))
        #expect(SharedProcessDriverSource.source.contains("NOTE activities:"))
    }

    // MARK: Limits inside one run under xcodebuild

    /// A host that does not get to its first test is stopped after a multiple of what the baseline needed to get
    /// there, not after the limit of a whole run; once the tests have started, the allowance for starting is not
    /// added to that of the tests.
    @Test func aRunIsLimitedUntilTheTestsStartAndFromThere() {
        // Baseline: 45 s in all, 20 s until the first test, the suite of the mutant takes 0.5 s
        let policy = TimeoutPolicy.make(baselineSeconds: 45, suiteSeconds: ["T/A": 0.5, "T/B": 19.5], factor: 3, constant: 30, startupSeconds: 20)
        #expect(policy.timeout(for: nil) == 165)
        #expect(policy.watch(for: nil) == LogWatch(startupLimit: 90, afterStart: 105, stopAtCrash: true))
        // Narrowed: (25 + 0.5) × 3 + 30 = 106.5 for the whole run; 46.5 s once the tests have started
        #expect(policy.timeout(for: ["T/A"]) == 106.5)
        #expect(policy.watch(for: ["T/A"]) == LogWatch(startupLimit: 90, afterStart: 46.5, stopAtCrash: true))
        // One test may take three times the slowest test of the baseline plus the constant, and not more than the rest
        let timed = TimeoutPolicy.make(baselineSeconds: 45, suiteSeconds: ["T/A": 0.5, "T/B": 19.5], factor: 3, constant: 30, startupSeconds: 20, longestTestSeconds: 2)
        // … where that is at most half of what the run has after its start (a run that this limit stops is repeated
        // once, and two waits must not be longer than the one there would be without the limit)
        #expect(timed.watch(for: nil)?.stallLimit == 36)
        #expect(timed.watch(for: ["T/A"])?.stallLimit == nil)
        let slow = TimeoutPolicy.make(baselineSeconds: 45, suiteSeconds: ["T/A": 0.5, "T/B": 19.5], factor: 3, constant: 30, startupSeconds: 20, longestTestSeconds: 15)
        #expect(slow.watch(for: nil)?.stallLimit == nil)
        #expect(TimeoutPolicy.longestTest(inLog: """
        Test Case '-[AppTests.A testOne]' passed (0.253 seconds).
        \u{2714} Test two() passed after 1.5 seconds.
        \u{2714} Test run with 2 tests passed after 9.0 seconds.
        Test Case '-[AppTests.A testThree]' failed (7.000 seconds).
        """) == 1.5)
        #expect(TimeoutPolicy.longestTest(inLog: "nothing") == nil)
        // A baseline that does not show when tests start: the limit of the whole run and the stop at the first
        // crash (which needs nothing from the baseline), and the run says that the other limits are not in use
        let blind = TimeoutPolicy.make(baselineSeconds: 45, suiteSeconds: nil, factor: 3, constant: 30)
        #expect(blind.watch(for: nil) == LogWatch(stopAtCrash: true))
        #expect(blind.limitsNotInUse?.contains("not in use") == true)
        #expect(TimeoutPolicy.make(baselineSeconds: 45, suiteSeconds: nil, factor: 3, constant: 30, startupSeconds: 45).watch(for: nil) == LogWatch(stopAtCrash: true))
        #expect(policy.limitsNotInUse == nil)
    }

    /// With `--select-tests reach` the test process of the baseline writes the
    /// lines of its tests into the trace file, not into the log of xcodebuild: no limit inside a run was in use on
    /// the app. The trace file is watched too; if neither shows the tests, the times come from the result bundle;
    /// and a crash is stopped at without any of them.
    @Test func theLimitsDoNotDependOnTheBaselineLogShowingItsTests() throws {
        // From the result bundle: 45 s of baseline, 20 s of them in tests (the longest suite 19.5 s)
        let fromResults = TimeoutPolicy.make(baselineSeconds: 45, suiteSeconds: ["T/A": 0.5, "T/B": 19.5], factor: 3, constant: 30)
        #expect(fromResults.startupSeconds == 25)
        #expect(fromResults.longestTestSeconds == 19.5)
        #expect(fromResults.limitsNotInUse == nil)
        #expect(fromResults.watch(for: nil)?.startupLimit == 105)

        try withTemporaryDirectory { directory in
            let log = directory.appendingPathComponent("out.log").path
            let trace = directory.appendingPathComponent("baseline.trace").path
            // The lines of the tests go to another file, as they do in the baseline
            let script = "echo launching; sleep 1; echo \"Test Case '-[AppTests.FormTests testSave]' started.\" >> '\(trace)'; sleep 2; echo \"Test Case '-[AppTests.FormTests testSave]' passed (2.000 seconds).\" >> '\(trace)'; echo \"Test Case '-[AppTests.FormTests testLoad]' started.\" >> '\(trace)'; sleep 1"
            let unseen = try Subprocess.run(["/bin/sh", "-c", script], logPath: log, timeout: 60, stop: .immediate, watch: LogWatch(stallLimit: .infinity))
            #expect(unseen.firstMarkerAfter == nil)
            try? FileManager.default.removeItem(atPath: trace)
            let seen = try Subprocess.run(["/bin/sh", "-c", script], logPath: log, timeout: 60, stop: .immediate,
                                          watch: LogWatch(stallLimit: .infinity, alsoWatch: [trace]))
            #expect((seen.firstMarkerAfter ?? 0) >= 0.9)
            #expect((seen.firstMarkerAfter ?? 99) < 3)
            #expect((seen.longestQuiet ?? 0) >= 1.5)
            #expect(TimeoutPolicy.longestTest(inLog: try String(contentsOfFile: trace, encoding: .utf8)) == 2)

            // No time from the baseline at all: the first restart still stops the run
            let crash = "echo \"Test Case '-[AppTests.FormTests testSave]' started.\"; sleep 1; echo \"Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.\"; sleep 30"
            let crashed = try Subprocess.run(["/bin/sh", "-c", crash], logPath: log, timeout: 60, stop: .immediate,
                                             watch: TimeoutPolicy.make(baselineSeconds: 45, suiteSeconds: nil, factor: 3, constant: 30).watch(for: nil))
            #expect(crashed.watchLimit == "crash")
            #expect(crashed.crashedIn == "FormTests/testSave()")
            #expect(crashed.duration < 10)
        }
    }

    /// A result bundle lists the host that ended unexpectedly as a failure of
    /// its own ("<host> (<pid>) encountered an error"): it was named among the tests that detected the mutant. And
    /// after a crash, where xcodebuild starts the host again, a test of a later suite that then failed was named
    /// as the test of the Crash.
    @Test func aDetectionNamesOnlyTestsAndACrashOnlyTheTestsThatCrashed() {
        let host = TestSummary.Failure(test: "Host (4711) encountered an error", message: "Crash: Host (4711) at Form.save()")
        let crashed = TestSummary.Failure(test: "FormTests/testSave()", message: "Crash: Host (4711) at Form.save()")
        let later = TestSummary.Failure(test: "ZListTests/testCount()", message: "XCTAssertEqual failed: (\"0\") is not equal to (\"2\")")
        #expect(!host.namesATest)
        #expect(crashed.namesATest && later.namesATest)
        #expect(TestSummary.Failure(test: "topLevelTest()", message: "x").namesATest)

        func judge(_ failures: [TestSummary.Failure]) -> Judgement.Result {
            let summary = TestSummary(result: "Failed", totalTestCount: 5, passedTests: 5 - failures.count, failedTests: failures.count, skippedTests: 0,
                                      expectedFailures: 0, failures: failures)
            return Judgement.classify(exitStatus: 65, timedOut: false, summary: summary, activated: true, timeout: 60, runnerErrorPattern: nil, baseline: nil)
        }
        // The later suite's assertion comes first in the bundle: the Crash still names the test that crashed
        let both = judge([later, host, crashed])
        #expect(both.status == .crash)
        #expect(both.killedBy == ["FormTests/testSave()"])
        #expect(both.detail?.hasPrefix("FormTests/testSave(): Crash") == true)
        // Only the host's entry: a Crash that names no test
        let hostOnly = judge([host, later])
        #expect(hostOnly.status == .crash)
        #expect(hostOnly.killedBy.isEmpty)
        #expect(hostOnly.detail?.contains("encountered an error") == true)
        // Without a crash every failing test is named, as before
        let plain = judge([later])
        #expect(plain.status == .killed)
        #expect(plain.killedBy == ["ZListTests/testCount()"])
    }

    /// A Crash that was stopped at the first crash named the Swift Testing test
    /// by what the log holds, its display name; that is not an identifier and is said in the detail only.
    @Test func aCrashStoppedInASwiftTestingTestDoesNotListItsDisplayName() {
        let log = "\u{25C7} Test \"saves the form\" started.\nRestarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.\n"
        #expect(LogWatch.runningTests(in: log) == ["\"saves the form\""])
        var observation = MutantObservation(key: "k", id: 0, attempt: 1, exitStatus: 65, timedOut: true, summary: nil, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 5, timeoutSeconds: 60)
        observation.crashedIn = "\"saves the form\""
        let named = Judgement.classify(observation, baseline: nil)
        #expect(named.status == .crash)
        #expect(named.killedBy.isEmpty)
        #expect(named.detail?.contains("in the Swift Testing test \"saves the form\"") == true)
        observation.crashedIn = "save()"
        #expect(Judgement.classify(observation, baseline: nil).killedBy.isEmpty)
        observation.crashedIn = "FormTests/testSave()"
        let xctest = Judgement.classify(observation, baseline: nil)
        #expect(xctest.killedBy == ["FormTests/testSave()"])
        #expect(xctest.detail?.contains("in FormTests/testSave();") == true)
    }

    /// A simulator on which a system dialog stopped the tests was given up after seven
    /// mutants; the 41 that were left were RunnerError, the score read 100 %, the exit code was 0 and the Markdown
    /// report did not show them. Every report says beside its score that mutants could not be run.
    @Test func aReportWithMutantsThatCouldNotBeRunDoesNotLookComplete() throws {
        let report = ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift"), (.runnerError, "App/Cart.swift"), (.runnerError, "App/Cart.swift")])
        #expect(report.reachedScore == 1)
        let note = try #require(report.notRunNote)
        #expect(note.hasPrefix("2 of 3 mutants could not be run and are not in the score (RunnerError 2)"))
        #expect(TextReport.render(report).contains("  INCOMPLETE: 2 of 3 mutants could not be run"))
        let markdown = MarkdownReport.render(report)
        #expect(markdown.contains("> **Incomplete**: 2 of 3 mutants could not be run"))
        #expect(markdown.contains("### Not evaluated"))
        #expect(markdown.components(separatedBy: "| RunnerError |").count == 3)
        #expect(try HTMLReport.render(report).contains("INCOMPLETE: 2 of 3 mutants could not be run"))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONReport(report: report))) as? [String: Any])
        #expect(json["unevaluatedCount"] as? Int == 2)
        #expect(AgentReport(report: report).unevaluatedCount == 2)
        #expect(ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift")]).notRunNote == nil)

        let message = MutantExecutor.droppedMessage(who: "The destination", destination: "platform=iOS Simulator,id=X", attempts: 3,
                                                    notPassed: ["run 1: no result after 95 s (the tests did not finish, or the test process ended); running when it ended: ScanTests/testOpen()"],
                                                    logs: ["/work/logs/between-w0-7.log"], screenshot: "/work/logs/worker-0-dropped-screen.png", isSimulator: true)
        #expect(message.contains("running when it ended: ScanTests/testOpen()"))
        #expect(message.contains("Logs: /work/logs/between-w0-7.log."))
        #expect(message.contains("The simulator's screen at that moment: /work/logs/worker-0-dropped-screen.png."))
        #expect(message.contains("simctl privacy"))
    }

    /// The crash report of a host is written seconds after the process has ended;
    /// what is kept for a process that failed names the exception and the first frames of the thread that crashed.
    @Test func aCrashReportIsDescribedByItsExceptionAndFirstFrames() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("Host-2026-01-01-000000.ips")
            let body: [String: Any] = ["exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"], "faultingThread": 1,
                                       "usedImages": [["name": "CoreData"], ["name": "HostTests"]],
                                       "threads": [["frames": [["symbol": "mach_msg", "imageIndex": 0]]],
                                                   ["frames": [["symbol": "objc_release", "imageIndex": 0], ["symbol": "StoreTests.tearDown()", "imageIndex": 1]]]]]
            let text = "{\"app_name\":\"Host\"}\n" + String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            try text.write(to: file, atomically: true, encoding: .utf8)
            #expect(SharedProcess.describeCrashReport(atPath: file.path) == "EXC_BAD_ACCESS (SIGSEGV); thread that crashed: objc_release (CoreData) < StoreTests.tearDown() (HostTests)")
            #expect(SharedProcess.describeCrashReport(atPath: directory.appendingPathComponent("none.ips").path) == nil)
        }
    }

    /// Once, on a busy Mac, a mutant that calls `fatalError` was a Timeout: xcodebuild
    /// had not written that it starts the host again when the limit after the first test stopped the run. A crash
    /// report of the host, on this simulator, written during the run makes such a run a crash.
    @Test func aRunStoppedByALimitIsACrashWhenTheHostLeftACrashReport() throws {
        try withTemporaryDirectory { directory in
            func report(_ name: String, bundle: String, device: String) throws {
                let body = "{\"procPath\":\"\\/Users\\/USER\\/Library\\/Developer\\/CoreSimulator\\/Devices\\/\(device)\\/data\\/App.app\\/App\",\"exception\":{\"type\":\"EXC_BREAKPOINT\",\"signal\":\"SIGTRAP\"}}"
                try ("{\"app_name\":\"App\",\"bundleID\":\"\(bundle)\"}\n" + body).write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try report("App-1.ips", bundle: "dev.example.App", device: "AAAA-1111")
            try report("App-2.ips", bundle: "dev.example.App", device: "BBBB-2222")
            try report("Other-1.ips", bundle: "dev.example.Other", device: "AAAA-1111")
            let start = Date().addingTimeInterval(-5)
            let found = SharedProcess.crashReports(bundleIdentifiers: ["dev.example.App"], since: start, device: "aaaa-1111", in: directory)
            #expect(found.map { URL(fileURLWithPath: $0).lastPathComponent } == ["App-1.ips"])
            #expect(SharedProcess.crashReports(bundleIdentifiers: ["dev.example.App"], since: start, in: directory).count == 2)
            #expect(SharedProcess.crashReports(bundleIdentifiers: ["dev.example.App"], since: Date().addingTimeInterval(60), in: directory).isEmpty)
            #expect(SharedProcess.crashReports(bundleIdentifiers: [], since: start, in: directory).isEmpty)
        }
        var observation = MutantObservation(key: "k", id: 0, attempt: 1, exitStatus: -1, timedOut: false, summary: nil, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 36, timeoutSeconds: 31)
        observation.crashedIn = "FormTests/testSave()"
        observation.crashEvidence = "a crash report of the host was written during the run: /reports/App-1.ips (EXC_BREAKPOINT (SIGTRAP))"
        let judged = Judgement.classify(observation, baseline: nil)
        #expect(judged.status == .crash)
        #expect(judged.killedBy == ["FormTests/testSave()"])
        #expect(judged.detail == "Crash: the test host ended unexpectedly in FormTests/testSave(): a crash report of the host was written during the run: /reports/App-1.ips (EXC_BREAKPOINT (SIGTRAP))")
    }

    /// `simctl launch` does not say how an app ended; the simulator's log does.
    @Test func theEndOfAProcessIsReadFromTheSimulatorsLog() {
        let log = """
        2026-11-24 01:02:03.456 Df SpringBoard[501:1a2b] [com.apple.runningboard:process] [app<dev.example.App(AAAA)>:4711] termination reported by launchd (2, 11, 11)
        2026-11-24 01:02:03.460 Df runningboardd[502:1a2c] [com.apple.runningboard:process] [app<dev.example.App(AAAA)>:4711] exited with context: <RBSProcessExitContext| specific, status:<RBSProcessExitStatus| domain:signal(2) code:SIGSEGV(11)>>
        2026-11-24 01:02:04.000 Df runningboardd[502:1a2c] [app<dev.example.Other(AAAA)>:4712] exited with context: <RBSProcessExitContext| voluntary>
        """
        let lines = SharedProcess.exitLines(inLog: log, processID: 4711)
        #expect(lines.count == 2)
        #expect(SharedProcess.exitReason(in: lines) == "domain:signal(2) code:SIGSEGV(11)")
        #expect(SharedProcess.exitLines(inLog: log, processID: 1).isEmpty)
        #expect(SharedProcess.exitReason(in: []) == nil)
    }

    /// What an agent that followed the guide asked for: the result of every key in the report for agents (a run
    /// with --only gave counts only), the candidates that were left out with the reason, the scope as it is, and no
    /// line about files that were not mutated when those are only tests.
    @Test func theReportForAgentsNamesEveryMutantByKey() throws {
        var report = ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift"), (.survived, "App/Cart.swift")])
        report.scope = "only"
        report.ignored = [IgnoredMutant(operator: .boundary, file: "App/Cart.swift", enclosingDecl: "f()", point: ByteRange(start: 0, end: 1),
                                        start: SourcePosition(line: 2, column: 5), original: "<", replacement: "<=", reason: .pattern)]
        let agent = AgentReport(report: report)
        #expect(agent.version == 5)
        #expect(agent.scope == "only")
        #expect(agent.results.map(\.status) == ["Killed", "Survived"])
        #expect(agent.results.map(\.key) == report.results.map(\.mutant.key))
        #expect(agent.ignoredCount == 1)
        #expect(agent.ignored.first?.reason == "pattern" && agent.ignored.first?.line == 2)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any])
        #expect(json["selection"] == nil)
        #expect((json["results"] as? [[String: Any]])?.first?["key"] as? String == report.results[0].mutant.key)

        report.excluded.counts = ["test-code": 2]
        #expect(!TextReport.render(report).contains("files not mutated"))
        report.excluded.counts = ["test-code": 2, "generated": 1]
        #expect(TextReport.render(report).contains("  files not mutated: generated 1, test-code 2"))
    }

    /// The two limits, on real processes: one that never writes the line of a test that starts, one that writes it
    /// and goes on for too long, and one that ends in time.
    @Test func theLimitsStopAProcessThatDoesNotStartOrDoesNotEnd() throws {
        try withTemporaryDirectory { directory in
            let log = directory.appendingPathComponent("out.log").path
            let silent = try Subprocess.run(["/bin/sh", "-c", "echo launching; sleep 30"], logPath: log, timeout: 60, stop: .immediate,
                                            watch: LogWatch(startupLimit: 1, afterStart: 60))
            #expect(silent.timedOut)
            #expect(silent.watchLimit == "startup")
            #expect(silent.firstMarkerAfter == nil)
            #expect(silent.duration < 10)

            let endless = try Subprocess.run(["/bin/sh", "-c", "echo \"Test Suite 'All tests' started\"; sleep 30"], logPath: log, timeout: 60, stop: .immediate,
                                             watch: LogWatch(startupLimit: 20, afterStart: 1))
            #expect(endless.timedOut)
            #expect(endless.watchLimit == "afterStart")
            #expect((endless.firstMarkerAfter ?? 99) < 5)
            #expect(endless.duration < 10)

            let fine = try Subprocess.run(["/bin/sh", "-c", "sleep 1; echo \"\u{25C7} Test run started.\"; sleep 1"], logPath: log, timeout: 60, stop: .immediate,
                                          watch: LogWatch(startupLimit: 20, afterStart: 20))
            #expect(!fine.timedOut)
            #expect(fine.watchLimit == nil)
            #expect((fine.firstMarkerAfter ?? 0) >= 0.9)
        }
    }

    /// Under xcodebuild a host that crashes is started again for every test that
    /// is left, and a test that waits forever was waited for as long as all tests may take. The run is stopped at
    /// the first restart (a Crash, with the test that had started last), and when one test does not end within the
    /// time that a single test may take (repeated once before it is a Timeout).
    @Test func aRunIsStoppedAtTheFirstCrashAndWhenOneTestDoesNotEnd() throws {
        try withTemporaryDirectory { directory in
            let log = directory.appendingPathComponent("out.log").path
            let crash = "echo \"Test Case '-[AppTests.FormTests testSave]' started.\"; sleep 1; echo \"Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.\"; sleep 30"
            let crashed = try Subprocess.run(["/bin/sh", "-c", crash], logPath: log, timeout: 60, stop: .immediate,
                                             watch: LogWatch(startupLimit: 20, afterStart: 40, stallLimit: 30, stopAtCrash: true))
            #expect(crashed.watchLimit == "crash")
            #expect(crashed.crashedIn == "FormTests/testSave()")
            #expect(crashed.runningAtStop == ["FormTests/testSave()"])
            #expect(crashed.duration < 10)
            // Without the option the restart is waited through
            let waited = try Subprocess.run(["/bin/sh", "-c", crash.replacingOccurrences(of: "sleep 30", with: "sleep 1")], logPath: log, timeout: 60, stop: .immediate,
                                            watch: LogWatch(startupLimit: 20, afterStart: 40))
            #expect(waited.watchLimit == nil)

            let stuck = try Subprocess.run(["/bin/sh", "-c", "echo \"\u{25C7} Test load() started.\"; sleep 1; echo \"\u{2714} Test load() passed after 1 seconds.\"; echo \"\u{25C7} Test wait() started.\"; sleep 30"],
                                           logPath: log, timeout: 60, stop: .immediate, watch: LogWatch(startupLimit: 20, afterStart: 40, stallLimit: 2))
            #expect(stuck.watchLimit == "stall")
            #expect(stuck.crashedIn == "wait()")
            #expect(stuck.duration > 2.5 && stuck.duration < 10)
            // Tests that go on starting and ending are not stuck, however long the run is
            let busy = try Subprocess.run(["/bin/sh", "-c", "for i in 1 2 3 4; do echo \"Test Case '-[T t$i]' started.\"; sleep 1; done"], logPath: log, timeout: 60, stop: .immediate,
                                          watch: LogWatch(startupLimit: 20, afterStart: 40, stallLimit: 2.5))
            #expect(busy.watchLimit == nil)
            #expect((busy.longestQuiet ?? 0) > 0.5 && (busy.longestQuiet ?? 9) < 2.5)
        }
        // The verdict of a run that was stopped at a crash
        var observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: 137, timedOut: false, summary: nil, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 12, timeoutSeconds: 71)
        observation.crashedIn = "FormTests/testSave()"
        let judged = Judgement.classify(observation, baseline: BaselineEvidence(testCount: 9, passedTests: 9, skippedTests: 0))
        #expect(judged.status == .crash)
        #expect(judged.killedBy == ["FormTests/testSave()"])
        observation.activated = false
        #expect(Judgement.classify(observation, baseline: nil).status == .runnerError)
        // A test that fails an assertion and then ends the host is Killed, as its result bundle would say
        observation.activated = true
        observation.failedBeforeCrash = true
        #expect(Judgement.classify(observation, baseline: nil).status == .killed)

        // The test that is named is one that had started and not ended where
        // the log stops, and only if it is the only one: Swift Testing runs tests side by side, and by the time the
        // log is read, tests of the restarted host have started
        let log = """
        Test Suite 'All tests' started at 2026-11-23
        Test Case '-[AppTests.A testOne]' started.
        /src/A.swift:3: error: -[AppTests.A testOne] : XCTAssertEqual failed: ("1") is not equal to ("2")
        Test Case '-[AppTests.A testOne]' failed (0.1 seconds).
        Test Case '-[AppTests.A testTwo]' started.
        """
        #expect(LogWatch.runningTests(in: log) == ["A/testTwo()"])
        #expect(!LogWatch.failed("A/testTwo()", in: log))
        #expect(LogWatch.failed("A/testOne()", in: log))
        #expect(LogWatch.failed("A/testTwo()", in: log + "\n/src/A.swift:9: error: -[AppTests.A testTwo] : XCTAssertEqual failed: (\"-1\") is not equal to (\"2\")\n"))
        #expect(LogWatch.runningTests(in: log + "\nTest Case '-[AppTests.A testTwo]' passed (0.1 seconds).\n").isEmpty)
        let sideBySide = """
        \u{25C7} Test run started.
        \u{25C7} Test load() started.
        \u{25C7} Test save() started.
        \u{2718} Test save() recorded an issue at A.swift:3:5: Expectation failed
        \u{2714} Test load() passed after 0.001 seconds.
        \u{25C7} Test wait() started.
        """
        #expect(LogWatch.runningTests(in: sideBySide) == ["save()", "wait()"])
        #expect(LogWatch.failed("save()", in: sideBySide))
        #expect(!LogWatch.failed("wait()", in: sideBySide))
    }

    /// [second round, 4] The limit for one test ends where the tests end: what xcodebuild does after the last test
    /// (collecting results, the host going down) is not a test that is stuck, however long it takes.
    @Test func theLimitForOneTestDoesNotApplyAfterTheTestsHaveEnded() throws {
        try withTemporaryDirectory { directory in
            let log = directory.appendingPathComponent("out.log").path
            let script = "echo \"Test Case '-[T t]' started.\"; echo \"Test Case '-[T t]' passed (0.001 seconds).\"; echo \"Test Suite 'All tests' passed at 2026\"; sleep 4"
            let slowEnd = try Subprocess.run(["/bin/sh", "-c", script], logPath: log, timeout: 60, stop: .immediate, watch: LogWatch(startupLimit: 20, afterStart: 40, stallLimit: 1.5))
            #expect(!slowEnd.timedOut)
            #expect(slowEnd.watchLimit == nil)
            // … and the time after the end is not what the baseline takes for "the longest time without a line of a test"
            #expect((slowEnd.longestQuiet ?? 9) < 1.5)
            // Swift Testing's run after XCTest's suites: tests are running again, and one that is stuck is found
            let second = script.replacingOccurrences(of: "sleep 4", with: "echo \"\u{25C7} Test wait() started.\"; sleep 30")
            let stuck = try Subprocess.run(["/bin/sh", "-c", second], logPath: log, timeout: 60, stop: .immediate, watch: LogWatch(startupLimit: 20, afterStart: 40, stallLimit: 1.5))
            #expect(stuck.watchLimit == "stall")
            #expect(stuck.runningAtStop == ["wait()"])
        }
        // [second round, 5] A Timeout says which limit stopped the run
        var observation = MutantObservation(key: "k", id: 1, attempt: 2, exitStatus: 137, timedOut: true, summary: nil, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 36, timeoutSeconds: 36)
        observation.limitNote = "one test did not end: no test or suite started or ended for 31 s"
        #expect(Judgement.classify(observation, baseline: nil).detail == observation.limitNote)
        observation.limitNote = nil
        #expect(Judgement.classify(observation, baseline: nil).detail == "exceeded 36s")
    }

    /// [second round, 3] Suites that are all the suites there are do not make a narrowed selection: nothing is marked
    /// as resting on narrowed tests, and nothing is run again against "the whole selection".
    @Test func aSelectionOfEverySuiteIsNotNarrowed() {
        var reach = TestReach()
        reach.reached = [0, 1]
        reach.suites = [0: ["A", "B"], 1: ["A"]]
        reach.tests = [0: ["A/one()", "B/one()"], 1: ["A/one()", "A/two()"]]
        let selector = ReachSelector(reach: reach, suites: [TestSuiteInfo(bundle: "T", name: "A", identifier: "A", testCount: 2, seconds: 1),
                                                           TestSuiteInfo(bundle: "T", name: "B", identifier: "B", testCount: 2, seconds: 1)], totalTestCount: 4)
        #expect(selector.selection(for: 0) == nil)
        #expect(selector.selection(for: 1)?.onlyTesting == ["T/A"])
    }

    /// The edges of the watch: a first test that starts just before the limit for starting is still seen (the log is
    /// not read at every turn), and so is one that starts in a process that ends at once.
    @Test func aStartIsSeenAtTheLimitAndAfterTheEnd() throws {
        try withTemporaryDirectory { directory in
            let log = directory.appendingPathComponent("out.log").path
            // The limit comes before the first regular look at the log
            let late = try Subprocess.run(["/bin/sh", "-c", "echo \"Test Case '-[T t]' started.\"; sleep 2"], logPath: log, timeout: 60, stop: .immediate,
                                          watch: LogWatch(startupLimit: 0.1, afterStart: 30))
            #expect(!late.timedOut)
            #expect((late.firstMarkerAfter ?? 99) < 1.5)

            let quick = try Subprocess.run(["/bin/sh", "-c", "echo \"Test Suite 'All tests' started\""], logPath: log, timeout: 60, stop: .immediate, watch: LogWatch())
            #expect(!quick.timedOut)
            #expect(quick.firstMarkerAfter != nil)
            let nothing = try Subprocess.run(["/bin/sh", "-c", "echo launching"], logPath: log, timeout: 60, stop: .immediate, watch: LogWatch())
            #expect(nothing.firstMarkerAfter == nil)

            // A log that is not there is a log without a marker
            #expect(!LogWatch.Reader(path: directory.appendingPathComponent("missing.log").path, markers: LogWatch.testStartMarkers).sawMarker())
        }
    }

    /// The report names the limit that stopped a run.
    @Test func theLimitThatStoppedARunIsTheOneReported() {
        #expect(RunSession.exceededLimit(ProcessOutcome(status: 137, timedOut: true, duration: 165.4), timeout: 165) == 165)
        #expect(RunSession.exceededLimit(ProcessOutcome(status: 137, timedOut: true, duration: 90.7, watchLimit: "startup"), timeout: 165) == 90)
    }

    /// A mutant that is run alone while shared processes are paused is narrowed only when every unit has shown its
    /// switch to be evaluated evenly.
    @Test func whatEarlierSharedProcessesShowedDecidesWhetherARunAloneIsNarrowed() {
        var first = SharedProcess.Classes()
        first.even = [1, 2, 3]
        first.uneven = [4]
        first.launch = [5]
        var second = SharedProcess.Classes()
        second.even = [4, 5]
        second.uneven = [3]
        #expect(MutantExecutor.isKnownEven(1, classes: [0: first], units: 1))
        // Not evaluated in any unit; evaluated unevenly; evaluated before the tests
        #expect(!MutantExecutor.isKnownEven(9, classes: [0: first], units: 1))
        #expect(!MutantExecutor.isKnownEven(4, classes: [0: first], units: 1))
        #expect(!MutantExecutor.isKnownEven(5, classes: [0: first], units: 1))
        // A unit that has not been looked at yet may still say otherwise
        #expect(!MutantExecutor.isKnownEven(1, classes: [0: first], units: 2))
        #expect(MutantExecutor.isKnownEven(1, classes: [0: first, 1: second], units: 2))
        // Even in one unit, uneven or at launch in another
        #expect(!MutantExecutor.isKnownEven(3, classes: [0: first, 1: second], units: 2))
        #expect(!MutantExecutor.isKnownEven(4, classes: [0: first, 1: second], units: 2))
        #expect(!MutantExecutor.isKnownEven(5, classes: [0: first, 1: second], units: 2))
    }

    /// A host that the tool starts gets the language and region of its test-plan configuration.
    /// Xcode 27 writes them into the `.xctestrun` file as arguments, which are handed on as they are; where only
    /// `TestLanguage` / `TestRegion` are there, the arguments are made from them.
    @Test func aHostStartedByTheToolGetsTheLanguageOfItsConfiguration() {
        let written = ["-AppleLanguages", "(ja)", "-AppleTextDirection", "NO", "-AppleLocale", "ja_JP"]
        #expect(SharedProcess.hostArguments(written, language: "ja", region: "JP") == written)
        #expect(SharedProcess.hostArguments(["-flag"], language: "ja", region: "JP") == ["-flag", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"])
        #expect(SharedProcess.hostArguments([], language: nil, region: nil) == [])
        #expect(SharedProcess.hostArguments([], language: "en", region: nil) == ["-AppleLanguages", "(en)"])
    }

    // MARK: --max-mutants

    /// The sample depends on the keys alone: not on their order, and a new mutant moves at most one mutant out.
    @Test func theSampleIsDecidedByTheKeys() {
        let keys = (0..<200).map { "Sources/A.swift::f(\($0))::boundary::0" }
        let sample = MutantSample.choose(keys, limit: 20)
        #expect(sample.count == 20)
        #expect(sample == MutantSample.choose(keys.reversed(), limit: 20))
        #expect(sample == MutantSample.choose(keys.shuffled(), limit: 20))
        let grown = MutantSample.choose(keys + ["Sources/B.swift::g()::negation::0"], limit: 20)
        #expect(sample.subtracting(grown).count <= 1)
        #expect(grown.subtracting(sample).isSubset(of: ["Sources/B.swift::g()::negation::0"]))
        // A sample of a larger limit holds the sample of a smaller one
        #expect(sample.isSuperset(of: MutantSample.choose(keys, limit: 5)))
        #expect(MutantSample.choose(keys, limit: 500) == Set(keys))
        // Not the first twenty in file order
        #expect(sample != Set(keys.prefix(20)))
    }

    @Test func aSampleIsNamedInTheReports() throws {
        var report = ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift"), (.survived, "App/Cart.swift")])
        report.sampling = RunReport.Sampling(limit: 2, candidates: 40)
        #expect(TextReport.render(report).contains("sample: 2 of 40 mutants, chosen by their stable keys (--max-mutants); the others were not examined"))
        #expect(MarkdownReport.render(report).contains("> **Sample**: 2 of 40 mutants were examined"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONReport(report: report))) as? [String: Any]
        #expect((json?["sampling"] as? [String: Any])?["limit"] as? Int == 2)
        #expect((json?["sampling"] as? [String: Any])?["candidates"] as? Int == 40)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONReport(report: ConfigJournalAndReportTests.report([(.killed, "A.swift")])))) as? [String: Any]
        #expect(plain?["sampling"] == nil)
        #expect(plain?["timeLimitReached"] == nil)
    }

    /// A report of a sample as `--baseline-report`: the mutants that the sample left out are not
    /// known to it, and are not new gaps. A report that cannot say what it left out is refused, and so is a report
    /// of changed lines or of named mutants. A mutant in a file that the earlier run did not examine is not new.
    @Test func aBaselineKnowsWhatItDidNotExamine() throws {
        func baseline(_ extra: [String: Any]) throws -> Data {
            var json: [String: Any] = ["keyVersion": MutantKeyScheme.version, "scope": "files", "files": ["App/Cart.swift"], "results": [
                ["status": "Killed", "mutant": ["key": "App/Cart.swift::Cart.total()::boundary::0"]],
            ]]
            for (key, value) in extra { json[key] = value }
            return try JSONSerialization.data(withJSONObject: json)
        }
        let sampled = try Gate.earlierReport(baseline(["sampling": ["limit": 1, "candidates": 2, "omittedKeys": ["App/Cart.swift::Cart.total()::boundary::1"]]]))
        #expect(sampled.unknown == ["App/Cart.swift::Cart.total()::boundary::1"])
        #expect(sampled.files == ["App/Cart.swift"])

        // Now: mutant 0 killed, mutant 1 survived (left out of the baseline's sample), mutant 2 survived (new code), a
        // survivor in a file that the baseline did not examine
        let report = ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift"), (.survived, "App/Cart.swift"), (.survived, "App/Cart.swift"), (.survived, "App/Other.swift")])
        var gate = Gate(earlierUndetected: sampled.undetected.union(sampled.unknown))
        gate.earlierFiles = sampled.files
        // A file that the baseline does not hold and that is not known to have existed then is new: its gaps count
        // (a new file with untested code must not pass the gate)
        #expect(gate.filesOutsideEarlier(report) == ["App/Other.swift"])
        #expect(gate.evaluate(report).first?.message.contains("2 mutants are not detected") == true)
        #expect(gate.outsideEarlierFiles(report).isEmpty)
        // The file existed when the baseline was made, and that run was limited to other files: not known, not new
        gate.filesLeftOutThen = ["App/Other.swift"]
        let failures = gate.evaluate(report)
        #expect(failures.map(\.exitCode) == [ExitCodes.newSurvivors])
        #expect(failures.first?.message.contains("1 mutants are not detected") == true)
        #expect(failures.first?.message.contains("boundary::2") == true)
        #expect(gate.outsideEarlierFiles(report).map(\.mutant.file) == ["App/Other.swift"])

        // The baseline's commit is not in this clone (a shallow clone): whether the file is new cannot be told. Not a
        // new gap, and not a pass: the gate cannot be confirmed
        var shallow = Gate(earlierUndetected: sampled.undetected.union(sampled.unknown).union(["App/Cart.swift::Cart.total()::boundary::2"]))
        shallow.earlierFiles = sampled.files
        shallow.undeterminedFiles = ["App/Other.swift"]
        shallow.undeterminedReason = "the commit of the earlier report is not in this clone"
        #expect(shallow.evaluate(report).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(shallow.evaluate(report).first?.message.contains("not in this clone") == true)

        #expect(throws: Gate.GateError.self) { try Gate.earlierReport(baseline(["sampling": ["limit": 1, "candidates": 2]])) }
        #expect(throws: Gate.GateError.self) { try Gate.earlierReport(baseline(["scope": "diff"])) }
        #expect(throws: Gate.GateError.self) { try Gate.earlierReport(baseline(["scope": "only"])) }
        #expect(try Gate.earlierReport(baseline(["scope": "all"])).unknown.isEmpty)
        // A report that the time limit cut short lists what it did not run
        #expect(try Gate.earlierReport(baseline(["interrupted": true, "timeLimitReached": true, "pendingKeys": ["k"]])).unknown == ["k"])
    }

    // MARK: --time-limit

    @Test(arguments: [("90", 90.0), ("90s", 90), ("45m", 2700), ("2h", 7200), ("1h30m", 5400), ("1.5h", 5400), ("1m30s", 90)])
    func durationsAreParsed(text: String, seconds: Double) {
        #expect(TimeLimit.parse(text) == seconds)
    }

    @Test(arguments: ["", "0", "0m", "m", "10x", "1h30", "-5", "5 m", "abc"])
    func whatIsNotADurationIsRefused(text: String) {
        #expect(TimeLimit.parse(text) == nil)
    }

    /// A run that the time limit cut short: a gate that the results already fail still fails with its own code; a
    /// gate that they do not fail cannot be confirmed (exit code 7), because mutants were not run.
    @Test func aGateIsNotConfirmedByARunThatTheTimeLimitCutShort() {
        var report = ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift"), (.killed, "App/Cart.swift")])
        report.interrupted = true
        report.timeLimitReached = true
        report.pendingKeys = ["App/Cart.swift::Cart.total()::boundary::7", "App/Cart.swift::Cart.total()::boundary::8"]
        let gate = Gate(failOnSurvived: true)
        #expect(gate.evaluate(report).map(\.exitCode) == [ExitCodes.incomplete])
        #expect(gate.evaluate(report).first?.message.contains("2 mutants were not run before the time limit") == true)
        // Without a gate there is nothing to fail
        #expect(Gate().evaluate(report).isEmpty)

        var failing = ConfigJournalAndReportTests.report([(.killed, "App/Cart.swift"), (.survived, "App/Cart.swift")])
        failing.interrupted = true
        failing.timeLimitReached = true
        failing.pendingKeys = report.pendingKeys
        #expect(gate.evaluate(failing).map(\.exitCode) == [ExitCodes.survived])

        #expect(TextReport.render(report).contains("TIME LIMIT REACHED, 2 not run"))
        #expect(MarkdownReport.render(report).contains("> **Time limit reached**: 2 mutants were not run."))
        #expect(GitHubReport.render(report, workspace: nil) == "::notice title=\(ToolInfo.name)::The time limit was reached: 2 mutants were not run.")
        let json = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONReport(report: report))) as? [String: Any]
        #expect(json?["timeLimitReached"] as? Bool == true)
        #expect(json?["interrupted"] as? Bool == true)
    }
}
