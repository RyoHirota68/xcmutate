import Foundation
import MutatorCore

/// Runs the reached mutants: on one or several workers (one test destination each), in shared processes where that
/// is enabled and possible, and alone otherwise.
///
/// The order of work on each worker:
/// 1. A worker other than the first runs the tests once without mutants on its destination (the first launch on a
///    simulator installs the host app, which must not count against a mutant's timeout). If that run fails or runs
///    a different number of tests, the worker takes no work.
/// 2. While mutants wait for a shared process, the worker takes a share of them and runs them through every unit
///    (test-plan configuration × test target), one process per unit and more after a process was lost.
/// 3. Mutants whose tests passed there are run once more, each in a new process that the tool starts itself
///    (`SharedProcess.DirectLaunch`); only a pass with the expected number of tests and the record of the switch
///    being active counts, and it means Survived.
/// 4. Then it runs, one `xcodebuild` invocation per mutant, whatever is left: what a shared process could not
///    settle and what did not pass in step 3.
///
/// Shared processes are paused while they lose more than they gain: a mutant that crashes the process or hangs it
/// costs a new launch, a mutant that is killed there saves one. Over the last twelve of these two kinds of
/// outcome, when the losses are three or more and outnumber the gains, the next mutants are run alone, one by
/// one, until the balance has turned.
///
/// With several workers a Timeout is provisional: the mutant is run once more after the workers are done, alone on
/// the first destination, and that result is the one reported (a destination that shares the CPU with others is slower,
/// and a Timeout counts as detected).
/// How the executor runs the tests. The default (nil in `MutantExecutor.Inputs`) is `xcodebuild`; the tool's own tests
/// put a model of a project in its place, to exercise the order of runs without a build.
protocol MutantRunning: Sendable {
    /// One run of the tests with `mutant` on, on the destination of worker `worker`.
    func execute(_ mutant: Mutant, worker: Int, attempt: Int) throws -> (MutantObservation, log: String)
    /// One run of the tests without mutants on that destination: the suites of `only`, or the whole selection (nil).
    func control(worker: Int, only: [String]?) -> (passed: Bool, failed: [String], log: String, seconds: Double)
}

final class MutantExecutor: @unchecked Sendable {
    struct Worker {
        var index: Int
        var xcode: Xcode
    }

    struct Inputs {
        var session: RunSession
        var config: RunConfiguration
        var journal: Journal
        var xctestrun: URL
        /// The first destination's invocation (test selection applied).
        var xcode: Xcode
        var evidence: BaselineEvidence
        var selector: ReachSelector?
        var timeout: Double
        /// Timeouts of runs whose tests are narrowed; nil: every run gets `timeout`.
        var timeouts: TimeoutPolicy?
        var baselineTimeout: Double
        var shared: SharedProcess.Setup?
        var switchCount: Int
        /// `--confirm-kills`.
        var confirmation = KillConfirmation.auto
        /// Several workers run on one destination (a Mac): their test processes can collide with each other.
        var sharedDestination = false
        /// With `--select-tests reach`, unless `--no-recheck-survivors`: a mutant that survives its narrowed tests is
        /// run once more against the whole selection.
        var recheckSurvivors = false
        /// Replaces `xcodebuild` (tests of the tool).
        var runner: (any MutantRunning)?
    }

    private let inputs: Inputs
    private let workers: [Worker]
    private let lock = NSLock()

    // State (guarded by `lock`)
    private(set) var results: [Int: MutantResult] = [:]
    private(set) var pending: [String] = []
    private(set) var warnings: [RunWarning] = []
    private(set) var resumedCount = 0
    private(set) var narrowedCount = 0
    private(set) var unnarrowedCount = 0
    private(set) var executedCount = 0
    private(set) var mutantSeconds = 0.0
    private(set) var sharedKilled = 0
    private(set) var sharedSurvived = 0
    private(set) var sharedProcesses = 0
    private(set) var sharedSeconds = 0.0
    private(set) var aloneCount = 0
    /// Mutants whose tests passed in a shared process and passed again in a new process started by the tool.
    private(set) var confirmedDirectly = 0
    /// Shared processes that the tool started itself, without `xcodebuild`.
    private(set) var directSessions = 0
    /// Mutants that were run alone because shared processes were paused.
    private(set) var pausedCount = 0
    private(set) var sharedUnusable: String?
    /// Why the tool stopped starting test hosts itself (nil while it does, or when it never did).
    private(set) var directUnusable: String?
    /// Workers that passed the run without mutants (index 0 always).
    private(set) var liveWorkers: [Int] = [0]
    private var sharedQueue: [Mutant] = []
    private var confirmQueue: [Mutant] = []
    private var aloneQueue: [(mutant: Mutant, note: String?)] = []
    private var sessionLauncher = SharedProcess.Launcher.xcodebuild
    private var directAllowed = false
    /// Workers on whose destination the tests passed in a process started by the tool.
    private var directGate: [Int: Bool] = [:]
    /// Number of tests in the first run without mutants, per unit.
    private var unitTests: [Int: Int] = [:]
    /// The last outcomes that cost or saved a launch (false: a shared process was lost, true: a mutant was killed).
    private var recentOutcomes: [Bool] = []
    private var pauseNoted = false
    /// The tool stopped starting hosts itself because a shared process that it started could not be used.
    private var directGivenUpBySession = false
    /// Results seen while several workers ran that are decided by one more run, alone, when the workers are done.
    private var provisional: [(mutant: Mutant, note: String?)] = []
    /// Per worker: which tests have passed without mutants on its destination since the last run that did not pass.
    /// (The first destination starts right after the baseline.)
    private var ledgers: [Int: ControlLedger] = [0: ControlLedger()]
    /// Per worker: the mutant of the last run that did not pass (named when the tests then fail without mutants).
    private var lastNotPassed: [Int: Mutant] = [:]
    /// Per worker: the mutant whose run did not pass, when that was the last run on the destination (cleared by the
    /// next run that passes, with or without a mutant).
    private var justNotPassed: [Int: Mutant] = [:]
    /// The mutants already named in a `possibleStateLeak` warning.
    private var namedAsPossibleLeak: Set<Int> = []
    /// Per worker: the suites of the tests that failed in the last run that did not pass.
    private var lastFailedSuites: [Int: [String]] = [:]
    /// The two runs without mutants at the start of a shared process have passed for this worker, unit and launcher.
    private struct GateKey: Hashable {
        var worker: Int
        var unit: Int
        var launcher: SharedProcess.Launcher
    }
    private var gates: [GateKey: (tests: Int, seconds: Double)] = [:]
    /// Per unit: what those runs showed about the switches.
    private var classes: [Int: SharedProcess.Classes] = [:]
    /// Mutants that were put first in a new shared process once, after a run of theirs did not end in time.
    private var hangRetried: Set<Int> = []
    /// Mutants that survived the tests that reach them and were then run against the whole selection
    /// (the default with `--select-tests reach`), and how many of them the whole selection detected.
    private(set) var recheckedSurvivors = 0
    private(set) var recheckedDetected = 0
    private var rechecking: Set<Int> = []
    /// `--confirm-kills full`: mutants that their narrowed tests detected and that are run against the whole
    /// selection, how many got a result there, and how many of those passed.
    private var confirmingAgainstAll: Set<Int> = []
    private(set) var detectionsRunAgainstAll = 0
    private(set) var detectionsNotConfirmedByAll = 0
    static let fullConfirmationNote = "detected by the tests that reach it; run against the whole selection (--confirm-kills full)"

    /// Call with the lock held. With `--confirm-kills full`, a detection by narrowed tests is not a verdict yet: the
    /// mutant is queued for a run against the whole selection. Returns true if it was queued (or, when the run is
    /// being cut short, listed as not run).
    private func queueFullConfirmation(_ mutant: Mutant, selected: [String]?) -> Bool {
        guard inputs.confirmation == .full, selected != nil, !confirmingAgainstAll.contains(mutant.id) else { return false }
        if InterruptState.isInterrupted {
            pending.append(mutant.key)
            return true
        }
        confirmingAgainstAll.insert(mutant.id)
        markUnnarrowed(mutant.id)
        aloneQueue.append((mutant, Self.fullConfirmationNote))
        return true
    }

    /// Mutants that wait for their run against the whole selection. Taken when nothing else is left, so that these
    /// runs follow each other: under `xcodebuild` a run of every test must come after a passing run of every test
    /// without mutants, and one such run then serves all the rechecks up to the next one that fails.
    private var recheckQueue: [Mutant] = []
    static let recheckNote = "survived the tests that reach it; run against the whole selection"

    /// Call with the lock held. Whether new processes started by the tool can be used now.
    private var directUsable: Bool { inputs.shared != nil && directAllowed && directUnusable == nil }

    /// Call with the lock held. Unless `--no-recheck-survivors`, a mutant whose narrowed tests passed is not reported
    /// yet: it is queued for a run against the whole selection, which decides. Returns true if it was queued.
    ///
    /// Narrowing by reach rests on "a test that does not run the mutated code is not affected by the mutant". That is
    /// false where a test leaves the mutant's effect in the process for a later test (a singleton that one suite
    /// configures and another reads): with every test run, the later test fails; with the mutant's own suites, nothing
    /// does.
    private func queueRecheck(_ mutant: Mutant, selected: [String]?) -> Bool {
        guard inputs.recheckSurvivors, selected != nil, !rechecking.contains(mutant.id) else { return false }
        // The run is being cut short (an interrupt, the time limit): the mutant has passed its narrowed tests, which
        // is half a result. It is listed as not run; reporting it as Survived would be a verdict that was not reached
        if InterruptState.isInterrupted {
            pending.append(mutant.key)
            return true
        }
        rechecking.insert(mutant.id)
        remaining.rechecksBegun += 1
        markUnnarrowed(mutant.id)
        recheckQueue.append(mutant)
        return true
    }

    /// Shared processes that were started without the two runs without mutants.
    private(set) var ungatedSessions = 0
    /// Mutants that a shared process reported as Timeout.
    private(set) var sharedTimeouts = 0
    private var remaining = RemainingTime()
    /// Per worker: the mutant whose last result was a RunnerError (run again elsewhere if the worker is dropped).
    private var lastRunnerError: [Int: (mutant: Mutant, note: String?)] = [:]
    private var droppedWorkers: Set<Int> = []
    /// The workers are running side by side (false while the provisional results are run again at the end).
    private var parallelPhase = true
    /// Runs of the tests without mutants between mutants (`--confirm-kills`), and their total time.
    private(set) var controlRuns = 0
    private(set) var controlSeconds = 0.0
    /// Mutants run a second time right after the tests passed without mutants, and how many passed then.
    private(set) var confirmationRuns = 0
    private(set) var unconfirmedKills = 0
    /// Detected mutants that were run again alone because workers ran side by side.
    private(set) var serialConfirmations = 0
    private var busy = 0
    private var stalls = 0
    private var canaryDone = false
    private var failure: Error?
    private var total = 0
    private var started = Date()

