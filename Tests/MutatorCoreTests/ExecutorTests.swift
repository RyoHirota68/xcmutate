import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

/// The order of runs in `MutantExecutor`, with a model of a project in place of `xcodebuild`:
/// state that a run leaves behind, workers on one destination, a worker that stops working.
@Suite(.serialized) struct ExecutorTests {
    /// A project with three tests and state that survives from one test process to the next.
    final class Model: MutantRunning, @unchecked Sendable {
        enum Behaviour {
            /// The tests pass with this mutant on.
            case passes
            /// A test fails with this mutant on.
            case fails
            /// A test fails with this mutant on and is cut short before it removes its file.
            case failsAndLeavesState
            /// The tests pass, but the mutant removed the code that cleans up: state is left.
            case passesAndLeavesState
            /// The tests pass, unless another worker's process is running at the same time (a fixed resource).
            case failsWhenNotAlone
            /// The test host dies with this mutant on, every time.
            case crashes
            /// The test host dies during the first run of this mutant only (something else stopped it).
            case crashesOnce
        }

        let lock = NSLock()
        var behaviours: [Int: Behaviour] = [:]
        /// Per worker: state on the destination that fails one test of the next run, which then removes it.
        var leftover: [Int: Bool] = [:]
        /// Workers whose destination has stopped working: every run there is an infrastructure error.
        var broken: Set<Int> = []
        var running = 0
        /// What ran, in order: `m3` a mutant, `c` the tests without mutants; `@1` on worker 1.
        var log: [String] = []
        var sharedDestination = false

        private func summary(failed: Bool, crashed: Bool = false) -> TestSummary {
            // A crash ends the process: fewer tests ran than in the baseline
            if crashed {
                return TestSummary(result: "Failed", totalTestCount: 2, passedTests: 1, failedTests: 1, skippedTests: 0, expectedFailures: 0,
                                   failures: [.init(test: "LeakTests/testAudit()", message: "Crash: xctest at f()")])
            }
            return TestSummary(result: failed ? "Failed" : "Passed", totalTestCount: 3, passedTests: failed ? 2 : 3, failedTests: failed ? 1 : 0, skippedTests: 0,
                               expectedFailures: 0, failures: failed ? [.init(test: "LeakTests/testAudit()", message: "XCTAssertEqual failed")] : [])
        }
        var crashedOnce: Set<Int> = []

        private func place(_ worker: Int) -> Int { sharedDestination ? 0 : worker }

        func execute(_ mutant: Mutant, worker: Int, attempt: Int) throws -> (MutantObservation, log: String) {
            lock.lock()
            running += 1
            let alone = running == 1
            lock.unlock()
            usleep(20_000)
            lock.lock()
            defer { running -= 1; lock.unlock() }
            log.append("m\(mutant.id)" + (worker == 0 ? "" : "@\(worker)"))
            if broken.contains(worker) {
                return (MutantObservation(key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: 70, timedOut: false, summary: nil, activated: false,
                                          runnerErrorPattern: "Unable to boot", durationSeconds: 0.1, timeoutSeconds: 60), "log")
            }
            var failed = false
            if leftover[place(worker)] == true {
                failed = true
                leftover[place(worker)] = false
            }
            switch behaviours[mutant.id] ?? .passes {
            case .passes: break
            case .fails: failed = true
            case .failsAndLeavesState:
                failed = true
                leftover[place(worker)] = true
            case .passesAndLeavesState: leftover[place(worker)] = true
            case .failsWhenNotAlone: if !alone { failed = true }
            case .crashes, .crashesOnce:
                if behaviours[mutant.id] == .crashes || crashedOnce.insert(mutant.id).inserted {
                    return (MutantObservation(key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: 65, timedOut: false, summary: summary(failed: true, crashed: true),
                                              activated: true, runnerErrorPattern: nil, durationSeconds: 0.1, timeoutSeconds: 60), "log")
                }
            }
            return (MutantObservation(key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: failed ? 65 : 0, timedOut: false, summary: summary(failed: failed),
                                      activated: true, runnerErrorPattern: nil, durationSeconds: 0.1, timeoutSeconds: 60), "log")
        }

        func control(worker: Int, only: [String]?) -> (passed: Bool, failed: [String], log: String, seconds: Double) {
            lock.lock()
            defer { lock.unlock() }
            log.append("c" + (worker == 0 ? "" : "@\(worker)"))
            if broken.contains(worker) { return (false, [], "log", 0.1) }
            if leftover[place(worker)] == true {
                leftover[place(worker)] = false
                return (false, ["LeakTests/testAudit()"], "log", 0.1)
            }
            return (true, [], "log", 0.1)
        }
    }

