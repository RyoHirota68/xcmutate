import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

/// What a run costs in a project whose whole test run is long.
@Suite("Runs without mutants, shared-process restarts, hangs, estimates")
struct ControlRunTests {
    // MARK: Which tests have passed without mutants

    @Test func theLedgerAsksOnlyForTestsNotShownToPassSinceTheLastRunThatDidNotPass() {
        var ledger = ControlLedger()
        // Right after the baseline: nothing is due, and a run that starts now comes directly after a passing run
        #expect(ledger.missing(for: .all) == nil)
        #expect(ledger.missing(for: .only(["T/A"])) == nil)
        #expect(ledger.isDirectlyAfterControl(of: .only(["T/A"])))

        ledger.runDidNotPass()
        #expect(ledger.missing(for: .all) == .all)
        #expect(ledger.missing(for: .only(["T/A", "T/B"])) == .only(["T/A", "T/B"]))
        #expect(!ledger.isDirectlyAfterControl(of: .only(["T/A"])))

        ledger.controlPassed(.only(["T/A"]))
        #expect(ledger.missing(for: .only(["T/A"])) == nil)
        // B has not passed since: a mutant that runs B needs it, and only it
        #expect(ledger.missing(for: .only(["T/A", "T/B"])) == .only(["T/B"]))
        #expect(ledger.missing(for: .all) == .all)
        #expect(ledger.isDirectlyAfterControl(of: .only(["T/A"])))
        #expect(!ledger.isDirectlyAfterControl(of: .only(["T/A", "T/B"])))

        // A passing run with a mutant takes nothing back, but the next run no longer follows a run without mutants
        ledger.mutantRunPassed()
        #expect(ledger.missing(for: .only(["T/A"])) == nil)
        #expect(!ledger.isDirectlyAfterControl(of: .only(["T/A"])))

        ledger.controlPassed(.only(["T/B"]))
        #expect(ledger.missing(for: .only(["T/A", "T/B"])) == nil)
        // Two suites are not the whole selection
        #expect(ledger.missing(for: .all) == .all)

        ledger.controlPassed(.all)
        #expect(ledger.missing(for: .all) == nil)
        #expect(ledger.isDirectlyAfterControl(of: .only(["T/C"])))

        // Every run that does not pass starts over
        ledger.runDidNotPass()
        #expect(ledger.missing(for: .only(["T/A"])) == .only(["T/A"]))
        #expect(ControlLedger.unknown.missing(for: .all) == .all)
    }

    @Test func aScopeCoversWhatItContains() {
        #expect(ControlScope(selected: nil) == .all)
        #expect(ControlScope(selected: ["T/B", "T/A", "T/B"]) == .only(["T/A", "T/B"]))
        #expect(ControlScope.all.covers(.only(["T/A"])))
        #expect(!ControlScope.only(["T/A"]).covers(.all))
        #expect(ControlScope.only(["T/A", "T/B"]).covers(.only(["T/B"])))
        #expect(!ControlScope.only(["T/A"]).covers(.only(["T/A", "T/B"])))
    }

    // MARK: The order of runs with narrowed tests

    /// A project with two suites of two tests each. Each mutant is reached by the tests of one suite. State that a
    /// run leaves on the destination fails one test of suite B the next time that test runs, which removes it.
    final class Project: MutantRunning, @unchecked Sendable {
        enum Behaviour { case passes, fails, failsAndLeavesStateForB, hangs, failsOnlyWhenEveryTestRuns, startsSlowlyOnce, neverStarts, failsOnlyWhenNarrowed }
        /// How often each mutant was run.
        var runs: [Int: Int] = [:]
        let lock = NSLock()
        var behaviours: [Int: Behaviour] = [:]
        var suites: [Int: String] = [:]
        var leftoverForB = false
        /// What a run leaves for B is removed only by a run in which suite A runs too (A cleans up, B does not).
        var onlyARemovesTheLeftover = false
        var recheck = false
        /// `--confirm-kills full`: the second run of a mutant that its suite detected is not narrowed.
        var fullConfirmation = false
        /// Suite B passes only in a process in which suite A has run before it.
        var bNeedsA = false
        /// How often suite B was run by itself without mutants and failed. After the third time the executor knows
        /// that B needs the others and runs B's mutants against every test (the model is not told the selection).
        var bAloneFailures = 0
        var log: [String] = []
        var journal: URL?

        static let infos = [TestSuiteInfo(bundle: "T", name: "A", identifier: "A", testCount: 2, seconds: 1),
                            TestSuiteInfo(bundle: "T", name: "B", identifier: "B", testCount: 2, seconds: 2)]

        var selector: ReachSelector {
            var reach = TestReach()
            for (id, suite) in suites {
                reach.reached.insert(id)
                reach.suites[id] = [suite]
                reach.tests[id] = ["\(suite)/one()", "\(suite)/two()"]
            }
            return ReachSelector(reach: reach, suites: Self.infos, totalTestCount: 4)
        }

        private func observation(_ mutant: Mutant, attempt: Int, failed: String?, tests: Int) -> MutantObservation {
            let summary = TestSummary(result: failed == nil ? "Passed" : "Failed", totalTestCount: tests, passedTests: failed == nil ? tests : tests - 1,
                                      failedTests: failed == nil ? 0 : 1, skippedTests: 0, expectedFailures: 0,
                                      failures: failed.map { [.init(test: $0, message: "XCTAssertEqual failed")] } ?? [])
            return MutantObservation(key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: failed == nil ? 0 : 65, timedOut: false, summary: summary,
                                     activated: true, runnerErrorPattern: nil, durationSeconds: 0.1, timeoutSeconds: 60)
        }

        func execute(_ mutant: Mutant, worker: Int, attempt: Int) throws -> (MutantObservation, log: String) {
            lock.lock()
            defer { lock.unlock() }
            // The run is narrowed to the mutant's suite; a mutant without one runs all four tests
            var suite = suites[mutant.id]
            runs[mutant.id, default: 0] += 1
            // The second run of a mutant that survived its suite is the recheck: it is not narrowed
            if recheck || fullConfirmation, runs[mutant.id] == 2 { suite = nil }
            if bNeedsA, suite == "B", bAloneFailures >= 3 { suite = nil }
            log.append("m\(mutant.id)" + (suite == nil && suites[mutant.id] != nil ? ":all" : ""))
            var failed: String?
            if bNeedsA, suite == "B" { failed = "B/one()" }
            if leftoverForB, suite == nil || suite == "B" {
                failed = "B/two()"
                if !onlyARemovesTheLeftover || suite == nil { leftoverForB = false }
            }
            switch behaviours[mutant.id] ?? .passes {
            case .passes: break
            case .fails: failed = "\(suite ?? "A")/one()"
            case .failsOnlyWhenEveryTestRuns: if suite == nil { failed = "B/one()" }
            case .failsOnlyWhenNarrowed: if suite != nil { failed = "\(suite ?? "A")/one()" }
            case .failsAndLeavesStateForB:
                failed = "\(suite ?? "A")/one()"
                leftoverForB = true
            case .startsSlowlyOnce, .neverStarts:
                if behaviours[mutant.id] == .neverStarts || runs[mutant.id] == 1 {
                    var stopped = MutantObservation(key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: -1, timedOut: true, summary: nil, activated: true,
                                                    runnerErrorPattern: nil, durationSeconds: 0.1, timeoutSeconds: 60)
                    stopped.stoppedBeforeTests = true
                    return (stopped, "log")
                }
            case .hangs:
                return (MutantObservation(key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: -1, timedOut: true, summary: nil, activated: true,
                                          runnerErrorPattern: nil, durationSeconds: 0.1, timeoutSeconds: 60), "log")
            }
            return (observation(mutant, attempt: attempt, failed: failed, tests: suite == nil ? 4 : 2), "log")
        }