    init(inputs: Inputs, workers: [Worker]) {
        self.inputs = inputs
        self.workers = workers
        if let shared = inputs.shared, shared.directLaunch {
            directAllowed = true
            sessionLauncher = .direct
        }
        // Before any run of a kind was seen: a run under xcodebuild costs about a baseline run when its tests are
        // not narrowed and what the baseline spent outside the tests when they are; a new process the latter
        if let timeouts = inputs.timeouts {
            let baseline = max((timeouts.full - timeouts.constant) / max(timeouts.factor, 1), 0)
            remaining.alonePrior = inputs.selector?.usable == true ? timeouts.overheadSeconds : baseline
            remaining.confirmPrior = min(timeouts.overheadSeconds, baseline)
            // A run of every test: in a process started by the tool, or under xcodebuild
            remaining.recheckPrior = baseline + (inputs.shared?.directLaunch == true ? 0 : timeouts.overheadSeconds)
        }
    }

    static let outcomeWindow = 12

    /// Whether shared processes lose more launches than they save, judged by the last outcomes.
    static func sharingUnfavourable(_ recent: [Bool]) -> Bool {
        let lost = recent.filter { !$0 }.count
        return lost >= 3 && lost > recent.count - lost
    }

    /// Call with the lock held.
    private func note(gain: Bool) {
        recentOutcomes.append(gain)
        if recentOutcomes.count > Self.outcomeWindow { recentOutcomes.removeFirst() }
    }

    /// The tests of `mutant` in one unit; nil if none of its tests are in that unit.
    private func entry(_ mutant: Mutant, unit: Int) -> SharedProcess.Entry? {
        guard let setup = inputs.shared else { return nil }
        // The driver runs a mutant only after it has seen its switch evaluated equally often in two runs without
        // mutants; one that is not goes back to a process of its own, where it is not narrowed (`markUnnarrowed`)
        guard let selection = inputs.selector?.selection(for: mutant.id, evenlyEvaluated: true) else { return SharedProcess.Entry(id: mutant.id, only: nil, tests: nil) }
        if setup.units.count == 1 {
            let only = unitSelection(selection.onlyTesting, unit: unit)?.only ?? selection.onlyTesting
            return SharedProcess.Entry(id: mutant.id, only: only, tests: selection.testCount)
        }
        guard let part = unitSelection(selection.onlyTesting, unit: unit) else { return nil }
        return SharedProcess.Entry(id: mutant.id, only: part.only, tests: part.tests)
    }

    /// Seconds allowed for one run of a mutant's narrowed tests inside a shared process of `unit` (the part that
    /// comes from the tests themselves); nil if the mutant runs the whole selection there.
    private func sessionLimit(_ mutant: Mutant, unit: Int) -> Double? {
        guard let selection = inputs.selector?.selection(for: mutant.id, evenlyEvaluated: true),
              let part = unitSelection(selection.onlyTesting, unit: unit) else { return nil }
        return inputs.timeouts?.sessionLimit(for: part.identifiers)
    }

    /// Mutants that a shared process found to be evaluated before the tests start, or not equally often in two runs
    /// without mutants: code that runs once per process, whose reach says nothing about which tests it affects.
    /// They are run against the whole selection. (A lock of its own: `plan` is called with and without `lock`.)
    private let unnarrowedLock = NSLock()
    private var unnarrowed: Set<Int> = []

    /// Mutants that a shared process started to run: their switches are evaluated equally often in every run of the tests.
    private var even: Set<Int> = []

    private func isEven(_ id: Int) -> Bool {
        unnarrowedLock.lock()
        defer { unnarrowedLock.unlock() }
        return even.contains(id)
    }

    private func markEven(_ ids: [Int]) {
        unnarrowedLock.lock()
        even.formUnion(ids)
        unnarrowedLock.unlock()
    }

    private func isUnnarrowed(_ id: Int) -> Bool {
        unnarrowedLock.lock()
        defer { unnarrowedLock.unlock() }
        return unnarrowed.contains(id)
    }

    private func markUnnarrowed(_ id: Int) {
        unnarrowedLock.lock()
        unnarrowed.insert(id)
        unnarrowedLock.unlock()
    }

    /// Narrowed selections (sorted suite identifiers) that were run by themselves without mutants: true if they
    /// passed, false if they do not pass without the tests that the whole selection runs before them.
    ///
    /// The baseline shows that the tests pass in a run of the whole selection. It does not show that some suites
    /// pass when only they are run: a suite can need what another suite leaves in the process (a singleton that
    /// an earlier suite configures). Run by itself such a suite fails with or without a mutant, and the failure
    /// must not be taken for a detection. (Guarded by `unnarrowedLock`: `plan` reads it.)
    private var standing: [[String]: Bool] = [:]

    private func standingAlone(_ selected: [String]) -> Bool? {
        unnarrowedLock.lock()
        defer { unnarrowedLock.unlock() }
        return standing[Array(Set(selected)).sorted()]
    }

    private func noteStanding(_ selected: [String], _ value: Bool) {
        unnarrowedLock.lock()
        standing[Array(Set(selected)).sorted()] = value
        unnarrowedLock.unlock()
    }

    /// A run of these suites without mutants failed: what was remembered about combinations that hold one of them
    /// passing by themselves is dropped (it is found out again when one of them fails with a mutant).
    private func forgetStanding(of identifiers: [String]) {
        unnarrowedLock.lock()
        standing = standing.filter { entry in entry.value == false || !entry.key.contains { identifiers.contains($0) } }
        unnarrowedLock.unlock()
    }

    enum Standing: Equatable {
        /// The suites passed by themselves without mutants at the first try.
        case alone
        /// They passed after the whole selection had been run without mutants: the first failure came from state
        /// that an earlier run had left on the destination.
        case aloneAfterCleaning
        /// They do not pass by themselves: they need what other tests leave in the process.
        case dependent
    }