    private func run(_ model: Model, mutants count: Int, workers: Int = 1, confirmation: KillConfirmation = .auto,
                     in directory: URL) throws -> MutantExecutor {
        let xcode = XcodeOptions(container: [], scheme: "S", destination: "platform=macOS", testPlan: nil, extraBuildArguments: [],
                                 extraTestArguments: [], onlyTesting: [], skipTesting: [], buildSettings: [])
        let config = RunConfiguration(root: directory, files: [], changedLines: nil, onlyKeys: [], xcode: xcode, prepareCommand: nil,
                                      workDirectory: directory.appendingPathComponent("work"))
        let session = RunSession(config: config)
        let journal = Journal(url: directory.appendingPathComponent("journal-\(UUID().uuidString).jsonl"))
        try journal.start(fingerprint: "test")
        let invocation = Xcode(options: xcode, derivedData: directory)
        let executor = MutantExecutor(
            inputs: .init(session: session, config: config, journal: journal, xctestrun: directory.appendingPathComponent("none.xctestrun"), xcode: invocation,
                          evidence: BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0), selector: nil, timeout: 60, baselineTimeout: 60,
                          shared: nil, switchCount: count, confirmation: confirmation, sharedDestination: model.sharedDestination, runner: model),
            workers: (0..<workers).map { MutantExecutor.Worker(index: $0, xcode: invocation) })
        let mutants = (0..<count).map { ConfigJournalAndReportTests.mutant($0) }
        try executor.run(active: mutants, reached: Set(0..<count))
        journal.close()
        return executor
    }

    private func statuses(_ executor: MutantExecutor) -> [MutantStatus?] {
        (0..<executor.results.count).map { executor.results[$0]?.status }
    }

    /// The run of mutant 0 leaves a file behind; the test that meets it fails once and removes it.
    @Test func stateLeftByAFailingRunIsNotCountedAsADetection() throws {
        try withTemporaryDirectory { directory in
            let model = Model()
            model.behaviours = [0: .failsAndLeavesState, 1: .passes, 2: .fails, 3: .passes]
            let executor = try run(model, mutants: 4, in: directory)
            #expect(statuses(executor) == [.killed, .survived, .killed, .survived])
            // After each run that did not pass, the tests without mutants; a second time after the one that failed
            #expect(model.log == ["m0", "c", "c", "m1", "m2", "c", "m3"])
            #expect(executor.controlRuns == 3)
            let leaks = executor.warnings.filter { $0.kind == "stateLeak" }
            #expect(leaks.count == 1)
            #expect(leaks.first?.key == ConfigJournalAndReportTests.mutant(0).key)
            #expect(leaks.first?.message.contains("LeakTests/testAudit()") == true)
        }
    }

    /// The same project without the confirmation: mutant 1 is reported as Killed by the file of mutant 0.
    @Test func withoutConfirmationTheLeftoverKillsTheNextMutant() throws {
        try withTemporaryDirectory { directory in
            let model = Model()
            model.behaviours = [0: .failsAndLeavesState, 1: .passes]
            let executor = try run(model, mutants: 2, confirmation: .none, in: directory)
            #expect(statuses(executor) == [.killed, .killed])
            #expect(model.log == ["m0", "m1"])
            #expect(executor.controlRuns == 0)
        }
    }

    /// The state is still there after the last mutant: the run without mutants that follows reports it, and stands in
    /// for the final baseline on that destination.
    @Test func theLastRunIsFollowedByARunWithoutMutants() throws {
        try withTemporaryDirectory { directory in
            let model = Model()
            model.behaviours = [0: .passes, 1: .failsAndLeavesState]
            let executor = try run(model, mutants: 2, in: directory)
            #expect(model.log == ["m0", "m1"])
            #expect(executor.settleDestinations() == [0])
            #expect(model.log == ["m0", "m1", "c", "c"])
            #expect(executor.warnings.filter { $0.kind == "stateLeak" }.count == 1)
            // A run whose last mutant passed has no such run: the final baseline is still to be run
            let other = Model()
            other.behaviours = [0: .fails, 1: .passes]
            let second = try run(other, mutants: 2, in: directory)
            #expect(second.settleDestinations().isEmpty)
            #expect(other.log == ["m0", "c", "m1"])
        }
    }

    /// A mutant whose tests pass removes the clean-up: `auto` trusts the state after a passing run, `all` does not.
    @Test func confirmAllRepeatsAFailureThatFollowsAPassingMutant() throws {
        try withTemporaryDirectory { directory in
            let auto = Model()
            auto.behaviours = [0: .passesAndLeavesState, 1: .passes, 2: .fails]
            let trusting = try run(auto, mutants: 3, in: directory)
            // The limit of `auto` (documented): mutant 1 is reported as Killed by what mutant 0 left
            #expect(statuses(trusting) == [.survived, .killed, .killed])

            let all = Model()
            all.behaviours = [0: .passesAndLeavesState, 1: .passes, 2: .fails]
            let strict = try run(all, mutants: 3, confirmation: .all, in: directory)
            #expect(statuses(strict) == [.survived, .survived, .killed])
            // m1 fails on the leftover, the tests pass without mutants, m1 passes; m2 fails directly after m1 passed,
            // so it is repeated after a run without mutants too
            #expect(all.log == ["m0", "m1", "c", "m1", "m2", "c", "m2"])
            #expect(strict.confirmationRuns == 2)
            #expect(strict.unconfirmedKills == 1)
            #expect(strict.warnings.filter { $0.kind == "unconfirmedKill" }.map(\.key) == [ConfigJournalAndReportTests.mutant(1).key])
            #expect(strict.results[1]?.detail?.contains("state left by an earlier run") == true)
            #expect(strict.results[2]?.detail?.contains("confirmed") == true)
            #expect(strict.results[2]?.attempts == 2)
        }
    }

    /// A Crash is a verdict only when the test host dies again after the tests have passed without mutants.
    @Test func aCrashIsRunAgain() throws {
        try withTemporaryDirectory { directory in
            let model = Model()
            model.behaviours = [0: .crashes, 1: .crashesOnce, 2: .passes]
            let executor = try run(model, mutants: 3, in: directory)
            #expect(statuses(executor) == [.crash, .survived, .survived])
            #expect(model.log == ["m0", "c", "m0", "c", "m1", "c", "m1", "m2"])
            #expect(executor.results[0]?.attempts == 2)
            #expect(executor.results[0]?.detail?.contains("confirmed") == true)
            #expect(executor.warnings.filter { $0.kind == "unconfirmedKill" }.map(\.key) == [ConfigJournalAndReportTests.mutant(1).key])
            // Not with --confirm-kills none
            let old = Model()
            old.behaviours = [0: .crashesOnce]
            #expect(statuses(try run(old, mutants: 1, confirmation: .none, in: directory)) == [.crash])
        }
    }

    /// Workers that share one Mac: a test fails because two test processes run at the same time.
    @Test func detectionsSeenWhileWorkersShareADestinationAreRunAgainAlone() throws {
        try withTemporaryDirectory { directory in
            let model = Model()
            model.sharedDestination = true
            model.behaviours = Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, Model.Behaviour.failsWhenNotAlone) })
            model.behaviours[7] = .fails
            let executor = try run(model, mutants: 8, workers: 3, in: directory)
            #expect(statuses(executor) == [.survived, .survived, .survived, .survived, .survived, .survived, .survived, .killed])
            #expect(executor.serialConfirmations >= 1)

            // With --confirm-kills none: the collisions are reported as detections
            let old = Model()
            old.sharedDestination = true
            old.behaviours = model.behaviours
            let unconfirmed = try run(old, mutants: 8, workers: 3, confirmation: .none, in: directory)
            #expect(statuses(unconfirmed).contains(.killed))
            #expect(statuses(unconfirmed).filter { $0 == .killed }.count > 1)
        }
    }

    /// A destination stops working in the middle of a run. It must not turn the rest of the queue into RunnerError.
    @Test func aWorkerThatStopsWorkingIsDroppedAndItsMutantRunElsewhere() throws {
        for confirmation in [KillConfirmation.auto, .none] {
            try withTemporaryDirectory { directory in
                let model = Model()
                model.behaviours = [3: .fails]
                let lock = NSLock()
                // Worker 1 passes its first run without mutants and then breaks
                final class Breaking: MutantRunning, @unchecked Sendable {
                    let model: Model
                    var controls = 0
                    let lock: NSLock
                    init(_ model: Model, _ lock: NSLock) { self.model = model; self.lock = lock }
                    func execute(_ mutant: Mutant, worker: Int, attempt: Int) throws -> (MutantObservation, log: String) {
                        try model.execute(mutant, worker: worker, attempt: attempt)
                    }
                    func control(worker: Int, only: [String]?) -> (passed: Bool, failed: [String], log: String, seconds: Double) {
                        let result = model.control(worker: worker, only: only)
                        if worker == 1 {
                            lock.lock()
                            controls += 1
                            if controls == 1 { model.lock.lock(); model.broken.insert(1); model.lock.unlock() }
                            lock.unlock()
                        }
                        return result
                    }
                }
                let runner = Breaking(model, lock)
                let xcode = XcodeOptions(container: [], scheme: "S", destination: "id=A", testPlan: nil, extraBuildArguments: [],
                                         extraTestArguments: [], onlyTesting: [], skipTesting: [], buildSettings: [])
                let config = RunConfiguration(root: directory, files: [], changedLines: nil, onlyKeys: [], xcode: xcode, prepareCommand: nil,
                                              workDirectory: directory.appendingPathComponent("work"))
                let journal = Journal(url: directory.appendingPathComponent("journal.jsonl"))
                try journal.start(fingerprint: "test")
                let invocation = Xcode(options: xcode, derivedData: directory)
                let executor = MutantExecutor(
                    inputs: .init(session: RunSession(config: config), config: config, journal: journal, xctestrun: directory.appendingPathComponent("none.xctestrun"),
                                  xcode: invocation, evidence: BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0), selector: nil, timeout: 60,
                                  baselineTimeout: 60, shared: nil, switchCount: 12, confirmation: confirmation, sharedDestination: false, runner: runner),
                    workers: [0, 1].map { MutantExecutor.Worker(index: $0, xcode: invocation) })
                try executor.run(active: (0..<12).map { ConfigJournalAndReportTests.mutant($0) }, reached: Set(0..<12))
                journal.close()
                let results = (0..<12).map { executor.results[$0]?.status }
                #expect(results.allSatisfy { $0 == .survived || $0 == .killed }, "\(confirmation): \(results)")
                #expect(results[3] == .killed)
                #expect(executor.warnings.contains { $0.kind == "workerDropped" })
                #expect(executor.liveWorkers == [0])
                // The broken worker ran one mutant (twice, the usual retry) and was then checked and dropped
                #expect(model.log.filter { $0.hasPrefix("m") && $0.hasSuffix("@1") }.count == 2, "\(model.log)")
            }
        }
    }

    /// The tests never pass again without mutants on the only destination: the rest of the mutants gets no verdict.
    @Test func whenNoDestinationIsLeftTheRestIsNotJudged() throws {
        try withTemporaryDirectory { directory in
            final class Stuck: MutantRunning, @unchecked Sendable {
                func execute(_ mutant: Mutant, worker: Int, attempt: Int) throws -> (MutantObservation, log: String) {
                    let summary = TestSummary(result: "Failed", totalTestCount: 3, passedTests: 2, failedTests: 1, skippedTests: 0, expectedFailures: 0,
                                              failures: [.init(test: "T/t()", message: "failed")])
                    return (MutantObservation(key: mutant.key, id: mutant.id, attempt: attempt, exitStatus: 65, timedOut: false, summary: summary, activated: true,
                                              runnerErrorPattern: nil, durationSeconds: 0.1, timeoutSeconds: 60), "log")
                }
                func control(worker: Int, only: [String]?) -> (passed: Bool, failed: [String], log: String, seconds: Double) { (false, ["T/t()"], "log", 0.1) }
            }
            let xcode = XcodeOptions(container: [], scheme: "S", destination: "id=A", testPlan: nil, extraBuildArguments: [],
                                     extraTestArguments: [], onlyTesting: [], skipTesting: [], buildSettings: [])
            let config = RunConfiguration(root: directory, files: [], changedLines: nil, onlyKeys: [], xcode: xcode, prepareCommand: nil,
                                          workDirectory: directory.appendingPathComponent("work"))
            let journal = Journal(url: directory.appendingPathComponent("journal.jsonl"))
            try journal.start(fingerprint: "test")
            let invocation = Xcode(options: xcode, derivedData: directory)
            let executor = MutantExecutor(
                inputs: .init(session: RunSession(config: config), config: config, journal: journal, xctestrun: directory.appendingPathComponent("none.xctestrun"),
                              xcode: invocation, evidence: BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0), selector: nil, timeout: 60,
                              baselineTimeout: 60, shared: nil, switchCount: 3, confirmation: .auto, sharedDestination: false, runner: Stuck()),
                workers: [MutantExecutor.Worker(index: 0, xcode: invocation)])
            try executor.run(active: (0..<3).map { ConfigJournalAndReportTests.mutant($0) }, reached: [0, 1, 2])
            journal.close()
            // The first failure came directly after the baseline and stands; nothing after it can be judged
            #expect((0..<3).map { executor.results[$0]?.status } == [.killed, .runnerError, .runnerError])
            #expect(executor.results[1]?.detail?.contains("no longer pass without mutants") == true)
            #expect(executor.warnings.contains { $0.kind == "stateLeak" })
            #expect(executor.warnings.contains { $0.kind == "workerDropped" })
            #expect(executor.pending.isEmpty)
        }
    }
}