        func control(worker: Int, only: [String]?) -> (passed: Bool, failed: [String], log: String, seconds: Double) {
            lock.lock()
            defer { lock.unlock() }
            log.append("c" + (only.map { ":" + $0.joined(separator: "+") } ?? ""))
            if bNeedsA, let only, only.contains("T/B"), !only.contains("T/A") {
                bAloneFailures += 1
                return (false, ["B/one()"], "log", 0.1)
            }
            if leftoverForB, onlyARemovesTheLeftover {
                // A removes it before B runs; B by itself fails on it and leaves it
                if only == nil || only?.contains("T/A") == true { leftoverForB = false } else if only?.contains("T/B") == true { return (false, ["B/two()"], "log", 0.1) }
            }
            if leftoverForB, only == nil || only?.contains("T/B") == true {
                leftoverForB = false
                return (false, ["B/two()"], "log", 0.1)
            }
            return (true, [], "log", 0.1)
        }
    }

    private func run(_ project: Project, mutants count: Int, confirmation: KillConfirmation = .auto, resuming earlier: URL? = nil,
                     in directory: URL) throws -> MutantExecutor {
        let xcode = XcodeOptions(container: [], scheme: "S", destination: "platform=macOS", testPlan: nil, extraBuildArguments: [],
                                 extraTestArguments: [], onlyTesting: [], skipTesting: [], buildSettings: [])
        var config = RunConfiguration(root: directory, files: [], changedLines: nil, onlyKeys: [], xcode: xcode, prepareCommand: nil,
                                      workDirectory: directory.appendingPathComponent("work"))
        let journal = Journal(url: earlier ?? directory.appendingPathComponent("journal-\(UUID().uuidString).jsonl"))
        if earlier != nil {
            config.resume = true
            journal.load()
        } else {
            try journal.start(fingerprint: "test")
        }
        project.journal = journal.url
        let invocation = Xcode(options: xcode, derivedData: directory)
        let executor = MutantExecutor(
            inputs: .init(session: RunSession(config: config), config: config, journal: journal, xctestrun: directory.appendingPathComponent("none.xctestrun"),
                          xcode: invocation, evidence: BaselineEvidence(testCount: 4, passedTests: 4, skippedTests: 0), selector: project.selector, timeout: 60,
                          baselineTimeout: 60, shared: nil, switchCount: count, confirmation: confirmation, sharedDestination: false,
                          recheckSurvivors: project.recheck, runner: project),
            workers: [MutantExecutor.Worker(index: 0, xcode: invocation)])
        try executor.run(active: (0..<count).map { ConfigJournalAndReportTests.mutant($0) }, reached: Set(0..<count))
        journal.close()
        return executor
    }

    /// The recheck of survivors (the default with --select-tests reach): a mutant that passes the suite that reaches it is run against every test before it is
    /// reported. Mutant 0 is detected only by a test of another suite (through state that its own suite's test leaves
    /// in the process); mutant 1 survives every test; mutant 2 is killed by its own suite and needs no second run.
    @Test func survivorsOfNarrowedTestsAreRunAgainstEveryTest() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.recheck = true
            project.suites = [0: "A", 1: "A", 2: "A"]
            project.behaviours = [0: .failsOnlyWhenEveryTestRuns, 1: .passes, 2: .fails]
            let executor = try run(project, mutants: 3, in: directory)
            #expect((0..<3).map { executor.results[$0]?.status } == [.killed, .survived, .killed])
            // The runs against every test come after all the narrowed runs. Every test is run without mutants before
            // the first of them (the run of mutant 2 did not pass) and again after the one that fails
            // (After mutant 2 failed its suite, the suite is run by itself once.)
            #expect(project.log == ["m0", "m1", "m2", "c:T/A", "c", "m0:all", "c", "m1:all"])
            #expect(executor.recheckedSurvivors == 2)
            // Mutants 0 and 1 got their verdict from every test; mutant 2 was killed by its own suite, and says so
            #expect((0..<3).map { executor.results[$0]?.narrowedOnly } == [nil, nil, true])
            #expect(executor.recheckedDetected == 1)
            #expect(executor.results[0]?.detail?.contains("detected by the whole selection") == true)
            #expect(executor.results[0]?.selectedTests == nil)
            #expect(executor.results[2]?.selectedTests == ["T/A"])