    /// Finds out whether the suites of a narrowed selection pass when only they are run, without mutants. Called
    /// before a failure of exactly these suites is taken as a detection, and before they are run without mutants
    /// as a check after a run that did not pass. nil: it could not be found out (interrupted, or the destination
    /// was dropped).
    private func standsAlone(_ selected: [String], worker: Worker) -> Standing? {
        let scope = ControlScope(selected: selected)
        func run() -> (passed: Bool, failed: [String], log: String)? {
            let number = locked { () -> Int in controlRuns += 1; return controlRuns }
            let result = control(worker, number: number, scope: scope)
            if InterruptState.isInterrupted { return nil }
            locked {
                controlSeconds += result.seconds
                if result.passed { ledgers[worker.index, default: .unknown].controlPassed(scope) } else { ledgers[worker.index, default: .unknown].runDidNotPass() }
            }
            return (result.passed, result.failed, result.log)
        }
        guard let first = run() else { return nil }
        if first.passed {
            noteStanding(selected, true)
            return .alone
        }
        // Either an earlier run left something behind, or these suites need the others. Once more (what was left is
        // often gone after one run); then after the whole selection has passed without mutants; then it is the suites
        guard let again = run() else { return nil }
        if again.passed {
            // (A first run without a result is not evidence of state left behind: see `ensureClean`.)
            locked { if !first.failed.isEmpty || inputs.runner != nil { warnStateLeft(worker, failed: first.failed, log: first.log) } }
            noteStanding(selected, true)
            return .aloneAfterCleaning
        }
        let leaksBefore = locked { warnings.filter { $0.kind == "stateLeak" }.count }
        guard ensureClean(worker, scope: .all) else { return nil }
        guard let second = run() else { return nil }
        if second.passed {
            locked { if warnings.filter({ $0.kind == "stateLeak" }).count == leaksBefore, !first.failed.isEmpty || inputs.runner != nil { warnStateLeft(worker, failed: first.failed, log: first.log) } }
            noteStanding(selected, true)
            return .aloneAfterCleaning
        }
        noteStanding(selected, false)
        locked {
            let tests = second.failed.isEmpty ? "no result" : second.failed.prefix(3).joined(separator: ", ")
            let message = "The tests of \(scope.identifiers?.joined(separator: ", ") ?? "") do not pass when they are run by themselves without mutants (\(tests)), although they pass in a run of the whole selection: they need what other tests leave in the process. Mutants that these suites reach are therefore run against the whole selection; no failure of these suites alone was counted as a detection. Log: \(second.log)"
            progress("tests that need other tests: " + message)
            warnings.append(RunWarning(kind: "dependentTests", message: message))
        }
        return .dependent
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The run for a mutant: the narrowed tests (`--select-tests reach`) and the test count a passing run must have.
    func plan(_ mutant: Mutant) -> (xcode: Xcode, evidence: BaselineEvidence, selected: [String]?) {
        guard !isUnnarrowed(mutant.id), let selection = inputs.selector?.selection(for: mutant.id, evenlyEvaluated: isEven(mutant.id)),
              // Suites that do not pass by themselves are not run by themselves
              standingAlone(selection.onlyTesting) != false else { return (inputs.xcode, inputs.evidence, nil) }
        var narrowed = inputs.xcode
        narrowed.options.onlyTesting = selection.onlyTesting
        return (narrowed, BaselineEvidence(testCount: selection.testCount, passedTests: selection.testCount, skippedTests: 0), selection.onlyTesting)
    }

    /// An observation in the journal of the earlier run whose verdict is settled (a single RunnerError is run again).
    private func settled(_ mutant: Mutant) -> (observation: MutantObservation, attempts: Int)? {
        guard inputs.config.resume, let list = inputs.journal.observations[mutant.key], let last = list.last, last.id == mutant.id else { return nil }
        // The earlier run ran this mutant against the whole selection (it had survived its narrowed tests, or could
        // not be narrowed there): the observation is compared with the whole selection here too
        if last.wholeSelection == true { markUnnarrowed(mutant.id) }
        let status = Judgement.classify(last, baseline: last.recordedEvidence ?? plan(mutant).evidence).status
        if status == .runnerError, list.count < 2 { return nil }
        // A pass in a shared process is a verdict only when survivors are trusted (the fingerprint keeps such a
        // journal from being resumed without the option; this is the second line of defence)
        if !Self.isFinal(last, status: status, trustSharedSurvivors: inputs.config.trustSharedSurvivors) { return nil }
        // While survivors are rechecked a pass of narrowed tests is half a result: the run against every test is missing
        if inputs.recheckSurvivors, status == .survived, last.expectedTests != nil ? last.selectedTests != nil : plan(mutant).selected != nil { return nil }
        return (last, list.count)
    }

    /// Writes into an observation what its run was compared with: the narrowed suites and their number of tests.
    private func stamp(_ observation: inout MutantObservation, _ planned: (xcode: Xcode, evidence: BaselineEvidence, selected: [String]?)) {
        if planned.selected == nil, inputs.selector != nil { observation.wholeSelection = true }
        observation.selectedTests = planned.selected
        observation.expectedTests = planned.evidence.testCount
    }

    /// Whether an observation taken from the journal can stand as the mutant's result.
    static func isFinal(_ observation: MutantObservation, status: MutantStatus, trustSharedSurvivors: Bool) -> Bool {
        if observation.sharedProcess == true, !status.isDetected { return trustSharedSurvivors }
        return true
    }

    /// Call with the lock held.
    private func store(_ mutant: Mutant, _ status: MutantStatus, killedBy: [String] = [], duration: Double? = nil, attempts: Int = 0,
                       detail: String? = nil, selected: [String]? = nil, sharedProcess: Bool? = nil, directLaunch: Bool? = nil,
                       countSelection: Bool = true) {
        var result = MutantResult(mutant: mutant, status: status, killedBy: killedBy, durationSeconds: duration, attempts: attempts, detail: detail)
        result.sharedProcess = sharedProcess
        result.directLaunch = directLaunch
        if inputs.selector != nil, countSelection {
            if selected == nil { unnarrowedCount += 1 } else { narrowedCount += 1 }
            result.selectedTests = selected
            result.coveredBy = inputs.selector?.reach.tests[mutant.id]
            // The verdict rests on the tests that reach the mutant alone: a pass that was not run against the others
            // (--no-recheck-survivors), or a detection that the whole selection was not asked about
            if selected != nil, status == .survived || status.isDetected { result.narrowedOnly = true }
        }
        // A recheck is counted when its run has given the mutant a result, not when it was queued
        if rechecking.contains(mutant.id) { recheckedSurvivors += 1 } else { remaining.firstVerdicts += 1 }
        results[mutant.id] = result
    }

    /// Call with the lock held.
    private lazy var acceptedKeys: Set<String> = inputs.config.accepted.keys

    private func report(_ mutant: Mutant, _ status: MutantStatus, seconds: Double, how: String, plain: Bool = false) {
        executedCount += 1
        // One worker and no shared process: there is only one way a mutant can have been run
        // An undetected mutant that is in the accepted file is reported as Accepted at the end: said here too, so
        // that the line does not read as if the acceptance had no effect
        let shown = status.isUndetected && acceptedKeys.contains(mutant.key) ? "\(status.rawValue) (accepted)" : status.rawValue
        progress(String(format: "[%d/%d] #%d %@ %@:%d %@ (%.1fs, %@%@)", executedCount, total,
                        mutant.id, mutant.operator.rawValue, mutant.file, mutant.start.line, shown, seconds, plain ? "" : how + ", ",
                        RemainingTime.format(remainingEstimate(), formatDuration: RunSession.formatDuration)))
    }

    /// Call with the lock held. What the mutants without a result still cost, by the kind of run each of them needs.
    private func remainingEstimate() -> RemainingTime.Estimate {
        let left = max(total - executedCount, 0)
        // Mutants whose run against the whole selection is still to come (queued, or handed on to xcodebuild)
        let recheck = min(recheckQueue.count + aloneQueue.filter { rechecking.contains($0.mutant.id) }.count, left)
        let confirm = min(confirmQueue.count, left - recheck)
        let alone = min(aloneQueue.filter { !rechecking.contains($0.mutant.id) }.count + provisional.count, left - recheck - confirm)
        // Everything else is in, or waits for, a shared process (without the option: nothing)
        let shared = inputs.shared == nil ? 0 : left - recheck - confirm - alone
        var remaining = remaining
        // Before a run against every test was seen in a new process: what such a process costs for narrowed tests,
        // plus the time the whole selection took inside a shared process (the baseline's time holds xcodebuild's)
        if directUsable, let whole = gates.values.map(\.seconds).max() {
            remaining.recheckPrior = (remaining.confirm.average ?? remaining.confirmPrior) + whole
        }
        return remaining.estimate(waitingShared: shared, waitingConfirm: confirm, waitingAlone: inputs.shared == nil ? left - recheck : alone,
                                  waitingRecheck: recheck, workers: max(liveWorkers.count - droppedWorkers.count, 1))
    }

    /// Runs `active` (the mutants that compiled). Mutants not in `reached` become NotReached.
    func run(active: [Mutant], reached: Set<Int>) throws {
        var toRun: [Mutant] = []
        for mutant in active {
            guard reached.contains(mutant.id) else {
                results[mutant.id] = MutantResult(mutant: mutant, status: .notReached, killedBy: [], durationSeconds: nil, attempts: 0, detail: nil)
                continue
            }
            if let earlier = settled(mutant) {
                // Judged against what the earlier run ran, where the observation says it
                let planned = plan(mutant)
                let recorded = earlier.observation.recordedEvidence
                let judged = Judgement.classify(earlier.observation, baseline: recorded ?? planned.evidence)
                store(mutant, judged.status, killedBy: judged.killedBy, duration: earlier.observation.durationSeconds,
                      attempts: earlier.attempts, detail: judged.detail, selected: recorded != nil ? earlier.observation.selectedTests : planned.selected,
                      sharedProcess: earlier.observation.sharedProcess,
                      directLaunch: earlier.observation.directLaunch)
                resumedCount += 1
                continue
            }
            toRun.append(mutant)
        }
        total = toRun.count
        started = Date()
        if inputs.shared != nil { sharedQueue = toRun } else { aloneQueue = toRun.map { ($0, nil) } }

        let group = DispatchGroup()
        for worker in workers {
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                do {
                    try work(worker)
                } catch {
                    locked { if failure == nil { failure = error } }
                }
            }
        }
        group.wait()
        if let failure { throw failure }

        // Results seen while several workers were running that need one more run: alone, on the first destination that is left
        parallelPhase = false
        if !provisional.isEmpty, !InterruptState.isInterrupted, let worker = workers.first(where: { !droppedWorkers.contains($0.index) }) {
            // Nothing is known about what the parallel runs left behind on a destination that they shared
            if inputs.sharedDestination { ledgers[worker.index, default: .unknown].runDidNotPass() }
            var rest = provisional
            while !rest.isEmpty, !InterruptState.isInterrupted, !droppedWorkers.contains(worker.index) {
                let item = rest.removeFirst()
                try runAlone(item.mutant, note: item.note, worker: worker, provisional: false, paused: false)
            }
        }
        // Whatever was handed back when the last worker was dropped is in the queues
        let unsettled = provisional.filter { item in results[item.mutant.id] == nil && !aloneQueue.contains { $0.mutant.id == item.mutant.id } }
        if InterruptState.isInterrupted {
            pending += sharedQueue.map(\.key) + confirmQueue.map(\.key) + aloneQueue.map(\.mutant.key) + recheckQueue.map(\.key) + unsettled.map(\.mutant.key)
        } else {
            // No destination is left on which the tests pass without mutants: the rest gets no verdict
            let rest = sharedQueue + confirmQueue + aloneQueue.map(\.mutant) + recheckQueue + unsettled.map(\.mutant)
            for mutant in rest where results[mutant.id] == nil {
                store(mutant, .runnerError, detail: "not run: the tests no longer pass without mutants on any destination of this run (see the workerDropped warning)", countSelection: false)
            }
            sharedQueue = []
            confirmQueue = []
            aloneQueue = []
            recheckQueue = []
        }
        if let reason = sharedUnusable {
            warnings.append(RunWarning(kind: "sharedProcessUnavailable", message: "--shared-process was not used: \(reason). Every mutant was run in a process of its own."))
        }
    }

    private func work(_ worker: Worker) throws {
        if worker.index > 0 {
            locked { busy += 1 }
            let ok = warmUp(worker)
            locked {
                busy -= 1
                if ok {
                    liveWorkers.append(worker.index)
                    ledgers[worker.index] = ControlLedger()
                }
            }
            guard ok else { return }
        }
        while true {
            if InterruptState.isInterrupted || locked({ failure != nil || droppedWorkers.contains(worker.index) }) { return }
            if let chunk = takeShared() {
                defer { locked { busy -= 1 } }
                try runShared(chunk, worker: worker)
                continue
            }
            if let mutant = takePaused() {
                defer { locked { busy -= 1 } }
                try runAlone(mutant, note: "shared processes are paused", worker: worker, provisional: workers.count > 1, paused: true)
                continue
            }
            if let mutant = takeConfirm() {
                defer { locked { busy -= 1 } }
                try runConfirm(mutant, worker: worker)
                continue
            }
            if let item = takeAlone() {
                defer { locked { busy -= 1 } }
                try runAlone(item.mutant, note: item.note, worker: worker, provisional: workers.count > 1, paused: false)
                continue
            }
            if let item = takeRecheck() {
                defer { locked { busy -= 1 } }
                if item.direct {
                    try runConfirm(item.mutant, worker: worker)
                } else {
                    try runAlone(item.mutant, note: Self.recheckNote, worker: worker, provisional: workers.count > 1, paused: false)
                }
                continue
            }
            // Another worker may still hand over mutants that its shared process could not settle
            if locked({ busy > 0 }) {
                usleep(100_000)
                continue
            }
            return
        }
    }

    /// The tests once without mutants on a worker's destination.
    private func warmUp(_ worker: Worker) -> Bool {
        if let runner = inputs.runner {
            let ok = runner.control(worker: worker.index, only: nil).passed
            if !ok { locked { warnings.append(RunWarning(kind: "workerDropped", message: "worker \(worker.index + 1) was not used: the tests did not pass there without mutants")) } }
            return ok
        }
        let session = inputs.session
        let log = session.logsDirectory.appendingPathComponent("worker-\(worker.index)-baseline.log")
        let bundle = session.resultsDirectory.appendingPathComponent("worker-\(worker.index)-baseline.xcresult")
        progress("worker \(worker.index + 1): running the tests once without mutants on \(worker.xcode.options.destination)...")
        guard let outcome = try? worker.xcode.testWithoutBuilding(xctestrun: inputs.xctestrun, environment: [:], resultBundle: bundle, log: log,
                                                                  timeout: inputs.baselineTimeout) else { return false }
        let summary = TestSummary.load(bundle)
        try? FileManager.default.removeItem(at: bundle)
        if InterruptState.isInterrupted { return false }
        guard outcome.status == 0, !outcome.timedOut, let summary, summary.failedTests == 0, summary.totalTestCount == inputs.evidence.testCount else {
            let message = "worker \(worker.index + 1) (\(worker.xcode.options.destination)) was not used: the tests did not pass there without mutants, or \(summary?.totalTestCount ?? 0) tests ran instead of \(inputs.evidence.testCount). Log: \(log.path)"
            progress(message)
            locked { warnings.append(RunWarning(kind: "workerDropped", message: message)) }
            return false
        }
        progress(String(format: "worker %d ready (%.1fs)", worker.index + 1, outcome.duration))
        return true
    }

    private func takeShared() -> [Mutant]? {
        locked {
            guard sharedUnusable == nil, !sharedQueue.isEmpty, !Self.sharingUnfavourable(recentOutcomes) else { return nil }
            // An equal share of all mutants per worker (workers still installing the host app will want theirs)
            let share = Int((Double(total) / Double(max(workers.count, 1))).rounded(.up))
            let count = min(sharedQueue.count, max(1, min(share, 200)))
            let chunk = Array(sharedQueue.prefix(count))
            sharedQueue.removeFirst(count)
            busy += 1
            return chunk
        }
    }

    /// While shared processes are paused: the next mutant that waits for one, to be run alone.
    private func takePaused() -> Mutant? {
        locked {
            guard sharedUnusable == nil, !sharedQueue.isEmpty, Self.sharingUnfavourable(recentOutcomes) else { return nil }
            if !pauseNoted {
                pauseNoted = true
                progress("shared processes are paused: crashes and hangs cost more launches than kills save; the next mutants run alone until that changes")
            }
            busy += 1
            pausedCount += 1
            let mutant = sharedQueue.removeFirst()
            // What the two runs without mutants of an earlier process showed holds for a run alone too: a switch that
            // is evaluated equally often in every run of the tests is narrowed to the tests that reach it, also when
            // that is one test (otherwise the run alone would be a run of every test, with the limit of one)
            if let setup = inputs.shared, Self.isKnownEven(mutant.id, classes: classes, units: setup.units.count) { markEven([mutant.id]) }
            return mutant
        }
    }

    /// Whether the runs without mutants of earlier shared processes showed the switch to be evaluated equally often
    /// in every run of the tests: every unit has been looked at, none saw it evaluated before the tests or unevenly,
    /// and at least one saw it evaluated at all.
    static func isKnownEven(_ id: Int, classes: [Int: SharedProcess.Classes], units: Int) -> Bool {
        classes.count == units
            && classes.values.allSatisfy { !$0.launch.contains(id) && !$0.uneven.contains(id) }
            && classes.values.contains { $0.even.contains(id) }
    }

    private func takeConfirm() -> Mutant? {
        locked {
            guard !confirmQueue.isEmpty else { return nil }
            busy += 1
            return confirmQueue.removeFirst()
        }
    }

    /// The next mutant that waits for its run against the whole selection, and whether a process started by the
    /// tool runs it (otherwise `xcodebuild` does).
    private func takeRecheck() -> (mutant: Mutant, direct: Bool)? {
        locked {
            guard !recheckQueue.isEmpty else { return nil }
            busy += 1
            return (recheckQueue.removeFirst(), directUsable)
        }
    }

    private func takeAlone() -> (mutant: Mutant, note: String?)? {
        locked {
            guard !aloneQueue.isEmpty else { return nil }
            busy += 1
            return aloneQueue.removeFirst()
        }
    }

    /// A process started by the tool ended without a result (the verdict then comes from another run, so nothing in
    /// the report says that it happened): the same files as for a process that makes the tool stop starting hosts
    /// are kept under `logs/<name>`, and the progress output says where.
    @discardableResult
    private func keepUnfinished(_ directory: URL, name: String, what: String) -> String {
        let kept = SharedProcess.keepEvidence(sessionDirectory: directory, logs: inputs.session.logsDirectory, name: name)
        progress("note: \(what) ended without a result in a process started by the tool; the verdict comes from the run that follows. \(kept.note)")
        // The class of the test that had started last. When processes end in the same class again and again, it is
        // most likely that class's tests that end the process (a crash in the tests' own code, or data on disk
        // that they read), and the warning says so instead of leaving a row of notes
        let started = ((try? String(contentsOf: kept.directory.appendingPathComponent("tests.log"), encoding: .utf8)) ?? "").split(separator: "\n")
        if let last = started.last {
            let name = last.hasPrefix("-[") ? String(last.dropFirst(2).split(separator: " ").first ?? "") : String(last.split(separator: "/").first ?? last)
            locked {
                unfinishedIn[name, default: []].append(kept.directory.path)
                let places = unfinishedIn[name] ?? []
                guard places.count >= 2 else { return }
                warnings.removeAll { $0.kind == "hostEndsInTests" && $0.message.contains(" while a test of \(name) was the last ") }
                warnings.append(RunWarning(kind: "hostEndsInTests", message: "\(places.count) processes started by the tool ended without a result while a test of \(name) was the last that had started. The mutants are not what they have in common (the runs were made again and the verdicts stand): look for a crash in these tests themselves or in what they set up and tear down, and for data on disk that an earlier run left and that these tests read (a new process does not clear the app's files, database or settings). The records, with the crash reports that were found: \(places.joined(separator: ", "))"))
            }
        }
        return kept.directory.path
    }

    /// The directories kept for processes that ended without a result, by the class of the test that had started last.
    private var unfinishedIn: [String: [String]] = [:]