            // Without the option the first mutant is reported as it left its own suite
            let plain = Project()
            plain.suites = project.suites
            plain.behaviours = project.behaviours
            let narrowed = try run(plain, mutants: 3, in: directory)
            #expect((0..<3).map { narrowed.results[$0]?.status } == [.survived, .survived, .killed])
            #expect(plain.log == ["m0", "m1", "m2", "c:T/A"])
            #expect(narrowed.recheckedSurvivors == 0)
            // … and both survivors say that they were not run against all tests; the mutant that was killed does not
            #expect((0..<3).map { narrowed.results[$0]?.narrowedOnly } == [true, true, true])
        }
    }

    /// A suite that passes in a run of all tests and fails when it is run by itself (it needs what
    /// another suite leaves in the process) fails with or without a mutant when a run is narrowed to it. That
    /// failure is not a detection: before it counts, the suite is run by itself without mutants; when it fails
    /// there too, also after a run of every test, its mutants are run against every test. Nothing is blamed on a
    /// mutant, and the destination is not given up.
    @Test func aSuiteThatNeedsAnotherSuiteDoesNotKillByItself() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.bNeedsA = true
            project.suites = [0: "B", 1: "B", 2: "A"]
            project.behaviours = [0: .passes, 1: .fails, 2: .fails]
            let executor = try run(project, mutants: 3, in: directory)
            // Mutant 0 survives every test; mutant 1 is killed by a test of B in a run of every test; mutant 2 by its own suite
            #expect((0..<3).map { executor.results[$0]?.status } == [.survived, .killed, .killed])
            // m0 narrowed to B fails; B by itself without mutants fails, twice; every test passes; B by itself fails
            // again: B needs the others. m0 and m1 are then run against every test (after a run of every test
            // without mutants, since the last run did not pass). m1 fails; before m2, its suite A is run without
            // mutants and passes by itself, so m2's failure needs no further check
            #expect(project.log == ["m0", "c:T/B", "c:T/B", "c", "c:T/B", "c", "m0:all", "m1:all", "c:T/A", "m2"])
            #expect(executor.warnings.map(\.kind) == ["dependentTests"])
            #expect(executor.warnings.first?.message.contains("T/B") == true)
            #expect(executor.results[0]?.selectedTests == nil)
            #expect(executor.results[2]?.selectedTests == ["T/A"])
        }
    }

    /// What a mutant's run leaves behind may be something that
    /// only another suite removes. The suites of the next mutant then fail by themselves however often they are
    /// run; before the destination is given up, every test is run once without mutants. Nothing is a RunnerError.
    @Test func whatOnlyAnotherSuiteRemovesIsRemovedByARunOfEveryTest() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.onlyARemovesTheLeftover = true
            project.suites = [0: "B", 1: "B", 2: "B"]
            project.behaviours = [0: .failsAndLeavesStateForB, 1: .passes, 2: .passes]
            let executor = try run(project, mutants: 3, in: directory)
            #expect((0..<3).map { executor.results[$0]?.status } == [.killed, .survived, .survived])
            #expect(!executor.warnings.contains { $0.kind == "workerDropped" || $0.kind == "dependentTests" })
            #expect(executor.warnings.contains { $0.kind == "stateLeak" })
            // m0 fails and leaves the state. Is B able to pass by itself? Twice no (the state), then every test (A
            // removes the state), then yes. m0 once more: it fails again, and now that counts. Before m1, B by
            // itself fails on the state; every test removes it; m1 and m2 pass
            #expect(project.log == ["m0", "c:T/B", "c:T/B", "c", "c:T/B", "m0", "c:T/B", "c", "m1", "m2"])
        }
    }

    /// What another suite leaves in the process can hide a mutant's effect: the suites that
    /// reach the mutant fail by themselves, and a run of all tests passes. A detection by narrowed tests says so
    /// (`narrowedOnly`), and `--confirm-kills full` runs it against every test, which decides.
    @Test func aDetectionByNarrowedTestsCanBeConfirmedByEveryTest() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.suites = [0: "A", 1: "A", 2: "A"]
            project.behaviours = [0: .failsOnlyWhenNarrowed, 1: .fails, 2: .passes]
            let plain = try run(project, mutants: 3, in: directory)
            #expect((0..<3).map { plain.results[$0]?.status } == [.killed, .killed, .survived])
            #expect((0..<3).map { plain.results[$0]?.narrowedOnly } == [true, true, true])

            let confirming = Project()
            confirming.fullConfirmation = true
            confirming.suites = project.suites
            confirming.behaviours = project.behaviours
            let executor = try run(confirming, mutants: 3, confirmation: .full, in: directory)
            #expect((0..<3).map { executor.results[$0]?.status } == [.survived, .killed, .survived])
            #expect(executor.results[0]?.detail?.contains("the whole selection passed") == true)
            #expect(executor.results[1]?.detail?.contains("confirmed by the whole selection") == true)
            // Neither verdict rests on narrowed tests any more; the survivor of narrowed tests does (no recheck here)
            #expect((0..<3).map { executor.results[$0]?.narrowedOnly } == [nil, nil, true])
            #expect(executor.detectionsRunAgainstAll == 2)
            #expect(executor.detectionsNotConfirmedByAll == 1)
            #expect(confirming.runs == [0: 2, 1: 2, 2: 1])
        }
    }

    /// The same check when the failure of the narrowed tests was real: the suite passes by itself, so the detection
    /// stands and nothing is run again; the next failure of the same suites needs no check.
    @Test func aSuiteThatStandsAloneIsCheckedOnce() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.suites = [0: "A", 1: "A"]
            project.behaviours = [0: .fails, 1: .fails]
            let executor = try run(project, mutants: 2, in: directory)
            #expect((0..<2).map { executor.results[$0]?.status } == [.killed, .killed])
            #expect(project.log == ["m0", "c:T/A", "m1"])
            #expect(executor.warnings.isEmpty)
        }
    }

    /// A run that is stopped because no test had started in time is repeated once: a host that
    /// was slow to start once is not a Timeout (a detection); a start that the mutant hangs is, the second time.
    @Test func aRunThatWasStoppedBeforeItsFirstTestIsRepeatedOnce() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.behaviours = [0: .startsSlowlyOnce, 1: .neverStarts]
            let executor = try run(project, mutants: 2, in: directory)
            #expect((0..<2).map { executor.results[$0]?.status } == [.survived, .timeout])
            // Each first run is followed by a run without mutants (it did not pass) and one more run of the mutant
            #expect(project.log == ["m0", "c", "m0", "m1", "c", "m1"])
            #expect(executor.results[0]?.attempts == 2)
            // The time of a mutant that was stopped twice is that of both runs (the first was left out)
            #expect(abs((executor.results[1]?.durationSeconds ?? 0) - 0.2) < 0.001)
        }
    }

    /// Rechecks that pass follow each other without a run without mutants between them: one such run serves them all.
    @Test func rechecksThatPassShareOneRunWithoutMutants() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.recheck = true
            project.suites = [0: "A", 1: "B", 2: "A", 3: "A"]
            project.behaviours = [0: .passes, 1: .passes, 2: .fails, 3: .passes]
            let executor = try run(project, mutants: 4, in: directory)
            #expect((0..<4).map { executor.results[$0]?.status } == [.survived, .survived, .killed, .survived])
            #expect(project.log == ["m0", "m1", "m2", "c:T/A", "m3", "c", "m0:all", "m1:all", "m3:all"])
            #expect(executor.recheckedDetected == 0)
        }
    }

    /// --resume: the result of a run against every test is taken over as such (it is not compared with the number of
    /// tests of the narrowed selection), and a mutant whose narrowed tests passed but whose run against every test is
    /// missing is run again.
    @Test func resumeTakesOverRechecksAndRepeatsHalfResults() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.recheck = true
            project.suites = [0: "A", 1: "A"]
            project.behaviours = [0: .failsOnlyWhenEveryTestRuns, 1: .passes]
            _ = try run(project, mutants: 2, in: directory)
            let journal = try #require(project.journal)

            let again = Project()
            again.recheck = true
            again.suites = project.suites
            again.behaviours = project.behaviours
            let resumed = try run(again, mutants: 2, resuming: journal, in: directory)
            #expect((0..<2).map { resumed.results[$0]?.status } == [.killed, .survived])
            #expect(again.log == [])
            #expect(resumed.resumedCount == 2)
            #expect(resumed.results[1]?.selectedTests == nil)
            #expect(resumed.results[1]?.narrowedOnly == nil)

            // A journal written without the recheck holds only the pass of the narrowed tests for both mutants:
            // with the recheck on, both are run again (the fingerprint keeps the tool from mixing the two; this is
            // the second line of defence)
            let plain = Project()
            plain.suites = project.suites
            plain.behaviours = project.behaviours
            _ = try run(plain, mutants: 2, in: directory)
            let half = Project()
            half.recheck = true
            half.suites = project.suites
            half.behaviours = project.behaviours
            let completed = try run(half, mutants: 2, resuming: try #require(plain.journal), in: directory)
            #expect(completed.resumedCount == 0)
            #expect((0..<2).map { completed.results[$0]?.status } == [.killed, .survived])
        }
    }

    /// The estimate of the time left counts the runs against every test: those that wait, and the share of the
    /// mutants without a verdict that will survive their narrowed tests if things go on as they have.
    @Test func theEstimateCountsTheRechecks() {
        var time = RemainingTime()
        time.recheckPrior = 30
        time.alone.add(20, count: 10)
        // Nothing has survived its narrowed tests yet: no recheck is expected
        time.firstVerdicts = 10
        #expect(time.estimate(waitingShared: 0, waitingConfirm: 0, waitingAlone: 10, workers: 1).seconds == 20)
        // Four of ten did: of the ten that are left, four more will; six wait already
        time.firstVerdicts = 6
        time.rechecksBegun = 4
        let guessed = time.estimate(waitingShared: 0, waitingConfirm: 0, waitingAlone: 10, waitingRecheck: 6, workers: 1)
        #expect(guessed.seconds == 20 + 10 * 30)
        #expect(!guessed.reliable)
        time.recheck.add(120, count: 3)
        let measured = time.estimate(waitingShared: 0, waitingConfirm: 0, waitingAlone: 10, waitingRecheck: 6, workers: 1)
        #expect(measured.seconds == 20 + 10 * 40)
        #expect(measured.reliable)
    }

    /// After a run that did not pass, only the next mutant's tests are run without mutants, and tests that have
    /// passed since are not run again.
    @Test func theRunWithoutMutantsCoversTheNextMutantsTestsOnly() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.suites = [0: "A", 1: "A", 2: "A", 3: "B", 4: "B"]
            project.behaviours = [0: .fails, 1: .passes, 2: .passes, 3: .passes, 4: .fails]
            let executor = try run(project, mutants: 5, in: directory)
            #expect((0..<5).map { executor.results[$0]?.status } == [.killed, .survived, .survived, .survived, .killed])
            // A once after m0; nothing before m2 (A has passed since); B before the first mutant that runs B
            #expect(project.log == ["m0", "c:T/A", "m1", "m2", "c:T/B", "m3", "m4"])
            #expect(executor.controlRuns == 2)
            #expect(executor.results[1]?.selectedTests == ["T/A"])
            // After the last mutant the whole selection is run once without mutants, in place of the final baseline
            #expect(executor.settleDestinations() == [0])
            #expect(project.log.last == "c")
        }
    }

    /// The property that the run of the whole selection gave, kept test by test: state that the run of mutant 0 left
    /// fails a test of *another* suite. The run without mutants before mutant 1 does not meet it (it runs suite A).
    /// Mutant 2 runs suite B: suite B has not passed without mutants since mutant 0, so it is run first, fails on
    /// the state, and passes when run again. Mutant 2 is not reported as Killed by what mutant 0 left.
    @Test func stateThatFailsATestOutsideTheNextMutantsTestsIsStillNotADetection() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.suites = [0: "A", 1: "A", 2: "B"]
            project.behaviours = [0: .failsAndLeavesStateForB, 1: .passes, 2: .passes]
            let executor = try run(project, mutants: 3, in: directory)
            #expect((0..<3).map { executor.results[$0]?.status } == [.killed, .survived, .survived])
            #expect(project.log == ["m0", "c:T/A", "m1", "c:T/B", "c:T/B", "m2"])
            let leaks = executor.warnings.filter { $0.kind == "stateLeak" }
            #expect(leaks.count == 1)
            // The mutant of the last run that did not pass is named
            #expect(leaks.first?.key == ConfigJournalAndReportTests.mutant(0).key)
            #expect(leaks.first?.message.contains("B/two()") == true)
        }
    }

    /// The same project with --confirm-kills none: the state is counted as a detection of mutant 2 (what the option means).
    @Test func withoutConfirmationTheStateIsCounted() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.suites = [0: "A", 1: "A", 2: "B"]
            project.behaviours = [0: .failsAndLeavesStateForB, 1: .passes, 2: .passes]
            let executor = try run(project, mutants: 3, confirmation: .none, in: directory)
            #expect((0..<3).map { executor.results[$0]?.status } == [.killed, .survived, .killed])
            #expect(project.log == ["m0", "m1", "m2"])
        }
    }

    /// A mutant that is not narrowed runs every test, so every test must have passed without mutants before it; a
    /// failing run without mutants puts all tests in doubt again.
    @Test func aMutantThatRunsEveryTestNeedsTheWholeSelection() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.suites = [0: "A", 2: "A"]
            project.behaviours = [0: .failsAndLeavesStateForB, 1: .passes, 2: .passes]
            let executor = try run(project, mutants: 3, in: directory)
            #expect((0..<3).map { executor.results[$0]?.status } == [.killed, .survived, .survived])
            // Before m1 the whole selection: it fails on the state once, then passes. A after that needs no run
            // (First, A by itself: m0's failure of narrowed tests counts only if they pass alone.)
            #expect(project.log == ["m0", "c:T/A", "c", "c", "m1", "m2"])
            #expect(executor.results[1]?.selectedTests == nil)
        }
    }

    /// --confirm-kills all: a failing run is repeated unless it came directly after a passing run of its own tests
    /// without mutants; a run of another suite in between does not count.
    @Test func confirmAllLooksAtTheMutantsOwnTests() throws {
        try withTemporaryDirectory { directory in
            let project = Project()
            project.suites = [0: "A", 1: "B", 2: "B"]
            project.behaviours = [0: .fails, 1: .fails, 2: .fails]
            let executor = try run(project, mutants: 3, confirmation: .all, in: directory)
            #expect((0..<3).map { executor.results[$0]?.status } == [.killed, .killed, .killed])
            // m0 comes directly after the baseline. m1 comes directly after a run of B without mutants (with it, the
            // suite of the test that m0 failed), and so does m2: neither is repeated
            // (After m0 failed, its suite A is run by itself once: a failure of narrowed tests counts only if they pass alone.)
            #expect(project.log == ["m0", "c:T/A", "c:T/B", "m1", "c:T/B", "m2"])
            #expect(executor.confirmationRuns == 0)
        }
    }

    @Test func failedTestsAreMappedToTheirSuites() {
        let selector = ReachSelector(reach: TestReach(), suites: Project.infos + [TestSuiteInfo(bundle: "U", name: "Shown name", identifier: "C", testCount: 1, seconds: 0.5)],
                                     totalTestCount: 5)
        #expect(selector.suiteIdentifiers(ofFailedTests: ["A/one()", "B/two()", "A/two()"]) == ["T/A", "T/B"])
        #expect(selector.suiteIdentifiers(ofFailedTests: ["Shown name/x()", "C/y()", "Unknown/z()", ""]) == ["U/C"])
        #expect(selector.suiteSeconds == ["T/A": 1, "T/B": 2, "U/C": 0.5])
        // One test without a time: no timeout is narrowed
        let partial = ReachSelector(reach: TestReach(), suites: [TestSuiteInfo(bundle: "T", name: "A", identifier: "A", testCount: 2, seconds: nil)], totalTestCount: 2)
        #expect(partial.suiteSeconds == nil)
    }

    // MARK: Timeouts

    @Test func theTimeoutOfNarrowedTestsComesFromTheirOwnTime() {
        // A baseline of 90 s, 80 s of which are tests; the suite of a mutant took 0.5 s
        let policy = TimeoutPolicy.make(baselineSeconds: 90, suiteSeconds: ["T/A": 0.5, "T/B": 79.5], factor: 3, constant: 30)
        #expect(policy.full == 300)
        #expect(policy.overheadSeconds == 10)
        // (10 s outside the tests + 0.5 s) × 3 + 30 s
        #expect(policy.timeout(for: ["T/A"]) == 61.5)
        #expect(policy.timeout(for: nil) == 300)
        // Never more than a run of everything
        #expect(policy.timeout(for: ["T/A", "T/B"]) == 300)
        // A suite that is not known: the whole timeout
        #expect(policy.timeout(for: ["T/Z"]) == 300)
        #expect(policy.sessionLimit(for: ["T/A"]) == 11.5)
        #expect(policy.sessionLimit(for: nil) == nil)
        // Without times of the tests nothing is narrowed
        let plain = TimeoutPolicy.make(baselineSeconds: 90, suiteSeconds: nil, factor: 3, constant: 30)
        #expect(plain.timeout(for: ["T/A"]) == 300)
        #expect(plain.sessionLimit(for: ["T/A"]) == nil)
    }

    @Test func durationsOfTheResultBundleAreRead() {
        #expect(TestSuiteInfo.seconds("0,0012s") == 0.0012)
        #expect(TestSuiteInfo.seconds("1.5s") == 1.5)
        #expect(TestSuiteInfo.seconds("2m 3s") == 123)
        #expect(TestSuiteInfo.seconds("1h 2m 3s") == 3723)
        #expect(TestSuiteInfo.seconds("soon") == nil)
        #expect(TestSuiteInfo.seconds("") == nil)
        let json: [String: Any] = ["testNodes": [["nodeType": "Unit test bundle", "name": "T", "children": [
            ["nodeType": "Test Suite", "name": "A", "children": [
                ["nodeType": "Test Case", "nodeIdentifier": "A/one()", "duration": "0,5s", "durationInSeconds": 0.5],
                ["nodeType": "Test Case", "nodeIdentifier": "A/two()", "duration": "1,5s"],
            ]],
            ["nodeType": "Test Suite", "name": "B", "children": [["nodeType": "Test Case", "nodeIdentifier": "B/one()"]]],
        ]]]]
        let suites = TestSuiteInfo.parse(json)
        #expect(suites.map(\.seconds) == [2.0, nil])
    }

    // MARK: Shared processes: what a later process takes from the first

    @Test func classesOfTheFirstProcessDecideWithoutARun() {
        var classes = SharedProcess.Classes.parse("launch 6 7\nuneven 30\neven 0 1 2\n")
        #expect(classes.launch == [6, 7])
        #expect(classes.skipReason(6) == "launch")
        #expect(classes.skipReason(30) == "uneven")
        #expect(classes.skipReason(1) == nil)
        #expect(classes.skipReason(99) == "unreached")
        // Another process disagrees about 2: it is no longer treated as evaluated equally often
        classes.merge(SharedProcess.Classes.parse("launch\nuneven 2\neven 0 1 3\n"))
        #expect(classes.skipReason(2) == "uneven")
        #expect(classes.even == [0, 1, 3])
        #expect(SharedProcess.Classes.parse("") == SharedProcess.Classes())
    }

    @Test func eventsOfAProcessWithoutTheTwoRuns() {
        let events = SharedProcessTests.events("""
        HELLO 77 1
        READY
        SKIP 6 launch
        PRE 3 ok 2 0.4
        BEGIN 3 1
        END 3 fail 1 2 0.1\tA/one()
        CHECK 3 ok 2 0.1
        DIRECT 3
        SETTLED 3
        BEGIN 4 1
        END 4 pass 1 2 0.1
        SETTLED 4
        BEGIN 5 0
        """)
        #expect(events.ready)
        #expect(!events.controlsPassed)
        #expect(events.gatePassed)
        #expect(events.pre == [3: "ok"])
        #expect(events.cleanAtBegin == [3, 4])
        #expect(events.begun == [3, 4, 5])
        #expect(SharedProcess.verdict(for: 3, events: events, ending: .exited) == .killed(failed: ["A/one()"], tests: 2, seconds: 0.1))
        #expect(SharedProcess.verdict(for: 4, events: events, ending: .exited) == .survived(tests: 2, seconds: 0.1))
        // The older form of BEGIN (no flag) is read as "not directly after a run without mutants"
        #expect(SharedProcessTests.events("HELLO 1 0\nBEGIN 9\n").cleanAtBegin.isEmpty)
        // The two runs: CLASSES after the second
        let gate = SharedProcessTests.events("HELLO 1 0\nCONTROL 1 ok 4 1.0\nCONTROL 2 ok 4 1.1\nCLASSES\n")
        #expect(gate.classesWritten)
        #expect(gate.gatePassed)
    }

    // MARK: A run that does not end

    @Test func aHangDirectlyAfterAPassingRunWithoutMutantsIsATimeout() {
        func isAlone(_ verdict: SharedProcess.Verdict) -> Bool { if case .alone = verdict { true } else { false } }
        let direct = SharedProcessTests.events("HELLO 1 0\nCONTROL 1 ok 4 1.0\nCONTROL 2 ok 4 1.1\nCLASSES\nBEGIN 3 1\n")
        let hang = SharedProcess.Hang(id: 3, activations: 2, seconds: 13.4, limit: 13.3)
        #expect(SharedProcess.verdict(for: 3, events: direct, ending: .timedOut, hang: hang) == .timedOut(seconds: 13.4, limit: 13.3))
        #expect(!SharedProcess.hangNeedsCleanRun(3, events: direct, ending: .timedOut, hang: hang))
        // Not while the process is still running, and not when it died
        #expect(isAlone(SharedProcess.verdict(for: 3, events: direct, ending: .exited, hang: hang)))
        // The switch was never evaluated in the run that did not end: nothing says that the mutant caused it
        #expect(isAlone(SharedProcess.verdict(for: 3, events: direct, ending: .timedOut, hang: SharedProcess.Hang(id: 3, activations: 0, seconds: 13.4, limit: 13.3))))
        // The shared region names another mutant, or none was read
        #expect(isAlone(SharedProcess.verdict(for: 3, events: direct, ending: .timedOut, hang: SharedProcess.Hang(id: 4, activations: 2, seconds: 13.4, limit: 13.3))))
        #expect(isAlone(SharedProcess.verdict(for: 3, events: direct, ending: .timedOut, hang: nil)))

        // Another mutant's passing run came in between: no verdict here; the mutant is put first in the next process
        let later = SharedProcessTests.events("HELLO 1 0\nCONTROL 1 ok 4 1.0\nCONTROL 2 ok 4 1.1\nBEGIN 2 1\nEND 2 pass 1 4 1.0\nSETTLED 2\nBEGIN 3 0\n")
        #expect(isAlone(SharedProcess.verdict(for: 3, events: later, ending: .timedOut, hang: hang)))
        #expect(SharedProcess.hangNeedsCleanRun(3, events: later, ending: .timedOut, hang: hang))
        #expect(!SharedProcess.hangNeedsCleanRun(2, events: later, ending: .timedOut, hang: hang))

        // The run with the mutant ended; what does not end is the run without it afterwards: not the mutant's hang
        let inCheck = SharedProcessTests.events("HELLO 1 0\nCONTROL 1 ok 4 1.0\nCONTROL 2 ok 4 1.1\nBEGIN 3 1\nEND 3 fail 1 4 1.0\tA/one()\n")
        #expect(isAlone(SharedProcess.verdict(for: 3, events: inCheck, ending: .timedOut, hang: hang)))
        #expect(!SharedProcess.hangNeedsCleanRun(3, events: inCheck, ending: .timedOut, hang: hang))
    }

    @Test func aTimeoutFromASharedProcessIsJudgedAndFinal() {
        var observation = MutantObservation(key: "k", id: 3, attempt: 1, exitStatus: -1, timedOut: true, summary: nil, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 13.4, timeoutSeconds: 13.3)
        observation.sharedProcess = true
        let judged = Judgement.classify(observation, baseline: BaselineEvidence(testCount: 2, passedTests: 2, skippedTests: 0))
        #expect(judged.status == .timeout)
        #expect(judged.detail == "exceeded 13s")
        // Taken over by --resume as it is
        #expect(MutantExecutor.isFinal(observation, status: judged.status, trustSharedSurvivors: false))
    }

    @Test func howAProcessEndedIsSaid() {
        #expect(SharedProcess.exitDescription(nil) == "the process was still running")
        #expect(SharedProcess.exitDescription(3) == "exit status 3")
        #expect(SharedProcess.exitDescription(137) == "the process was ended by signal 9")
        // `simctl launch` ends with 0 whatever the app did
        #expect(SharedProcess.exitDescription(0, viaSimctl: true) == "the app ended; simctl does not say how")
        #expect(SharedProcess.exitDescription(2, viaSimctl: true) == "simctl launch exit status 2")
    }

    // MARK: What a failed start leaves behind

    @Test func theLaunchRecordShowsValuesOnlyOfKnownVariables() {
        let unit = SharedProcess.Target(blueprintName: "AppTests", moduleName: "AppTests", bundlePath: "/p/App.app/PlugIns/AppTests.xctest", only: [], skip: [],
                                        configurationName: "ja", hostPath: "/p/App.app", hostBundleIdentifier: "dev.example.App", isAppHosted: true)
        let text = SharedProcess.launchDescription(
            arguments: ["/usr/bin/xcrun", "simctl", "launch", "--console", "UDID", "dev.example.App"],
            environment: ["SIMCTL_CHILD_API_TOKEN": "secret", "SIMCTL_CHILD_XCMUTATE_SESSION": "/w/shared-process/1",
                          "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "/w/libDriver.dylib", "SIMCTL_CHILD_XCTestBundlePath": "/p/x.xctest"],
            unit: unit)
        #expect(text.contains("unit: ja / AppTests"))
        #expect(text.contains("  simctl\n"))
        #expect(text.contains("  SIMCTL_CHILD_API_TOKEN\n"))
        #expect(!text.contains("secret"))
        #expect(text.contains("SIMCTL_CHILD_XCMUTATE_SESSION=/w/shared-process/1"))
        #expect(text.contains("SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/w/libDriver.dylib"))
        #expect(text.contains("SIMCTL_CHILD_XCTestBundlePath=/p/x.xctest"))
    }

    @Test func evidenceOfAFailedStartIsCopiedToTheLogs() throws {
        try withTemporaryDirectory { directory in
            let session = directory.appendingPathComponent("shared-process/1")
            let logs = directory.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try "first line\n\n  the app says why  \nlast line\n".write(to: session.appendingPathComponent("host.log"), atomically: true, encoding: .utf8)
            try "command".write(to: session.appendingPathComponent("launch.txt"), atomically: true, encoding: .utf8)
            try "HELLO 1 0\n".write(to: session.appendingPathComponent("events.log"), atomically: true, encoding: .utf8)
            let kept = SharedProcess.keepEvidence(sessionDirectory: session, logs: logs, name: "direct-launch-1")
            // The session directory is used again by the next process; the copies are not
            try FileManager.default.removeItem(at: session)
            #expect(kept.directory.path == logs.appendingPathComponent("direct-launch-1").path)
            for file in ["host.log", "launch.txt", "events.log"] {
                #expect(FileManager.default.fileExists(atPath: kept.directory.appendingPathComponent(file).path))
            }
            #expect(kept.note.contains(kept.directory.path))
            #expect(kept.note.contains("The last lines the host wrote: first line | the app says why | last line."))
            #expect(kept.note.contains("the first lines of \(kept.directory.appendingPathComponent("host.log").path)"))
            // A host that wrote nothing
            let empty = directory.appendingPathComponent("shared-process/2")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            #expect(SharedProcess.keepEvidence(sessionDirectory: empty, logs: logs, name: "direct-launch-2").note.contains("The host wrote nothing."))
        }
    }

    /// A test target without a host app: the tool starts the `xctest` agent with its driver bundle, and when the agent
    /// cannot load the bundle it writes the reason first and then its whole environment. The warning showed the last
    /// three lines, a part of that environment ("I really don't know what this means"). The output is what the agent of
    /// Xcode 27.2 wrote on an iOS 27.2 simulator for a bundle that is not there.
    @Test func theWarningQuotesWhyTheAgentStoppedAndNotItsEnvironment() throws {
        let output = """
        Usage: xctest [-XCTest <TestClassOne/testMethodA>(,...)] <path to test bundle>

        Failure: No test bundle found at path `/w/shared-process/driver-1/XCMutateSharedProcess.xctest`.

        Displaying process arguments and environment for debugging purposes:
        Arguments: (
            "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest",
            "-XCTest",
            "XCMutateSharedProcess/testRunMutants",
            "/w/shared-process/driver-1/XCMutateSharedProcess.xctest"
        )
        Environment: {
            HOME = "/Users/USER/Library/Developer/CoreSimulator/Devices/AAAAAAAA-0000-0000-0000-000000000001/data";
            "__XPC_DYLD_FRAMEWORK_PATH" = "/w/DerivedData/Build/Products/Debug-iphonesimulator";
            "__XPC_DYLD_LIBRARY_PATH" = "/w/DerivedData/Build/Products/Debug-iphonesimulator";
        }
        """
        let reason = SharedProcess.hostReason(inOutput: output)
        #expect(reason.chosen)
        #expect(reason.lines == ["Failure: No test bundle found at path `/w/shared-process/driver-1/XCMutateSharedProcess.xctest`.",
                                 "Usage: xctest [-XCTest <TestClassOne/testMethodA>(,...)] <path to test bundle>"])
        // The dynamic loader
        let dyld = "dyld[4711]: Library not loaded: @rpath/Kit.framework/Kit\n  Referenced from: <UUID> /w/Tests.xctest/Tests\n  Reason: tried: '/w/Kit.framework/Kit' (no such file)\n"
        #expect(SharedProcess.hostReason(inOutput: dyld).lines == ["dyld[4711]: Library not loaded: @rpath/Kit.framework/Kit", "Reason: tried: '/w/Kit.framework/Kit' (no such file)"])
        // Nothing known: the last lines, said as such
        #expect(SharedProcess.hostReason(inOutput: "a\nb\nc\nd\n") == (["b", "c", "d"], false))

        try withTemporaryDirectory { directory in
            let session = directory.appendingPathComponent("shared-process/1")
            let logs = directory.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try output.write(to: session.appendingPathComponent("host.log"), atomically: true, encoding: .utf8)
            try "command".write(to: session.appendingPathComponent("launch.txt"), atomically: true, encoding: .utf8)
            let note = SharedProcess.keepEvidence(sessionDirectory: session, logs: logs, name: "direct-launch-1").note
            #expect(note.hasPrefix("What the host said: Failure: No test bundle found at path"))
            #expect(!note.contains("__XPC_DYLD"))
        }
    }

    // MARK: The time that is left

    @Test func theEstimateCountsWhatIsLeftByTheRunItNeeds() {
        var time = RemainingTime()
        // Nothing seen yet: a lower bound of nothing
        #expect(time.estimate(waitingShared: 100, waitingConfirm: 0, waitingAlone: 0, workers: 1) == RemainingTime.Estimate(seconds: 0, reliable: false))

        // 100 mutants went through shared processes in 50 s; 20 of them need a new process, 5 a run under xcodebuild
        time.shared.add(50, count: 100)
        time.throughShared = 100
        time.sharedThenConfirm = 20
        time.sharedThenAlone = 5
        // The cheap ones are done; what waits are 20 new processes and 5 runs under xcodebuild, none seen yet
        let early = time.estimate(waitingShared: 0, waitingConfirm: 20, waitingAlone: 5, workers: 1)
        #expect(early.seconds == 0)
        #expect(!early.reliable)
        #expect(RemainingTime.format(early, formatDuration: RunSession.formatDuration) == "roughly 0s left")
        // With what the baseline says about a launch (8 s) and a run of everything (40 s), the guess is not zero
        time.confirmPrior = 8
        time.alonePrior = 40
        let guessed = time.estimate(waitingShared: 0, waitingConfirm: 20, waitingAlone: 5, workers: 1)
        #expect(guessed == RemainingTime.Estimate(seconds: 360, reliable: false))
        #expect(RemainingTime.format(guessed, formatDuration: RunSession.formatDuration) == "roughly 6m00s left")

        // Three of each seen: 4 s per new process, 60 s per run under xcodebuild (a timeout among them)
        time.confirm.add(12, count: 3)
        time.confirmed = 3
        time.alone.add(180, count: 3)
        let later = time.estimate(waitingShared: 0, waitingConfirm: 17, waitingAlone: 2, workers: 1)
        #expect(later == RemainingTime.Estimate(seconds: 188, reliable: true))
        #expect(RemainingTime.format(later, formatDuration: RunSession.formatDuration) == "about 3m08s left")

        // Mutants still waiting for a shared process bring their share of new processes and runs under xcodebuild
        let mixed = time.estimate(waitingShared: 100, waitingConfirm: 0, waitingAlone: 0, workers: 1)
        #expect(mixed.seconds == 430)
        #expect(mixed.reliable)
        // Two destinations at work
        #expect(time.estimate(waitingShared: 100, waitingConfirm: 0, waitingAlone: 0, workers: 2).seconds == 215)

        // One process per mutant: the average of the runs so far, the runs without mutants included
        var plain = RemainingTime()
        plain.alone.add(30, count: 2)
        #expect(plain.estimate(waitingShared: 0, waitingConfirm: 0, waitingAlone: 10, workers: 1) == RemainingTime.Estimate(seconds: 150, reliable: false))
        plain.alone.add(15)
        #expect(plain.estimate(waitingShared: 0, waitingConfirm: 0, waitingAlone: 10, workers: 1) == RemainingTime.Estimate(seconds: 150, reliable: true))
    }

    // MARK: Declarations that exist for the tests

    @Test func namePatternsOfDeclarations() {
        #expect(DeclarationPatterns.matches("resetForTesting", pattern: "*ForTesting"))
        #expect(DeclarationPatterns.matches("ForTesting", pattern: "*ForTesting"))
        #expect(!DeclarationPatterns.matches("resetForTestingNow", pattern: "*ForTesting"))
        #expect(DeclarationPatterns.matches("_resetCache", pattern: "_reset*"))
        #expect(!DeclarationPatterns.matches("reset", pattern: "_reset*"))
        #expect(DeclarationPatterns.matches("makeStubForTests", pattern: "make*For*"))
        #expect(!DeclarationPatterns.matches("makeStub", pattern: "make*For*"))
        // Without `*` the whole name must be equal
        #expect(DeclarationPatterns.matches("debugDump", pattern: "debugDump"))
        #expect(!DeclarationPatterns.matches("debugDumpAll", pattern: "debugDump"))
        #expect(DeclarationPatterns.matches("anything", pattern: "*"))
        // The parameter list is not part of the name; any enclosing declaration counts
        #expect(DeclarationPatterns.excludes(["Session", "resetForTesting(keeping:)"], patterns: ["*ForTesting"]))
        #expect(DeclarationPatterns.excludes(["TestingHooks", "apply()"], patterns: ["TestingHooks"]))
        #expect(!DeclarationPatterns.excludes(["Session", "add(_:)"], patterns: ["*ForTesting", ""]))
        #expect(!DeclarationPatterns.excludes(["Session", "resetForTesting()"], patterns: []))
    }

    @Test func declarationsNamedInTheConfigAreNotMutated() throws {
        let source = """
        struct Session {
            var count = 0
            mutating func add(_ n: Int) { if n > 0 { count += n } }
            #if DEBUG
            mutating func resetForTesting() { if count > 0 { count = 0 } }
            static func _resetShared(_ session: inout Session) { if session.count > 1 { session.count = 0 } }
            #endif
        }
        """
        let all = MutantGenerator().generate(source: source, filePath: "Session.swift")
        #expect(Set(all.mutants.map(\.enclosingDecl)) == ["Session.add(_:)", "Session.resetForTesting()", "Session._resetShared(_:)"])

        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("xcmutate.config.json")
            try #"{"excludeDeclarations": ["*ForTesting", "_reset*"]}"#.write(to: file, atomically: true, encoding: .utf8)
            let config = try MutatorConfig.load(file)
            #expect(config.loadWarnings.isEmpty)
            let options = try config.generatorOptions(extraArid: [], extraDisabled: [], maxSwitches: nil)
            let narrowed = MutantGenerator(options: options).generate(source: source, filePath: "Session.swift")
            #expect(Set(narrowed.mutants.map(\.enclosingDecl)) == ["Session.add(_:)"])
            // What was left out is listed, with the reason
            let left = narrowed.ignored.filter { $0.reason == .excludedDeclaration }
            #expect(Set(left.map(\.enclosingDecl)) == ["Session.resetForTesting()", "Session._resetShared(_:)"])
            #expect(left.count == all.mutants.count - narrowed.mutants.count + all.ignored.filter { $0.enclosingDecl != "Session.add(_:)" }.count)
        }
    }

    // MARK: Gaps that the run of the tool on itself found in this stage's code

    /// A journal says whether the run that wrote it reached its end; a run that replaces the journal of an unfinished
    /// run says so. What a run records is also there to read without loading the file again.
    @Test func theJournalKnowsWhetherItsRunFinished() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("observations.jsonl")
            let journal = Journal(url: url)
            #expect(!journal.finished)
            try journal.start(fingerprint: "f")
            let observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: 0, timedOut: false, summary: nil, activated: true,
                                                runnerErrorPattern: nil, durationSeconds: 1, timeoutSeconds: 60)
            try journal.record(observation)
            #expect(journal.observations["k"]?.count == 1)
            journal.close()

            // Stopped before the end: the marker is not there
            let unfinished = Journal(url: url)
            #expect(unfinished.load())
            #expect(!unfinished.finished)
            #expect(unfinished.observations["k"]?.count == 1)

            // The same run, continued to its end
            let continued = Journal(url: url)
            #expect(continued.load())
            try continued.recordFinished()
            #expect(continued.finished)
            continued.close()
            let finished = Journal(url: url)
            #expect(finished.load())
            #expect(finished.finished)

            // A new run in the same place starts unfinished
            try finished.start(fingerprint: "g")
            #expect(!finished.finished)
            finished.close()
            let restarted = Journal(url: url)
            #expect(restarted.load())
            #expect(!restarted.finished)
            #expect(restarted.observations.isEmpty)
        }
    }

    /// The estimate is not called reliable while fewer than three mutants have come out of a shared process: the
    /// shares of survivors and of runs under xcodebuild among them are not known yet.
    @Test func theEstimateNeedsThreeMutantsThroughASharedProcess() {
        var time = RemainingTime()
        time.shared.add(9, count: 3)
        time.throughShared = 2
        #expect(!time.estimate(waitingShared: 10, waitingConfirm: 0, waitingAlone: 0, workers: 1).reliable)
        time.throughShared = 3
        #expect(time.estimate(waitingShared: 10, waitingConfirm: 0, waitingAlone: 0, workers: 1).reliable)
        // Nothing waits for a shared process: what went through them does not matter
        time.throughShared = 0
        #expect(time.estimate(waitingShared: 0, waitingConfirm: 0, waitingAlone: 0, workers: 1).reliable)
    }

    /// In a git repository the names of untracked files are part of the state that --resume compares, not only
    /// their contents.
    @Test func theNamesOfUntrackedFilesAreInTheRepositoryState() throws {
        try withTemporaryDirectory { directory in
            func git(_ arguments: [String]) throws {
                let result = try Subprocess.capture(["git", "-C", directory.path, "-c", "user.name=t", "-c", "user.email=t@example.com"] + arguments, timeout: 60)
                #expect(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
            }
            try git(["init", "-q"])
            try "tracked".write(to: directory.appendingPathComponent("Tracked.swift"), atomically: true, encoding: .utf8)
            try git(["add", "Tracked.swift"])
            try git(["commit", "-q", "-m", "one"])
            try "same".write(to: directory.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            let before = RunFingerprint.repositoryState(directory)
            try FileManager.default.moveItem(at: directory.appendingPathComponent("A.swift"), to: directory.appendingPathComponent("B.swift"))
            #expect(RunFingerprint.repositoryState(directory) != before)
            try FileManager.default.moveItem(at: directory.appendingPathComponent("B.swift"), to: directory.appendingPathComponent("A.swift"))
            #expect(RunFingerprint.repositoryState(directory) == before)
        }
    }

    /// A failure with a crash marker from a shared process is Killed by the shared branch also when there is no
    /// baseline to compare the number of tests with (the general branch would call it a Crash).
    @Test func theSharedBranchJudgesWithoutABaselineToo() {
        let summary = TestSummary(result: "Failed", totalTestCount: 3, passedTests: 2, failedTests: 1, skippedTests: 0, expectedFailures: 0,
                                  failures: [.init(test: "T/t()", message: "Crash: App at f()")])
        var observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: 65, timedOut: false, summary: summary, activated: true,
                                            runnerErrorPattern: nil, durationSeconds: 1, timeoutSeconds: 60)
        observation.sharedProcess = true
        let judged = Judgement.classify(observation, baseline: nil)
        #expect(judged.status == .killed)
        #expect(judged.detail == "T/t() failed in a shared process")
    }

    /// The lines of a hunk are counted, so that an added line whose text starts with `++ ` is not read as the header
    /// of another file. An earlier test used a line with one `+` too many, which no parser
    /// would take for a header, so the counting was not tested outside the slow command-line tests.
    @Test func hunkLinesAreCountedAndNotReadAsHeaders() {
        let added = """
        --- a/A.swift
        +++ b/A.swift
        @@ -1,0 +2,3 @@
        +42
        +++ b/Other.swift
        +last
        @@ -20 +30,2 @@
        -old
        +new
        +x
        """
        #expect(DiffFilter.parseUnifiedDiff(added) == ["A.swift": [2...4, 30...31]])

        // After the removed lines of a hunk, and after the note that git prints for a file without a final line
        // break, the added lines are still lines of the hunk
        let replaced = """
        --- a/A.swift
        +++ b/A.swift
        @@ -3 +3,2 @@
        -a
        \\ No newline at end of file
        +++ b/Other.swift
        +c
        @@ -9 +10 @@
        -p
        +q
        """
        #expect(DiffFilter.parseUnifiedDiff(replaced) == ["A.swift": [3...4, 10...10]])

        // The note after the last line of a hunk, and a file that git calls binary, do not end the reading
        let several = """
        --- a/A.swift
        +++ b/A.swift
        @@ -3 +3 @@
        -a
        +b
        \\ No newline at end of file
        Binary files a/Bin.swift and b/Bin.swift differ
        --- a/C.swift
        +++ b/C.swift
        @@ -1 +1 @@
        -x
        +y
        """
        #expect(DiffFilter.parseUnifiedDiff(several) == ["A.swift": [3...3], "Bin.swift": [1...Int.max], "C.swift": [1...1]])
    }

    @Test func everyEscapeOfAQuotedPathIsRead() {
        #expect(DiffFilter.unquote("\"\"") == "")
        #expect(DiffFilter.unquote("\"") == "\"")
        #expect(DiffFilter.unquote(#""a\nb\rc\ad\be\ff\vg""#) == "a\nb\rc\u{07}d\u{08}e\u{0C}f\u{0B}g")
    }
}