    /// One run without mutants that did not pass, for the warning that gives a destination up: the tests that
    /// failed, or, for a run without a result, the test that was running when it ended (from the log of xcodebuild,
    /// or from `tests.log` of a process started by the tool).
    static func describe(failedControl result: (passed: Bool, failed: [String], log: String, seconds: Double)) -> String {
        let time = String(format: "%.0f s", result.seconds)
        if !result.failed.isEmpty {
            return "\(result.failed.count) test\(result.failed.count == 1 ? "" : "s") failed after \(time) (\(result.failed.prefix(3).joined(separator: ", "))\(result.failed.count > 3 ? ", …" : ""))"
        }
        var running: [String] = []
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: result.log, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                let started = ((try? String(contentsOfFile: result.log + "/tests.log", encoding: .utf8)) ?? "").split(separator: "\n")
                running = started.last.map { [String($0)] } ?? []
            } else if let text = try? String(contentsOfFile: result.log, encoding: .utf8) {
                running = LogWatch.runningTests(in: text)
            }
        }
        let where_ = running.isEmpty ? "" : "; running when it ended: " + running.prefix(3).joined(separator: ", ")
        return "no result after \(time) (the tests did not finish, or the test process ended)\(where_)"
    }

    /// A picture of the simulator's screen, taken when its destination is given up: a system dialog over the app (a
    /// permission request) stops tests whatever the mutant, and nothing in a log shows it. nil if the destination
    /// is not a simulator or no picture could be taken.
    private func screenshot(_ worker: Worker) -> String? {
        guard inputs.runner == nil,
              let udid = worker.xcode.simulatorUDID ?? SimulatorCheck.simulator(forDestination: worker.xcode.options.destination)?.udid else { return nil }
        let file = inputs.session.logsDirectory.appendingPathComponent("worker-\(worker.index)-dropped-screen.png")
        try? FileManager.default.removeItem(at: file)
        guard let result = try? Subprocess.capture(["xcrun", "simctl", "io", udid, "screenshot", file.path], timeout: 30, ignoresInterrupt: true),
              result.status == 0, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file.path
    }

    /// The text added to the reason why hosts are no longer started by the tool: where the evidence of the process
    /// that failed is kept. (The session directory is used again by the next process.)
    static func keepEvidence(of outcome: SharedProcess.SessionResult, directory: URL, logs: URL, number: Int) -> String {
        let kept = SharedProcess.keepEvidence(sessionDirectory: directory, logs: logs, name: "direct-launch-\(number)")
        return ". " + kept.note
    }

    /// `reason` with the paths of the session directory replaced by those of the copies that are kept.
    static func reasonWithEvidence(_ reason: String, of outcome: SharedProcess.SessionResult, directory: URL, logs: URL, number: Int) -> String {
        let kept = SharedProcess.keepEvidence(sessionDirectory: directory, logs: logs, name: "direct-launch-\(number)")
        return reason.replacingOccurrences(of: directory.path, with: kept.directory.path) + ". " + kept.note
    }

    /// Call with the lock held. The tool stops starting test hosts itself; `xcodebuild` starts them from here on.
    private func giveUpDirectLaunch(_ reason: String) {
        guard directUnusable == nil else { return }
        directUnusable = reason
        sessionLauncher = .xcodebuild
        aloneQueue += confirmQueue.map { ($0, nil) }
        confirmQueue = []
        let message = "Test hosts were started by xcodebuild, not by the tool itself: \(reason)\(reason.hasSuffix(".") || reason.hasSuffix("|") ? "" : ".")"
        progress(message)
        warnings.append(RunWarning(kind: "directLaunchUnavailable", message: message))
    }

    // MARK: The tests without mutants, between mutants

    /// Several workers on one destination disturb each other, so a run without mutants proves nothing there while
    /// they run side by side; what they detect is run again alone at the end instead.
    private var controlsApply: Bool {
        inputs.confirmation != .none && !(inputs.sharedDestination && workers.count > 1 && parallelPhase)
    }

    /// Detected results seen while workers run side by side are decided by one more run alone at the end.
    private var confirmsSerially: Bool {
        workers.count > 1 && parallelPhase && inputs.confirmation != .none && (inputs.sharedDestination || inputs.confirmation == .all)
    }

    /// Call with the lock held, after a run with a mutant on `worker`'s destination.
    /// - Parameter failed: the tests that failed in a run that did not pass, as the report names them.
    private func noteRun(_ worker: Worker, passed: Bool, mutant: Mutant?, failed: [String] = []) {
        if passed {
            justNotPassed[worker.index] = nil
            ledgers[worker.index, default: .unknown].mutantRunPassed()
        } else {
            ledgers[worker.index, default: .unknown].runDidNotPass()
            if let mutant { lastNotPassed[worker.index] = mutant }
            justNotPassed[worker.index] = mutant
            lastFailedSuites[worker.index] = inputs.selector?.suiteIdentifiers(ofFailedTests: failed) ?? []
        }
    }

    /// The timeout of one run of these suites (nil: the whole selection) in a process of its own.
    private func timeout(for selected: [String]?) -> Double {
        inputs.timeouts?.timeout(for: selected) ?? inputs.timeout
    }

    /// The part of a narrowed selection that one unit runs: the tests without the target's name, and their number.
    /// nil if none of the suites are in that unit.
    private func unitSelection(_ identifiers: [String], unit: Int) -> (only: [String], tests: Int?, identifiers: [String])? {
        guard let setup = inputs.shared else { return nil }
        let prefix = setup.units[unit].target.blueprintName + "/"
        if setup.units.count == 1 {
            return (identifiers.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }, inputs.selector?.testCount(of: identifiers), identifiers)
        }
        let own = identifiers.filter { $0.hasPrefix(prefix) }
        guard !own.isEmpty, let tests = inputs.selector?.testCount(of: own) else { return nil }
        return (own.map { String($0.dropFirst(prefix.count)) }, tests, own)
    }

    /// One run without mutants on `worker`'s destination, of the whole selection or of some suites.
    private func control(_ worker: Worker, number: Int, scope: ControlScope) -> (passed: Bool, failed: [String], log: String, seconds: Double) {
        let only = scope.identifiers
        if let runner = inputs.runner { return runner.control(worker: worker.index, only: only) }
        let session = inputs.session
        let limit = timeout(for: only)
        // In a process that the tool starts itself, where that is known to work on this destination (much faster)
        if let setup = inputs.shared, locked({ directUnusable == nil && directGate[worker.index] == true }) {
            let start = Date()
            var counts: [Int: Int] = [:]
            var failed: [String] = []
            var log = ""
            var complete = true
            for unit in setup.units.indices {
                var entry = SharedProcess.Entry(id: -1, only: nil, tests: nil)
                if let only {
                    // None of these suites are in this unit: nothing to run there
                    guard let part = unitSelection(only, unit: unit) else { continue }
                    entry = SharedProcess.Entry(id: -1, only: part.only, tests: part.tests)
                }
                let directory = session.sessionsDirectory.appendingPathComponent("between-w\(worker.index)-\(unit)")
                guard let outcome = try? SharedProcess.runSession(.single(entry, active: nil, trace: nil), setup: setup,
                                                                  unit: unit, launcher: .direct, expectedTests: nil, xcode: worker.xcode, directory: directory,
                                                                  singleTimeout: limit) else {
                    complete = false
                    break
                }
                guard outcome.unusable == nil, let single = outcome.events.single else {
                    // The process ended without a result: what it left is kept (the directory is used again)
                    if !InterruptState.isInterrupted { log = keepUnfinished(directory, name: "direct-between-w\(worker.index)-\(number)", what: "a run without mutants") }
                    complete = false
                    break
                }
                log = outcome.log
                counts[unit] = single.tests
                failed += single.failed
                if single.status != "pass" { complete = false }
                if let tests = entry.tests, single.tests != tests { complete = false }
            }
            let known = locked { unitTests }
            let countsFit = only != nil ? !counts.isEmpty : setup.countsAgree(counts) && (known.count != counts.count || known == counts)
            return (complete && failed.isEmpty && countsFit, failed, log, Date().timeIntervalSince(start))
        }
        let log = session.logsDirectory.appendingPathComponent("between-w\(worker.index)-\(number).log")
        let bundle = session.resultsDirectory.appendingPathComponent("between-w\(worker.index).xcresult")
        var xcode = worker.xcode
        var expected = inputs.evidence.testCount
        if let only, let tests = inputs.selector?.testCount(of: only) {
            xcode.options.onlyTesting = only
            expected = tests
        }
        guard let outcome = try? xcode.testWithoutBuilding(xctestrun: inputs.xctestrun, environment: [:], resultBundle: bundle, log: log,
                                                           timeout: limit) else { return (false, [], log.path, 0) }
        let summary = outcome.timedOut ? nil : TestSummary.load(bundle)
        try? FileManager.default.removeItem(at: bundle)
        let passed = outcome.status == 0 && !outcome.timedOut && summary?.failedTests == 0 && summary?.totalTestCount == expected
        if passed { try? FileManager.default.removeItem(at: log) }
        return (passed, summary?.failures.map(\.test) ?? [], log.path, outcome.duration)
    }

    /// The run without mutants that is due on `worker`'s destination before a run of `wanted`; nil if none is.
    /// Call with the lock held.
    /// - Parameter forced: the destination is in doubt (a RunnerError): one run is due whatever is known.
    private func dueControl(_ worker: Worker, wanted: ControlScope?, forced: Bool) -> ControlScope? {
        var due = controlsApply ? wanted.flatMap { ledgers[worker.index, default: .unknown].missing(for: $0) } : nil
        if due == nil, forced { due = wanted ?? .all }
        guard case let .only(identifiers) = due else { return due }
        // With them, the suites of the tests that the last run that did not pass saw failing: when that run left
        // something behind, they are where it shows first, and the warning then names the mutant that caused it
        let all = Array(Set(identifiers + (lastFailedSuites[worker.index] ?? []))).sorted()
        // A suite whose number of tests is not known cannot be checked: the whole selection then
        return inputs.runner != nil || inputs.selector?.testCount(of: all) != nil ? .only(all) : .all
    }

    /// Call with the lock held. The tests failed once without mutants after a run that did not pass: says so, and
    /// names the mutant of that run.
    private func warnStateLeft(_ worker: Worker, failed: [String], log: String) {
        let result = (failed: failed, log: log)
        let culprit = lastNotPassed[worker.index]
        let place = workers.count > 1 ? " on worker \(worker.index + 1) (\(worker.xcode.options.destination))" : ""
        let tests = result.failed.isEmpty ? "no result" : result.failed.prefix(3).joined(separator: ", ")
        let message = "After the run of \(culprit.map { "mutant #\($0.id) (\($0.file):\($0.start.line), \($0.key))" } ?? "a mutant"), the tests failed once without mutants\(place) (\(tests)). That run left state behind (a file, UserDefaults, a database) that fails a test by itself. The tests were run again without mutants until they passed before the next mutant, so that this state is not counted as a detection; make the tests remove what they create, also when they fail. Log: \(result.log)"
        progress("state left behind: " + message)
        warnings.append(RunWarning(kind: "stateLeak", message: message, key: culprit?.key))
    }

    /// The warning for a destination that is given up. The mutants are not the cause here (the tests fail without
    /// them, three times in a row), so the text says what the runs showed and where to look.
    static func droppedMessage(who: String, destination: String, attempts: Int, notPassed: [String], logs: [String], screenshot: String?, isSimulator: Bool) -> String {
        var message = "\(who) (\(destination)) was not used any further: the tests did not pass without mutants in \(attempts) runs in a row after a mutant's run"
        if !notPassed.isEmpty { message += " (" + notPassed.joined(separator: "; ") + ")" }
        message += ". The mutants that were left were not run (RunnerError) and are not in the score."
        message += logs.isEmpty ? " No log of these runs was kept." : " Logs: " + logs.joined(separator: ", ") + "."
        if let screenshot { message += " The simulator's screen at that moment: \(screenshot)." }
        if isSimulator {
            message += " What to check: whether a system dialog is on the simulator's screen (a permission request for the camera, notifications, the location or the like stops the tests whatever the mutant; grant it beforehand with `xcrun simctl privacy <UDID> grant <service> <bundle id>`), whether the simulator is still booted, and whether the tests pass there when run by hand."
        } else {
            message += " What to check: whether the tests pass on this destination when run by hand, and what the logs say about the tests named above."
        }
        return message
    }

    /// Call with the lock held. A process ended without a result directly after a mutant's run that did not pass.
    /// That can be the destination (a host that is still going down), and it can be what the mutant's run left on
    /// disk: a new process does not clear the app's data (files, a database, settings), and a test that reads them
    /// can end the next process. Not known which, so the
    /// warning says it as a possibility, once per mutant; nothing is blamed and no verdict rests on it.
    private func warnPossibleStateLeft(_ worker: Worker, what: String, log: String) {
        guard inputs.runner == nil, let culprit = justNotPassed[worker.index], namedAsPossibleLeak.insert(culprit.id).inserted else { return }
        let place = workers.count > 1 ? " on worker \(worker.index + 1) (\(worker.xcode.options.destination))" : ""
        let message = "Directly after the run of mutant #\(culprit.id) (\(culprit.file):\(culprit.start.line), \(culprit.key)), in which the tests did not pass, \(what) ended without a result\(place). The mutant's run may have left state behind that a new process does not clear: data of the app on disk (files, a database, settings), which a test of the next process then trips over. It may also be the destination (a host that had not gone down yet). The run was made again, so no verdict depends on it; if this warning comes often, make the tests set up and remove the data they use. Record: \(log.isEmpty ? "none" : log)"
        progress("possibly state left behind: " + message)
        warnings.append(RunWarning(kind: "possibleStateLeak", message: message, key: culprit.key))
    }

    /// Before a run of the tests of `wanted` with a mutant: those of them that have not passed without mutants on
    /// this destination since the last run that did not pass are run without mutants until they pass (three times
    /// at most). `wanted` nil: nothing is needed for the run that follows (only a destination in doubt is checked).
    /// Returns false if the worker cannot go on: the tests did not pass (the worker is dropped), or the tool was
    /// interrupted.
    private func ensureClean(_ worker: Worker, scope wanted: ControlScope?) -> Bool {
        // After a RunnerError the destination itself is in doubt, whatever --confirm-kills says: a destination that
        // stopped working fails every mutant within seconds and would take most of the queue from the healthy workers
        let healthCheck = locked { lastRunnerError[worker.index] != nil }
        let attempts = 3
        var lastLog = ""
        var notPassed: [String] = []
        var logs: [String] = []
        /// Suites failed by themselves without mutants: the next attempt runs every test (what was left behind may be
        /// something that only another suite removes).
        var widen = false
        for attempt in 1...attempts {
            // A failing run without mutants puts every test in doubt again: the next attempt covers all of `wanted`
            guard var scope = locked({ dueControl(worker, wanted: wanted, forced: healthCheck && lastRunnerError[worker.index] != nil) }) else { return true }
            if widen { scope = .all }
            let number = locked { () -> Int in controlRuns += 1; return controlRuns }
            let result = control(worker, number: number, scope: scope)
            if InterruptState.isInterrupted { return false }
            lastLog = result.log
            if !result.passed {
                notPassed.append("run \(notPassed.count + 1): " + Self.describe(failedControl: result))
                if !result.log.isEmpty, !logs.contains(result.log) { logs.append(result.log) }
            }
            let stop: Bool = locked {
                controlSeconds += result.seconds
                if result.passed {
                    justNotPassed[worker.index] = nil
                    ledgers[worker.index, default: .unknown].controlPassed(scope)
                    // These suites pass by themselves: a later failure of exactly them needs no further check
                    if let identifiers = scope.identifiers { noteStanding(identifiers, true) }
                    lastRunnerError[worker.index] = nil
                    lastFailedSuites[worker.index] = nil
                    return true
                }
                ledgers[worker.index, default: .unknown].runDidNotPass()
                // A run without a result (no test is known to have failed) is not evidence of state left behind: the
                // destination was not ready (a host that was stopped a moment ago is still going down). It is run
                // again like any other; the warning is for a test that failed
                if attempt == 1, !healthCheck || controlsApply, !result.failed.isEmpty || inputs.runner != nil { warnStateLeft(worker, failed: result.failed, log: result.log) }
                // Without a result, but directly after a mutant's run that did not pass: said as a possibility
                else if attempt == 1, result.failed.isEmpty { warnPossibleStateLeft(worker, what: "a run of the tests without mutants", log: result.log) }
                if let identifiers = scope.identifiers {
                    // Whatever was known about these suites passing by themselves is in doubt again; and before the
                    // destination is given up, every test is run once (it removes what a single suite cannot)
                    forgetStanding(of: identifiers)
                    widen = true
                }
                return false
            }
            // Whatever else of `wanted` is due is run by the next turn of the loop (nothing, as a rule)
            if stop, locked({ dueControl(worker, wanted: wanted, forced: false) }) == nil { return true }
        }
        if locked({ dueControl(worker, wanted: wanted, forced: lastRunnerError[worker.index] != nil) }) == nil { return true }
        _ = lastLog
        let picture = screenshot(worker)
        locked {
            droppedWorkers.insert(worker.index)
            liveWorkers.removeAll { $0 == worker.index }
            let message = Self.droppedMessage(who: workers.count > 1 ? "Worker \(worker.index + 1)" : "The destination", destination: worker.xcode.options.destination,
                                              attempts: attempts, notPassed: notPassed, logs: logs, screenshot: picture,
                                              isSimulator: worker.xcode.options.destination.contains("Simulator") || picture != nil)
            progress(message)
            warnings.append(RunWarning(kind: "workerDropped", message: message))
            // A RunnerError that this destination produced just before says nothing about the mutant: another worker runs it
            if let item = lastRunnerError[worker.index], workers.contains(where: { !droppedWorkers.contains($0.index) }) {
                results[item.mutant.id] = nil
                executedCount -= 1
                aloneQueue.insert((item.mutant, item.note), at: 0)
            }
            lastRunnerError[worker.index] = nil
        }
        return false
    }

    /// After the last mutant: on every destination where a run did not pass and the whole selection has not passed
    /// without mutants since, it is run without mutants (as before a mutant that runs every test). Returns the workers on
    /// which the last run now is a passing run of the whole selection without mutants; the final baseline has
    /// nothing to add there.
    func settleDestinations() -> Set<Int> {
        guard !InterruptState.isInterrupted else { return [] }
        for worker in workers where locked({ liveWorkers.contains(worker.index) }) { _ = ensureClean(worker, scope: .all) }
        return locked { Set(liveWorkers.filter { ledgers[$0]?.isDirectlyAfterControl(of: .all) == true && ledgers[$0]?.missing(for: .all) == nil }) }
    }

    // MARK: Shared processes

    /// Runs `chunk` through every unit. A mutant is settled when every unit has a verdict for it.
    private func runShared(_ chunk: [Mutant], worker: Worker) throws {
        guard let setup = inputs.shared else { return }
        let units = setup.units
        var verdicts: [Int: [Int: SharedProcess.Verdict]] = [:]
        // Recorded, or handed to another queue
        var settled: Set<Int> = []

        /// Call with the lock held. Takes over what a process says about the mutants of `todo` in unit `unit`.
        func absorb(_ events: SharedProcess.Events, ending: SharedProcess.Ending?, unit: Int, todo: [Mutant], hang: SharedProcess.Hang? = nil) {
            markEven(events.begun)
            for mutant in todo where verdicts[mutant.id]?[unit] == nil {
                let verdict = SharedProcess.verdict(for: mutant.id, events: events, ending: ending ?? .exited, confirmation: setup.confirmation, hang: hang)
                if let reason = events.skipped[mutant.id], reason == "launch" || reason == "uneven" { markUnnarrowed(mutant.id) }
                switch verdict {
                case .notRun:
                    continue
                case .alone:
                    // Whether a started mutant goes back to a process of its own is known only when the process has ended
                    // (or when the driver said so: SKIP, an END that cannot be trusted)
                    guard ending != nil || events.skipped[mutant.id] != nil || events.ended[mutant.id] != nil && events.current != mutant.id else { continue }
                    // Its run did not end in time, but other runs came between it and the last passing run without
                    // mutants: once more, as the first mutant of the next process, where its tests are run without
                    // mutants right before it. (A run under xcodebuild would wait for a whole timeout again.)
                    if let ending, SharedProcess.hangNeedsCleanRun(mutant.id, events: events, ending: ending, hang: hang), hangRetried.insert(mutant.id).inserted {
                        continue
                    }
                case .killed, .survived, .unreached, .timedOut:
                    break
                }
                verdicts[mutant.id, default: [:]][unit] = verdict
            }
        }

        /// Call with the lock held. The verdicts that are known without a process: what the two runs without mutants
        /// of an earlier process of the unit showed about the switches of `todo`.
        func classify(_ todo: [Mutant], unit: Int) {
            guard let known = classes[unit] else { return }
            var events = SharedProcess.Events()
            for mutant in todo where verdicts[mutant.id]?[unit] == nil {
                if let reason = known.skipReason(mutant.id) { events.skipped[mutant.id] = reason }
            }
            absorb(events, ending: nil, unit: unit, todo: todo)
        }

        /// Call with the lock held. Settles the mutants that have a verdict in every unit, or that one unit sent
        /// to a process of their own.
        func settle(session index: Int) throws {
            for mutant in chunk where !settled.contains(mutant.id) {
                let own = verdicts[mutant.id] ?? [:]
                let alone = own.sorted { $0.key < $1.key }.compactMap { item -> String? in
                    if case let .alone(reason) = item.value { return reason }
                    return nil
                }.first
                if let alone {
                    settled.insert(mutant.id)
                    remaining.throughShared += 1
                    remaining.sharedThenAlone += 1
                    aloneQueue.append((mutant, alone))
                    continue
                }
                let hung = own.sorted { $0.key < $1.key }.compactMap { item -> (seconds: Double, limit: Double)? in
                    if case let .timedOut(seconds, limit) = item.value { return (seconds, limit) }
                    return nil
                }.first
                if let hung {
                    // The tests of one unit did not end with the mutant on: detected, whatever the other units say
                    settled.insert(mutant.id)
                    remaining.throughShared += 1
                    canaryDone = true
                    if workers.count > 1, parallelPhase {
                        // A destination that shares the CPU with others is slower: decided by one more run alone at the end
                        self.provisional.append((mutant, "did not finish in time in a shared process while \(workers.count) workers were running"))
                        continue
                    }
                    let planned = plan(mutant)
                    if queueFullConfirmation(mutant, selected: planned.selected) { continue }
                    sharedTimeouts += 1
                    mutantSeconds += hung.seconds
                    var observation = MutantObservation(key: mutant.key, id: mutant.id, attempt: 1, exitStatus: -1, timedOut: true, summary: nil,
                                                        activated: true, runnerErrorPattern: nil, durationSeconds: hung.seconds, timeoutSeconds: hung.limit)
                    observation.sharedProcess = true
                    stamp(&observation, planned)
                    try inputs.journal.record(observation)
                    let judged = Judgement.classify(observation, baseline: planned.evidence)
                    store(mutant, judged.status, duration: hung.seconds, attempts: 1,
                          detail: (judged.detail.map { $0 + " " } ?? "") + "in a shared process, directly after the same tests had passed there without mutants",
                          selected: planned.selected, sharedProcess: true)
                    report(mutant, judged.status, seconds: hung.seconds, how: "shared process \(index)")
                    continue
                }
                guard own.count == units.count, unitTests.count == units.count, setup.countsAgree(unitTests) else { continue }
                settled.insert(mutant.id)
                var failed: [String] = []
                var seconds = 0.0
                var killed = false
                var reached = false
                for unit in units.indices {
                    switch own[unit] {
                    case let .killed(names, _, time):
                        killed = true
                        reached = true
                        seconds += time
                        for name in names where !failed.contains(name) { failed.append(name) }
                    case let .survived(_, time):
                        reached = true
                        seconds += time
                    default:
                        break
                    }
                }
                remaining.throughShared += 1
                guard reached else {
                    remaining.sharedThenAlone += 1
                    aloneQueue.append((mutant, "its switch was not evaluated when the tests ran in the shared process"))
                    continue
                }
                canaryDone = true
                let planned = plan(mutant)
                let tests = planned.evidence.testCount
                if killed, confirmsSerially {
                    // Workers share the destination, or every detection is to be confirmed alone: not final here
                    serialConfirmations += 1
                    provisional.append((mutant, "failed in a shared process while \(workers.count) workers were running"))
                    continue
                }
                if killed {
                    sharedKilled += 1
                    note(gain: true)
                    if queueFullConfirmation(mutant, selected: planned.selected) { continue }
                    mutantSeconds += seconds
                    let summary = TestSummary(result: "Failed", totalTestCount: tests, passedTests: max(tests - failed.count, 0), failedTests: max(failed.count, 1),
                                              skippedTests: 0, expectedFailures: 0,
                                              failures: failed.map { TestSummary.Failure(test: $0, message: "failed with the mutant on in a shared process") })
                    var observation = MutantObservation(key: mutant.key, id: mutant.id, attempt: 1, exitStatus: 65, timedOut: false, summary: summary,
                                                        activated: true, runnerErrorPattern: nil, durationSeconds: seconds, timeoutSeconds: inputs.timeout)
                    observation.sharedProcess = true
                    stamp(&observation, planned)
                    try inputs.journal.record(observation)
                    let judged = Judgement.classify(observation, baseline: planned.evidence)
                    store(mutant, judged.status, killedBy: judged.killedBy, duration: seconds, attempts: 1, detail: judged.detail,
                          selected: planned.selected, sharedProcess: true)
                    report(mutant, judged.status, seconds: seconds, how: "shared process \(index)")
                    continue
                }
                sharedSurvived += 1
                // Passed its narrowed tests: the run against every test is also the run in a new process
                if queueRecheck(mutant, selected: planned.selected) { continue }
                guard inputs.config.trustSharedSurvivors else {
                    if directAllowed, directUnusable == nil {
                        remaining.sharedThenConfirm += 1
                        confirmQueue.append(mutant)
                    } else {
                        remaining.sharedThenAlone += 1
                        aloneQueue.append((mutant, nil))
                    }
                    continue
                }
                mutantSeconds += seconds
                let summary = TestSummary(result: "Passed", totalTestCount: tests, passedTests: tests, failedTests: 0,
                                          skippedTests: 0, expectedFailures: 0, failures: [])
                var observation = MutantObservation(key: mutant.key, id: mutant.id, attempt: 1, exitStatus: 0, timedOut: false, summary: summary,
                                                    activated: true, runnerErrorPattern: nil, durationSeconds: seconds, timeoutSeconds: inputs.timeout)
                observation.sharedProcess = true
                stamp(&observation, planned)
                try inputs.journal.record(observation)
                let judged = Judgement.classify(observation, baseline: planned.evidence)
                store(mutant, judged.status, duration: seconds, attempts: 1, detail: "passed in a shared process; not run again alone (--trust-shared-survivors)",
                      selected: planned.selected, sharedProcess: true)
                report(mutant, judged.status, seconds: seconds, how: "shared process \(index), not confirmed")
            }
        }

        var paused = false
        unitLoop: for unit in units.indices {
            var todo: [Mutant] = []
            locked {
                for mutant in chunk where !settled.contains(mutant.id) {
                    if entry(mutant, unit: unit) == nil {
                        // None of the mutant's tests are in this unit: nothing here can detect it
                        verdicts[mutant.id, default: [:]][unit] = .unreached
                    } else {
                        todo.append(mutant)
                    }
                }
            }
            var stalled = 0
            // A unit without work still has to say how many tests it runs: the counts of all units are compared with the baseline
            var needsCount = todo.isEmpty && units.count > 1 && locked({ unitTests[unit] == nil })
            /// The last process stopped because the first mutant's tests did not pass in it without mutants.
            var precheckFailed = false
            while !todo.isEmpty || needsCount {
                if InterruptState.isInterrupted || locked({ sharedUnusable != nil || failure != nil }) { break unitLoop }
                let (launcher, gate) = try locked { () -> (SharedProcess.Launcher, SharedProcess.Gate) in
                    let launcher = sessionLauncher
                    guard let known = gates[GateKey(worker: worker.index, unit: unit, launcher: launcher)], classes[unit] != nil else { return (launcher, .full) }
                    // What the two runs without mutants of an earlier process showed needs no process
                    classify(todo, unit: unit)
                    try settle(session: sharedProcesses)
                    todo.removeAll { verdicts[$0.id]?[unit] != nil }
                    return (launcher, .known(tests: known.tests, seconds: known.seconds))
                }
                if todo.isEmpty, !needsCount { break }
                // The two runs without mutants at the start of a shared process must not meet what an earlier run left
                // behind: the whole selection must have passed since. A process that does not make them starts with the
                // first mutant's tests without mutants, inside the process; only when those failed there are they
                // run before the next process, which is what tells state on the destination from a process gone wrong.
                var before: ControlScope? = .all
                if gate != .full { before = precheckFailed ? todo.first.map { ControlScope(selected: plan($0).selected) } : nil }
                let sessionStart = Date()
                guard ensureClean(worker, scope: before) else { break unitLoop }
                let (index, expected) = locked { () -> (Int, Int?) in
                    sharedProcesses += 1
                    if launcher == .direct { directSessions += 1 }
                    if gate != .full { ungatedSessions += 1 }
                    return (sharedProcesses, gate != .full ? nil : (units.count == 1 ? setup.expectedTests : unitTests[unit]))
                }
                let directory = inputs.session.sessionsDirectory.appendingPathComponent("\(index)")
                let entries = todo.compactMap { entry($0, unit: unit) }
                var limits: [Int: Double] = [:]
                for mutant in todo { limits[mutant.id] = sessionLimit(mutant, unit: unit) }
                let isLastUnit = unit == units.count - 1
                let outcome = try SharedProcess.runSession(.session(entries), setup: setup, unit: unit, launcher: launcher, expectedTests: expected,
                                                           xcode: worker.xcode, directory: directory, gate: gate, limits: limits) { events in
                    // Final verdicts are recorded while the process is still running the other mutants
                    guard isLastUnit, events.gatePassed else { return }
                    if gate == .full {
                        guard let tests = events.controls[1]?.tests, expected == nil || tests == expected else { return }
                        try locked {
                            unitTests[unit] = tests
                            guard unitTests.count == units.count, setup.countsAgree(unitTests) else { return }
                            absorb(events, ending: nil, unit: unit, todo: todo)
                            try settle(session: index)
                        }
                    } else {
                        try locked {
                            absorb(events, ending: nil, unit: unit, todo: todo)
                            try settle(session: index)
                        }
                    }
                }
                try locked {
                    sharedSeconds += outcome.duration
                    // Failing runs inside the process, a crash or a hang may have left something on the destination
                    let events = outcome.events
                    let allPassed = outcome.ending == .done && events.stop == nil && events.ended.values.allSatisfy { $0.status == "pass" }
                    noteRun(worker, passed: allPassed, mutant: events.begun.last.flatMap { id in chunk.first { $0.id == id } },
                            failed: events.ended.values.flatMap(\.failed))
                    precheckFailed = events.stop == "precheck"
                    if let reason = outcome.unusable {
                        if launcher == .direct {
                            // Not a statement about shared processes: try again with xcodebuild as the launcher
                            sharedProcesses -= 1
                            directSessions -= 1
                            giveUpDirectLaunch(Self.reasonWithEvidence(reason, of: outcome, directory: directory, logs: inputs.session.logsDirectory, number: index))
                            directGivenUpBySession = true
                        } else {
                            sharedUnusable = reason
                            // The same happens under xcodebuild: it was not about who starts the host
                            if directGivenUpBySession { warnings.removeAll { $0.kind == "directLaunchUnavailable" } }
                        }
                        return
                    }
                    if gate == .full {
                        if let tests = outcome.events.controls[1]?.tests { unitTests[unit] = tests }
                        guard setup.countsAgree(unitTests) else {
                            sharedUnusable = "the tests that the driver ran in the units of a configuration do not add up to the \(setup.expectedTests) tests of the baseline"
                            return
                        }
                        if launcher == .direct { directGate[worker.index] = true }
                        // Later processes of this unit on this destination do not make the two runs again
                        if let found = outcome.classes, let first = events.controls[1], let second = events.controls[2], events.controlsPassed {
                            gates[GateKey(worker: worker.index, unit: unit, launcher: launcher)] = (first.tests, max(first.seconds, second.seconds))
                            classes[unit, default: SharedProcess.Classes()].merge(found)
                        }
                    }
                    needsCount = false
                    absorb(outcome.events, ending: outcome.ending, unit: unit, todo: todo, hang: outcome.hang)
                    try settle(session: index)
                    let before = todo.count
                    todo.removeAll { verdicts[$0.id]?[unit] != nil }
                    // A mutant whose run did not end in time and that gets one more run: first in the next process
                    if let hung = outcome.hang?.id, let position = todo.firstIndex(where: { $0.id == hung }), position > 0 {
                        todo.insert(todo.remove(at: position), at: 0)
                    }
                    remaining.shared.add(Date().timeIntervalSince(sessionStart), count: before - todo.count)
                    if outcome.ending == .exited || outcome.ending == .timedOut {
                        // The process was lost to a crash or a hang
                        note(gain: false)
                        if Self.sharingUnfavourable(recentOutcomes) { paused = true }
                    }
                    if before > 0, todo.count == before, outcome.ending != .interrupted {
                        // Processes that settle nothing would repeat forever
                        stalled += 1
                        if stalled >= 2 { sharedUnusable = "two shared processes in a row ended without judging a mutant (log: \(outcome.log))" }
                    } else {
                        stalled = 0
                    }
                }
                if paused { break unitLoop }
            }
            // The last unit may have had no work: settle with what the earlier units said
            if unit == units.count - 1 { try locked { try settle(session: sharedProcesses) } }
        }
        locked {
            let rest = chunk.filter { !settled.contains($0.id) }
            if let reason = sharedUnusable {
                if !rest.isEmpty || !sharedQueue.isEmpty {
                    progress("--shared-process cannot be used (\(reason)); running every mutant in a process of its own")
                }
                aloneQueue += (rest + sharedQueue).map { ($0, nil) }
                sharedQueue = []
            } else {
                // Interrupted (reported as pending), or paused (taken one by one)
                sharedQueue = rest + sharedQueue
            }
        }
    }

    // MARK: A new process per survivor, started by the tool

    /// Whether the tests pass, as many as in the baseline, in processes that the tool starts itself on this
    /// worker's destination. Checked once per worker, with a run without mutants in every unit.
    private func directLaunchWorks(_ worker: Worker) throws -> Bool {
        guard let setup = inputs.shared else { return false }
        if let known = locked({ directUnusable != nil ? false : directGate[worker.index] }) { return known }
        var counts: [Int: Int] = [:]
        var problem: String?
        for unit in setup.units.indices {
            let directory = inputs.session.sessionsDirectory.appendingPathComponent("control-w\(worker.index)-\(unit)")
            let outcome = try SharedProcess.runSession(.single(SharedProcess.Entry(id: -1, only: nil, tests: nil), active: nil, trace: nil), setup: setup, unit: unit,
                                                       launcher: .direct, expectedTests: nil, xcode: worker.xcode, directory: directory, singleTimeout: inputs.timeout)
            if InterruptState.isInterrupted { return false }
            guard outcome.unusable == nil, let single = outcome.events.single, single.status == "pass" else {
                let how = outcome.events.single.map { "\($0.status)\($0.failed.isEmpty ? "" : ": " + $0.failed.prefix(3).joined(separator: ", "))" }
                    ?? (outcome.ending == .timedOut ? "they did not finish in \(Int(inputs.timeout))s" : "the process ended before they had finished, \(SharedProcess.exitDescription(outcome.exitCode))")
                problem = Self.reasonWithEvidence(outcome.unusable ?? "the tests of \(setup.units[unit].target.label) did not pass without mutants in a process started by the tool (\(how); log: \(outcome.log))",
                                                  of: outcome, directory: directory, logs: inputs.session.logsDirectory, number: 0)
                break
            }
            counts[unit] = single.tests
        }
        if problem == nil {
            let known = locked { unitTests }
            if !setup.countsAgree(counts) || (known.count == counts.count && known != counts) {
                problem = "a process started by the tool ran \(counts.sorted { $0.key < $1.key }.map { String($0.value) }.joined(separator: " + ")) tests; the baseline ran \(setup.expectedTests)"
            }
        }
        locked {
            directGate[worker.index] = problem == nil
            if let problem { giveUpDirectLaunch(problem) }
        }
        return problem == nil
    }

    /// Runs a mutant whose tests passed in the shared processes once more, in a new process per unit with the
    /// mutant on from the start. A pass in every unit is Survived; anything else is decided by `xcodebuild`.
    private func runConfirm(_ mutant: Mutant, worker: Worker) throws {
        guard let setup = inputs.shared else { return }
        // A mutant that survived its narrowed tests: this run is against the whole selection
        let whole = locked { rechecking.contains(mutant.id) }
        guard try directLaunchWorks(worker) else {
            locked { if InterruptState.isInterrupted { pending.append(mutant.key) } else { aloneQueue.append((mutant, whole ? Self.recheckNote : nil)) } }
            return
        }
        // A pass in the new process is the only result taken from it, and what an earlier run left on the destination
        // does not make tests pass: no run without mutants is needed before it. (A run that does not pass there goes
        // to xcodebuild, and before that run the mutant's tests are run without mutants.) Only a destination in doubt
        // is checked.
        guard ensureClean(worker, scope: nil) else {
            locked {
                if InterruptState.isInterrupted { pending.append(mutant.key) } else if whole { recheckQueue.insert(mutant, at: 0) } else { confirmQueue.insert(mutant, at: 0) }
            }
            return
        }
        let planned = plan(mutant)
        let trace = inputs.session.tracesDirectory.appendingPathComponent("\(mutant.id)-direct.trace")
        try? FileManager.default.removeItem(at: trace)
        let start = Date()
        var problem: String?
        for unit in setup.units.indices {
            guard let entry = whole ? SharedProcess.Entry(id: mutant.id, only: nil, tests: nil) : entry(mutant, unit: unit) else { continue }
            let expected = entry.tests ?? (setup.units.count == 1 ? setup.expectedTests : locked { unitTests[unit] })
            let directory = inputs.session.sessionsDirectory.appendingPathComponent("confirm-\(mutant.id)-\(unit)")
            let outcome = try SharedProcess.runSession(.single(entry, active: mutant.id, trace: trace), setup: setup, unit: unit, launcher: .direct,
                                                       expectedTests: nil, xcode: worker.xcode, directory: directory, singleTimeout: timeout(for: planned.selected))
            if InterruptState.isInterrupted {
                locked { pending.append(mutant.key) }
                return
            }
            guard outcome.unusable == nil, let single = outcome.events.single else {
                problem = outcome.ending == .timedOut ? "the tests did not finish in time" : "the process ended without a result"
                let kept = keepUnfinished(directory, name: "direct-confirm-\(mutant.id)-\(unit)", what: "the run of mutant #\(mutant.id) in a new process")
                locked { warnPossibleStateLeft(worker, what: "the run of mutant #\(mutant.id) in a new process", log: kept) }
                try? FileManager.default.removeItem(at: directory)
                break
            }
            guard single.status == "pass" else {
                problem = "the tests did not pass"
                break
            }
            guard single.tests == expected else {
                problem = "\(single.tests) tests ran, \(expected.map(String.init) ?? "an unknown number") were expected"
                break
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let seconds = Date().timeIntervalSince(start)
        if problem == nil, !Trace.read(trace).activated.contains(mutant.id) {
            problem = "the switch was not recorded as evaluated while active"
        }
        try locked {
            noteRun(worker, passed: problem == nil, mutant: mutant)
            if whole {
                remaining.recheck.add(seconds)
            } else {
                remaining.confirm.add(seconds)
                remaining.confirmed += 1
            }
            if let problem {
                if !whole { remaining.confirmThenAlone += 1 }
                aloneQueue.append((mutant, (whole ? Self.recheckNote + "; " : "") + "in a new process started by the tool, \(problem)"))
                return
            }
            let tests = planned.evidence.testCount
            let summary = TestSummary(result: "Passed", totalTestCount: tests, passedTests: tests, failedTests: 0, skippedTests: 0, expectedFailures: 0, failures: [])
            var observation = MutantObservation(key: mutant.key, id: mutant.id, attempt: 1, exitStatus: 0, timedOut: false, summary: summary,
                                                activated: true, runnerErrorPattern: nil, durationSeconds: seconds, timeoutSeconds: inputs.timeout)
            observation.sharedProcess = false
            observation.directLaunch = true
            stamp(&observation, planned)
            try inputs.journal.record(observation)
            let judged = Judgement.classify(observation, baseline: planned.evidence)
            mutantSeconds += seconds
            confirmedDirectly += 1
            store(mutant, judged.status, killedBy: judged.killedBy, duration: seconds, attempts: 1, detail: judged.detail,
                  selected: planned.selected, sharedProcess: false, directLaunch: true)
            report(mutant, judged.status, seconds: seconds, how: (workers.count > 1 ? "worker \(worker.index + 1), " : "") + (whole ? "new process, every test" : "new process"))
        }
    }

    // MARK: One process per mutant

    private func runAlone(_ mutant: Mutant, note: String?, worker: Worker, provisional: Bool, paused: Bool) throws {
        let aloneStart = Date()
        var planned = plan(mutant)
        // Before these suites are run without mutants as a check for state left behind: do they pass by themselves at
        // all? (A check that fails for that reason would be taken for state left behind, three times, and the
        // destination would be given up.)
        if inputs.confirmation != .none, let selected = planned.selected, standingAlone(selected) == nil,
           locked({ dueControl(worker, wanted: ControlScope(selected: selected), forced: false) }) != nil {
            guard standsAlone(selected, worker: worker) != nil else {
                locked { if InterruptState.isInterrupted { pending.append(mutant.key) } else { aloneQueue.insert((mutant, note), at: 0) } }
                return
            }
            planned = plan(mutant)
        }
        let scope = ControlScope(selected: planned.selected)
        // The mutant's tests must have passed without mutants on this destination before it is judged there
        guard ensureClean(worker, scope: scope) else {
            locked { if InterruptState.isInterrupted { pending.append(mutant.key) } else { aloneQueue.insert((mutant, note), at: 0) } }
            return
        }
        var runXcode = worker.xcode
        runXcode.options.onlyTesting = planned.xcode.options.onlyTesting
        var attempt = 0
        var outcome: RunSession.Evaluation?
        /// Whether the last run came directly after a passing run without mutants.
        var cleanAtRun = true
        /// A run that was stopped before its first test has been repeated.
        var startRepeated = false
        /// The time of the run that a limit stopped and that was then made again: part of what the mutant cost (it was
        /// left out, and a mutant stopped twice by a limit of 46 s was reported with 51.7 s).
        var stoppedRunSeconds = 0.0
        /// The observations of this call, written to the journal when the mutant gets its result from them.
        var observed: [MutantObservation] = []
        /// Runs the mutant until it has a result that is not a RunnerError (twice at most). False: stop here.
        func observe() throws -> Bool {
            var tries = 0
            repeat {
                attempt += 1
                tries += 1
                let cleanBefore = locked { ledgers[worker.index]?.isDirectlyAfterControl(of: scope) == true }
                func once() throws -> (MutantObservation, log: String) {
                    try inputs.runner?.execute(mutant, worker: worker.index, attempt: attempt)
                        ?? inputs.session.execute(mutant, xcode: runXcode, xctestrun: inputs.xctestrun, timeout: timeout(for: planned.selected), attempt: attempt,
                                                  watch: inputs.timeouts?.watch(for: planned.selected))
                }
                var run = try once()
                // Stopped because no test had started in time: once more before it counts. A host that is slow to start
                // (a busy machine, a simulator that was restarted) would otherwise be a Timeout, which is a detection,
                // for every mutant that is evaluated while the host starts; a start that the mutant hangs repeats.
                if run.0.stoppedBeforeTests == true || run.0.stoppedInTest == true, !startRepeated, !InterruptState.isInterrupted {
                    startRepeated = true
                    progress("#\(mutant.id): \(run.0.stoppedInTest == true ? "one test did not end within the time allowed for a single test" : "no test had started when the limit for starting the host was reached"); running it once more before that counts")
                    locked { noteRun(worker, passed: false, mutant: mutant) }
                    guard ensureClean(worker, scope: scope) else {
                        locked { if InterruptState.isInterrupted { pending.append(mutant.key) } else { aloneQueue.insert((mutant, note), at: 0) } }
                        return false
                    }
                    attempt += 1
                    stoppedRunSeconds = run.0.durationSeconds
                    let first = run.0
                    run = try once()
                    // Stopped by the same limit again: the detail says that the time is that of both runs
                    if (run.0.stoppedBeforeTests == true && first.stoppedBeforeTests == true) || (run.0.stoppedInTest == true && first.stoppedInTest == true),
                       let note = run.0.limitNote {
                        run.0.limitNote = note + String(format: "; stopped twice by this limit (%.1f s and %.1f s)", first.durationSeconds, run.0.durationSeconds)
                    }
                }
                var observation = run.0
                let log = run.log
                stamp(&observation, planned)
                // A run stopped by an interrupt is not a result of the mutant
                if InterruptState.isInterrupted {
                    locked { pending.append(mutant.key) }
                    return false
                }
                let judged = Judgement.classify(observation, baseline: planned.evidence)
                locked { noteRun(worker, passed: judged.status == .survived || judged.status == .notActivated, mutant: mutant, failed: judged.killedBy) }
                if provisional, judged.status == .timeout || (judged.status.isDetected && confirmsSerially) {
                    let why = judged.status == .timeout ? "timed out" : "was detected (\(judged.status.rawValue))"
                    progress("#\(mutant.id) \(why) while \(workers.count) workers were running; it will be run again alone at the end")
                    locked {
                        if judged.status != .timeout { serialConfirmations += 1 }
                        self.provisional.append((mutant, note))
                    }
                    return false
                }
                // Not written to the journal yet: whether this run is the mutant's result is decided further down (do
                // the suites pass by themselves, does a crash repeat, does the whole selection agree), and `--resume`
                // takes the last observation of the journal as the verdict
                stamp(&observation, planned)
                observed.append(observation)
                outcome = RunSession.Evaluation(status: judged.status, killedBy: judged.killedBy, duration: (outcome?.duration ?? 0) + observation.durationSeconds + stoppedRunSeconds,
                                                activated: observation.activated, detail: judged.detail, log: log)
                stoppedRunSeconds = 0
                cleanAtRun = cleanBefore
            } while outcome?.status == .runnerError && tries < 2
            return true
        }
        guard try observe() else { return }
        // A failure of narrowed tests is a detection only if those suites pass by themselves without the mutant. The
        // baseline does not show that: it ran them after everything that the whole selection runs before them.
        // (--confirm-kills none: a failing run counts as it is.)
        if inputs.confirmation != .none, let selected = planned.selected, outcome?.status.isDetected == true, standingAlone(selected) == nil {
            let standing = standsAlone(selected, worker: worker)
            if standing != .alone {
                // Not known yet, or the failure may have had another cause (state left behind, suites that need
                // others): the run is not a result. The mutant is run again, against what `plan` now says.
                locked { if InterruptState.isInterrupted { pending.append(mutant.key) } else { aloneQueue.insert((mutant, note), at: 0) } }
                return
            }
        }
        // --confirm-kills all: a failing run that did not come directly after a passing run without mutants is
        // repeated after one. (With `auto`, the run before it was a mutant whose tests passed.)
        // A Crash is repeated in the same way whenever detections are confirmed: a test host that dies has many causes
        // besides the mutant (another process stopping the app on a shared simulator, a simulator being restarted),
        // crashes are few, and Crash is the one verdict that is given although the number of tests differs.
        let repeatAfterControl: Bool = {
            guard controlsApply, let first = outcome, first.status.isDetected else { return false }
            return (inputs.confirmation == .all && !cleanAtRun) || first.status == .crash
        }()
        if repeatAfterControl, let first = outcome {
            guard ensureClean(worker, scope: scope) else {
                locked { if InterruptState.isInterrupted { pending.append(mutant.key) } else { aloneQueue.insert((mutant, note), at: 0) } }
                return
            }
            guard try observe() else { return }
            locked {
                confirmationRuns += 1
                if let second = outcome {
                    if second.status.isDetected {
                        outcome?.detail = (second.detail.map { $0 + "; " } ?? "") + "confirmed: failed again right after the tests had passed without mutants"
                    } else if second.status == .survived {
                        unconfirmedKills += 1
                        outcome?.detail = "the first run failed (\(first.detail ?? first.status.rawValue)), the run right after the tests had passed without mutants passed: the first failure came from state left by an earlier run"
                        warnings.append(RunWarning(kind: "unconfirmedKill", message: "Mutant #\(mutant.id) (\(mutant.file):\(mutant.start.line)) failed the tests once (\(first.killedBy.prefix(3).joined(separator: ", "))) and passed when run again right after the tests had passed without mutants. It is reported as Survived; the first failure came from state that an earlier run left behind.", key: mutant.key))
                    }
                }
            }
        }
        guard let outcome else { return }
        try locked {
            mutantSeconds += outcome.duration
            aloneCount += 1
            if rechecking.contains(mutant.id) {
                remaining.recheck.add(Date().timeIntervalSince(aloneStart))
            } else {
                remaining.alone.add(Date().timeIntervalSince(aloneStart))
            }
            if outcome.status == .survived, queueRecheck(mutant, selected: planned.selected) { return }
            if outcome.status.isDetected, queueFullConfirmation(mutant, selected: planned.selected) { return }
            // Now the runs are the mutant's result
            for observation in observed { try inputs.journal.record(observation) }
            var outcome = outcome
            if confirmingAgainstAll.contains(mutant.id), planned.selected == nil, outcome.status != .runnerError {
                detectionsRunAgainstAll += 1
                if outcome.status == .survived {
                    detectionsNotConfirmedByAll += 1
                    outcome.detail = "the tests that reach it failed with the mutant, and the whole selection passed: what other tests leave in the process hides the mutant's effect from them (--confirm-kills full)"
                } else if outcome.status.isDetected {
                    outcome.detail = (outcome.detail.map { $0 + "; " } ?? "") + "confirmed by the whole selection"
                }
            }
            if rechecking.contains(mutant.id), planned.selected == nil, outcome.status.isDetected {
                recheckedDetected += 1
                outcome.detail = "passed the tests that reach it and was detected by the whole selection (\(outcome.detail ?? outcome.status.rawValue)): a test leaves the mutant's effect in the process for a test that does not run the mutated code"
            }
            lastRunnerError[worker.index] = outcome.status == .runnerError ? (mutant, note) : nil
            // While shared processes are paused, the runs alone show whether sharing would pay again
            if paused {
                if outcome.status == .killed { self.note(gain: true) }
                if outcome.status == .crash || outcome.status == .timeout { self.note(gain: false) }
            }
            store(mutant, outcome.status, killedBy: outcome.killedBy, duration: outcome.duration, attempts: attempt, detail: outcome.detail,
                  selected: planned.selected, sharedProcess: inputs.shared == nil ? nil : false)
            report(mutant, outcome.status, seconds: outcome.duration,
                   how: (workers.count > 1 && parallelPhase ? "worker \(worker.index + 1)" : "alone") + (note.map { ": \($0)" } ?? ""),
                   plain: inputs.shared == nil && workers.count == 1)
            // Canary: the first mutant run alone must produce a record of being evaluated as active.
            // A timeout or an infrastructure error may have stopped before the tests started, so the next one is used then.
            if !canaryDone, outcome.status != .timeout, outcome.status != .runnerError {
                canaryDone = true
                if outcome.status == .notActivated || !outcome.activated {
                    throw RunError.stage("canary", "mutant #\(mutant.id) was reached in the baseline but no activation was recorded when enabled; TEST_RUNNER_\(inputs.session.names.active) does not seem to reach the test process", log: outcome.log)
                }
            }
        }
    }
}
