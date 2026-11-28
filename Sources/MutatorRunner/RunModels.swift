import CryptoKit
import Foundation
import MutatorCore

/// Kinds of results of running a mutant.
public enum MutantStatus: String, Codable, Sendable, CaseIterable {
    /// A test failed (detected)
    case killed = "Killed"
    /// The test process crashed (detected; recorded separately from Killed)
    case crash = "Crash"
    /// The tests did not finish in time (detected)
    case timeout = "Timeout"
    /// The tests passed (undetected)
    case survived = "Survived"
    /// Not run because the switch was never evaluated in the baseline (undetected)
    case notReached = "NotReached"
    /// Removed because it does not compile (not included in the score)
    case compileError = "CompileError"
    /// The tests passed but there is no record of it being evaluated as active (not included in the score; an anomaly in the tool or the execution infrastructure)
    case notActivated = "NotActivated"
    /// Execution infrastructure error (simulator launch failure, etc.; still failing after one retry; not included in the score)
    case runnerError = "RunnerError"
    /// Accepted as an equivalent mutant (xcmutate.accepted.json) and not detected (not included in the score)
    case accepted = "Accepted"

    public var isDetected: Bool { self == .killed || self == .crash || self == .timeout }
    public var isUndetected: Bool { self == .survived || self == .notReached }
}

/// `--confirm-kills`: when a failing run is taken as the mutant's doing.
///
/// A test can fail because of what an earlier run left behind (a file, a singleton's contents) instead of because
/// of the mutant that is on. The failure of a mutant counts when the same tests passed without mutants right
/// before it; this option says how far the tool goes to have that.
public enum KillConfirmation: String, Codable, Sendable, CaseIterable {
    /// One process per mutant: after a run that did not pass, the tests are run once without mutants before the
    /// next mutant on that destination. Shared process: a failing run that did not come directly after a passing
    /// run of the same tests without mutants is repeated after one. Detected mutants found while several workers
    /// share one destination are run again alone at the end.
    case auto
    /// As `auto`, and: every failing run is repeated right after the tests passed without mutants, whatever ran
    /// before it; detected mutants found while several workers ran are run again alone at the end.
    case all
    /// A failing run counts as it is.
    case none
    /// As `auto`, and: a mutant that its narrowed tests detect (`--select-tests reach`) is run once more against
    /// the whole selection, and only that run decides. What other tests leave in the process can hide a mutant's
    /// effect as well as show it: a run of all tests can pass where the suites that reach the mutant fail by
    /// themselves. Costs one run of all tests per detected mutant.
    case full
    /// As `auto`, except that the run of the tests without mutants after a run that did not pass is replaced by
    /// putting back a copy of the app's containers and the simulator's keychain taken right before the baseline
    /// (`SimulatorRestore`). Where that cannot be done or checked, the tests are run as with `auto`. Not the final
    /// baseline, and not the run of all tests that rechecks a survivor.
    case restore
}

public struct MutantResult: Codable, Sendable {
    public var mutant: Mutant
    public var status: MutantStatus
    /// Identifiers of the failed tests (for Killed / Crash).
    public var killedBy: [String]
    public var durationSeconds: Double?
    public var attempts: Int
    /// Supplementary information (the cause of a RunnerError, the diagnostic of a CompileError, etc.).
    public var detail: String?
    /// `--select-tests reach`: the tests run for this mutant (`-only-testing` identifiers). nil if not narrowed.
    public var selectedTests: [String]?
    /// `--select-tests reach`: the tests that reached this switch in the baseline (`suite/test`; display names as is).
    public var coveredBy: [String]?
    /// `--shared-process`: true if the verdict comes from a process that ran several mutants, false if the mutant was run
    /// in a process of its own. nil when the option was not used.
    public var sharedProcess: Bool?
    /// `--shared-process`: true if the run that decided the verdict was in a process that the tool started itself,
    /// without `xcodebuild` (a survivor confirmed in a new process).
    public var directLaunch: Bool?
    /// With `--select-tests reach`: true if the verdict rests on the tests that reach the mutant alone, and the
    /// mutant was **not run against the whole selection**. Absent when the whole selection decided.
    /// - On a Survived (only with `--no-recheck-survivors`): a test that reads state left by a test that runs the
    ///   mutated code could still detect it.
    /// - On a Killed, Crash or Timeout (the normal case; not with `--confirm-kills full`): the suites that reach
    ///   the mutant failed, in a process of their own or in a shared process. A run of all tests gives the same
    ///   verdict unless another test leaves state that hides the mutant's effect from them.
    public var narrowedOnly: Bool?
    /// True when the verdict comes from a run of all selected tests that was stopped at its first failing test.
    public var stoppedAtFirstFailure: Bool?
    /// `--reuse`: true if the mutant was not run; the Killed of an earlier run was taken over because neither the
    /// product code nor a test that killed it changed. `killedBy` then names those tests.
    public var reused: Bool?
    /// CompileError only: true if the mutant was removed together with every other mutant of its declaration because
    /// the compiler reported an error in the declaration that is not on a mutated line. Such a mutant may well
    /// compile on its own; it was not examined.
    public var collateral: Bool?

    /// Start of the `detail` of a CompileError that removed a whole declaration (`RunSession.analyzeCompileErrors`).
    public static let collateralDetailPrefix = "excluded with the other mutants of "
}

public struct RunWarning: Codable, Sendable {
    public var kind: String
    public var message: String
    public var key: String?
    public var file: String?

    public init(kind: String, message: String, key: String? = nil, file: String? = nil) {
        self.kind = kind
        self.message = message
        self.key = key
        self.file = file
    }
}

public struct RunDurations: Codable, Sendable {
    public var generationSeconds: Double = 0
    public var copySeconds: Double = 0
    public var buildSeconds: Double = 0
    public var buildCount: Int = 0
    public var baselineSeconds: Double = 0
    public var finalBaselineSeconds: Double = 0
    public var mutantSeconds: Double = 0
    public var executedMutants: Int = 0
    public var totalSeconds: Double = 0
    /// Wall-clock time of the mutant phase (with several workers or shared processes it is less than `mutantSeconds`).
    public var mutantPhaseSeconds: Double?
    /// Number of test destinations that ran mutants.
    public var workers: Int?
    /// `--shared-process`: number of processes, their total time, and how the mutants were settled.
    public var sharedProcess: SharedProcessStatistics?
    /// Where the time of the mutant phase and the final baseline went; nil when no mutant was run.
    public var breakdown: Breakdown?

    /// The parts of the mutant phase that are as long as runs of the tests, and what is left. The parts never add up to
    /// more than `totalSeconds` (the wall-clock time of the mutant phase and the final baseline): with several workers,
    /// a part of the mutant phase is its time summed over the workers divided by their number (`workers`).
    public struct Breakdown: Codable, Sendable, Equatable {
        /// The two runs without mutants at the start of shared processes (the processes that made them).
        public var startupRunSeconds: Double
        public var startupRunProcesses: Int
        /// Mutants run by themselves against all selected tests, other than rechecks: by reason, `launch` (a shared
        /// process found the switch evaluated before the tests started), `uneven` (evaluated unequally often in two runs),
        /// `unnarrowed` (the tests that reach it are not known for certain), `selection` (no narrowing asked for).
        public var wholeSelectionSeconds: Double
        public var wholeSelectionMutants: Int
        public var wholeSelectionReasons: [String: Int]
        /// Of those, the ones whose run was stopped at its first failing test (Killed).
        public var wholeSelectionStopped: Int = 0
        /// Mutants run by themselves against their own narrowed tests (after a crash or a hang of a shared process,
        /// for a confirmation, or without shared processes).
        public var ownTestsSeconds: Double
        public var ownTestsMutants: Int
        /// Mutants run against all selected tests because they passed their narrowed tests, or for `--confirm-kills full`.
        public var recheckSeconds: Double
        public var recheckMutants: Int
        /// Runs without mutants between mutants (`durations.confirmation.controlSeconds`).
        public var controlSeconds: Double
        public var finalBaselineSeconds: Double
        /// Shared processes that were lost to a crash or a hang.
        public var lostProcesses: Int
        /// The rest of the mutant phase and the final baseline: mutants inside shared processes, starting processes.
        public var otherSeconds: Double
        public var totalSeconds: Double
        /// Set when several workers ran side by side: the parts of that time are their time summed over the workers,
        /// divided by the time the workers were there for and multiplied by the time they ran side by side (with no
        /// worker dropped: divided by their number). What ran after them, alone, and the final baseline are not divided.
        public var workers: Int?

        private var phaseParts: [Double] { [startupRunSeconds, wholeSelectionSeconds, ownTestsSeconds, recheckSeconds, controlSeconds] }

        /// The breakdown from parts measured as times summed over the workers (`otherSeconds` and `totalSeconds` of
        /// `parts` are not read). `parallel`: the parts as they stood when the workers were done, how long they ran
        /// side by side and the time the workers were there for (workers × that time, less for workers that were
        /// dropped). Those parts become shares of the wall-clock time; the rest of each part is serial and is taken as
        /// measured. Either is scaled down further if it still adds up to more than its time, so that the parts never
        /// add up to more than `totalSeconds`; `otherSeconds` is what is left.
        public static func fitted(_ parts: Breakdown, phaseSeconds: Double, parallel: (parts: Breakdown, seconds: Double, workerSeconds: Double, workers: Int)? = nil) -> Breakdown {
            let phase = max(phaseSeconds, 0)
            let all = parts.phaseParts
            let side = parallel.map { $0.parts.phaseParts } ?? all
            let serial = zip(all, side).map { max($0 - $1, 0) }
            let sideWall = min(parallel.map { max($0.seconds, 0) } ?? phase, phase)
            var sideFactor = parallel.map { $0.workerSeconds > 0 ? sideWall / $0.workerSeconds : 0 } ?? 1
            let sideSum = side.reduce(0, +)
            if sideSum * sideFactor > sideWall, sideSum > 0 { sideFactor = sideWall / sideSum }
            let serialWall = max(phase - sideWall, 0)
            var serialFactor = 1.0
            let serialSum = serial.reduce(0, +)
            if serialSum > serialWall, serialSum > 0 { serialFactor = serialWall / serialSum }
            let values = zip(side, serial).map { $0 * sideFactor + $1 * serialFactor }
            var result = parts
            result.startupRunSeconds = values[0]
            result.wholeSelectionSeconds = values[1]
            result.ownTestsSeconds = values[2]
            result.recheckSeconds = values[3]
            result.controlSeconds = values[4]
            result.workers = (parallel?.workers ?? 1) > 1 ? parallel?.workers : nil
            result.totalSeconds = phase + parts.finalBaselineSeconds
            result.otherSeconds = max(result.totalSeconds - values.reduce(0, +) - parts.finalBaselineSeconds, 0)
            return result
        }

        /// The breakdown in one line, the largest parts first; parts of no time are left out.
        public var line: String {
            func time(_ seconds: Double) -> String {
                let total = Int(seconds.rounded())
                if total >= 3600 { return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))m" }
                if total >= 60 { return "\(total / 60)m\(String(format: "%02d", total % 60))s" }
                return "\(total)s"
            }
            // (Without narrowing, every mutant runs all tests: no reason to give)
            let reasons = wholeSelectionReasons.filter { $0.key != "selection" }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { key, count -> String in
                let words = ["launch": "evaluated before the tests", "uneven": "evaluated unequally often", "unnarrowed": "tests not known", "selection": "no narrowing"][key] ?? key
                return "\(count) \(words)"
            }
            var parts: [(Double, String)] = [
                (startupRunSeconds, "runs without mutants at the start of shared processes \(time(startupRunSeconds)) (\(startupRunProcesses))"),
                (wholeSelectionSeconds, "mutants run alone against all tests \(time(wholeSelectionSeconds)) (\(wholeSelectionMutants)\(reasons.isEmpty ? "" : ": " + reasons.joined(separator: ", "))\(wholeSelectionStopped > 0 ? "; \(wholeSelectionStopped) stopped at the first failing test" : ""))"),
                (ownTestsSeconds, "mutants run alone against their own tests \(time(ownTestsSeconds)) (\(ownTestsMutants)\(lostProcesses > 0 ? "; \(lostProcesses) shared process\(lostProcesses == 1 ? "" : "es") lost to crashes or hangs" : ""))"),
                (recheckSeconds, "rechecks against all tests \(time(recheckSeconds)) (\(recheckMutants))"),
                (controlSeconds, "runs without mutants between mutants \(time(controlSeconds))"),
                (finalBaselineSeconds, "final baseline \(time(finalBaselineSeconds))"),
            ].filter { $0.0 >= 0.5 }
            parts.sort { $0.0 > $1.0 }
            if otherSeconds >= 0.5 { parts.append((otherSeconds, "the rest \(time(otherSeconds)) (mutants in shared processes, starting processes)")) }
            let perWorker = workers.map { " (\($0) workers side by side: their time is divided among them)" } ?? ""
            return "time of the mutant phase and the final baseline \(time(totalSeconds))\(perWorker): " + parts.map(\.1).joined(separator: "; ")
        }
    }

    /// `--shared-process auto`: whether shared processes were used, and the numbers the choice rests on.
    public var sharedProcessChoice: SharedProcessChoice?

    /// What `--confirm-kills` cost: the runs added to tell a mutant's doing from state left by earlier runs.
    public var confirmation: ConfirmationStatistics?

    public struct ConfirmationStatistics: Codable, Sendable {
        public var mode: String
        /// Runs of the tests without mutants between mutants (after a run that did not pass), and their total time.
        public var controlRuns: Int
        public var controlSeconds: Double
        /// Mutants run a second time right after the tests had passed without mutants (`--confirm-kills all`).
        public var repeatedRuns: Int
        /// Of those, the ones that passed the second time (reported as Survived, with an `unconfirmedKill` warning).
        public var notConfirmed: Int
        /// Detected mutants that were run again alone at the end because workers ran side by side.
        public var runAgainAlone: Int
        /// With `--select-tests reach` (unless `--no-recheck-survivors`): mutants that survived the tests that reach them and were run against the whole
        /// selection, and how many of them it detected.
        public var recheckedSurvivors: Int?
        public var recheckedDetected: Int?
        /// `--confirm-kills full`: mutants that their narrowed tests detected and that were run against the whole
        /// selection, and how many of them passed there (reported as Survived).
        public var detectionsRunAgainstAll: Int?
        public var detectionsNotConfirmedByAll: Int?
        /// `--confirm-kills restore`: runs without mutants that putting back the snapshot replaced, and the times it
        /// could not and the tests were run instead (the reasons are in the warning `restoreFellBack`).
        public var restoredStates: Int?
        public var restoreFallbacks: Int?
    }

    /// The choice of `--shared-process auto` (`SharedProcessChoice.decide`).
    public struct SharedProcessChoice: Codable, Sendable, Equatable {
        /// True: the mutants were run in shared processes.
        public var used: Bool
        /// Mutants that were to be run.
        public var mutants: Int
        /// What one launch of the test host costs outside the tests, from the baseline.
        public var launchSeconds: Double
        /// What the tests of the first run without mutants at the start of a shared process take, from the baseline.
        public var startupRunSeconds: Double
        /// The same for the second run, when it runs only the suites of the mutants (`--select-tests reach`).
        public var secondRunSeconds: Double?
        /// Units (test-plan configuration × unit-test target): each needs a start of its own.
        public var units: Int
        /// The choice and its reason in one sentence.
        public var reason: String
    }

    public struct SharedProcessStatistics: Codable, Sendable {
        public var processes: Int
        public var seconds: Double
        /// Killed in a shared process (final).
        public var killed: Int
        /// Passed in a shared process (run again alone unless survivors are trusted).
        public var passed: Int
        /// Mutants run in a process of their own (including the confirmations of `passed`).
        public var alone: Int
        public var trustedSurvivors: Bool
        /// Units (test-plan configuration × test target) that each shared process round covers.
        public var units: Int?
        /// Shared processes started by the tool itself, without `xcodebuild`.
        public var directProcesses: Int?
        /// Mutants that passed in the shared processes and were confirmed in a new process started by the tool
        /// (not counted in `alone`).
        public var confirmedDirectly: Int?
        /// Mutants run alone while shared processes were paused because crashes and hangs outnumbered kills.
        public var pausedAlone: Int?
        /// Shared processes that did not repeat the two runs without mutants of the first process of their unit.
        public var withoutStartupRuns: Int?
        /// Shared processes whose second run without mutants at the start ran only the suites of their mutants
        /// (`--select-tests reach`, unless `--no-narrow-gate`).
        public var narrowedStartupRuns: Int?
        /// Mutants whose tests did not end in time in a shared process, directly after the same tests had passed
        /// there without mutants (Timeout, final).
        public var timedOut: Int?
    }

    public var averageMutantSeconds: Double? {
        // Wall-clock time per mutant when it is known: with shared processes and several workers that is what the run cost
        executedMutants == 0 ? nil : (mutantPhaseSeconds ?? mutantSeconds) / Double(executedMutants)
    }
}

/// The result of one `run`. The JSON report writes this out as is.
public struct RunReport: Codable, Sendable {
    /// 2: (added `tool`, `startedAt`, `finishedAt`, `commit`, `reachedScore`, `fileScores`, `excluded`, `interrupted`)
    public var version = 2
    public var tool = Tool()
    /// Start and end date-times of the run (ISO 8601).
    public var startedAt: String = ""
    public var finishedAt: String = ""
    /// The HEAD commit of the target repository and whether there were uncommitted changes. nil if not under git.
    public var commit: Commit?
    /// Whether the run was cut short by an interrupt (Ctrl-C). When true, `results` contains only what had finished by then.
    public var interrupted = false
    /// true when it was `--time-limit` that cut the run short (then `interrupted` is true as well). Absent otherwise.
    public var timeLimitReached: Bool?
    /// true when `--stop-when-gate-decided` cut the run short because the gates' result could no longer change
    /// (then `interrupted` is true as well, and `pendingKeys` lists what was not run). Absent otherwise.
    public var gateDecidedEarly: Bool?
    /// With `gateDecidedEarly`: how the result was decided ("fails: …" or "passes: …").
    public var gateDecision: String?
    /// The run options that came from the config file: the file, the profile, each key with its value and where it came
    /// from (`config` for its `run` object, `profile <name>`), and the keys that the command line replaced. Absent
    /// when the file gave no run option.
    public var settings: Settings?
    public struct Settings: Codable, Sendable, Equatable {
        public var file: String?
        public var profile: String?
        public var fromFile: [String: Setting]
        public var overriddenByCommandLine: [String]
        public struct Setting: Codable, Sendable, Equatable {
            public var value: String
            public var source: String
            public init(value: String, source: String) {
                self.value = value
                self.source = source
            }
        }
        public init(file: String?, profile: String?, fromFile: [String: Setting], overriddenByCommandLine: [String]) {
            self.file = file
            self.profile = profile
            self.fromFile = fromFile
            self.overriddenByCommandLine = overriddenByCommandLine
        }
    }
    /// `--max-mutants`: present when fewer mutants were examined than the selection holds.
    public var sampling: Sampling?
    /// Stable keys of the mutants not run because of the interrupt or the time limit.
    public var pendingKeys: [String] = []
    /// Number of results carried over from the previous record with `--resume`.
    public var resumedCount = 0
    /// `--reuse`: number of results taken over from earlier runs without running the mutant (all of them Killed), and
    /// when none was, the reason.
    public var reuse: ReuseSummary?

    public struct Sampling: Codable, Sendable {
        /// The value of `--max-mutants`: the number of mutants in `results`.
        public var limit: Int
        /// The number of mutants that the selection (files, `--since`, `--only`) holds.
        public var candidates: Int
        /// Stable keys of the mutants that were left out. A report with a sample can serve as `--baseline-report`
        /// because of this list: what was left out is known not to be known, instead of looking like a mutant that
        /// did not exist.
        public var omittedKeys: [String] = []
    }

    public struct ReuseSummary: Codable, Sendable {
        public var reusedCount: Int
        /// Why nothing was reused (the tool, the options or the product code changed; no earlier results).
        public var refusal: String?
        /// Number of Killed results stored for later runs.
        public var storedCount: Int
    }
    /// Files excluded from the targets (default exclusions and the config's `exclude`). `counts` is the number per reason;
    /// `files` lists those other than test files (with `--since`, only those in the diff).
    public var excluded = Excluded()

    public struct Tool: Codable, Sendable {
        public var name = ToolInfo.name
        public var version = ToolInfo.version
    }

    public struct Commit: Codable, Sendable {
        public var sha: String
        public var dirty: Bool
    }

    public struct Excluded: Codable, Sendable {
        public var counts: [String: Int] = [:]
        public var files: [ExcludedFile] = []
        public init() {}
    }

    /// Per-file totals.
    public struct FileScore: Codable, Sendable {
        public var file: String
        public var detected: Int
        public var survived: Int
        public var notReached: Int
        /// detected / (detected + Survived + NotReached)
        public var score: Double?
        /// detected / (detected + Survived)
        public var reachedScore: Double?
    }

    /// `all` (everything) / `diff` (narrowed with `--since`) / `only` (specified with `--only`)
    public var scope: String
    public var root: String
    public var files: [String]
    public var skippedFiles: [String: String]
    public var baseline: Baseline?
    public var durations: RunDurations
    public var results: [MutantResult]
    public var ignored: [IgnoredMutant]
    public var warnings: [RunWarning]
    /// Which tests were run.
    public var testSelection: TestSelection?
    /// Among the accepted mutants, those that are now detected and those that no longer exist.
    public var acceptance: Acceptance?

    public struct TestSelection: Codable, Sendable {
        /// `auto` (searched for the tests corresponding to the changed files) / `reach` (ran, for each mutant, only the suites of the
        /// tests that reached it in the baseline) / `manual` (--only-testing) / `all`
        public var mode: String
        /// `reach`: the number of mutants run with narrowed tests, and the number run with everything because they could not be narrowed.
        public var narrowedMutants: Int?
        public var unnarrowedMutants: Int?
        /// `reach`: whether a mutant that survived its narrowed tests was run against the whole selection before it was
        /// reported (the default; false with `--no-recheck-survivors`).
        public var recheckSurvivors: Bool?
        /// `reach`: the number of Survived results that rest on the narrowed tests alone (`narrowedOnly` in `results`).
        /// 0 unless `--no-recheck-survivors`.
        public var survivedNarrowedOnly: Int?
        /// `reach`: the number of detected mutants (Killed, Crash, Timeout) whose verdict rests on their narrowed
        /// tests alone (`narrowedOnly` in `results`). 0 with `--confirm-kills full`.
        public var detectedNarrowedOnly: Int?
        /// `reach`: how many of `detectedNarrowedOnly` were detected inside a shared process (`--shared-process`).
        /// There the whole selection had run in the same process before the mutant's narrowed tests, so the state
        /// that the other suites leave was present; the rest were detected by their narrowed tests in a process of
        /// their own, where it was not.
        public var detectedNarrowedOnlyShared: Int?
        /// Whether `auto` found no corresponding tests and fell back to all tests (or --only-testing).
        public var fallback: Bool
        public var onlyTesting: [String]
        /// Tests left out with `--skip-testing`.
        public var skipTesting: [String]?
        public var matches: [TestSelector.Match]
        /// `auto`: the mutated files for which no test file was found (their mutants ran against the tests found for the other files).
        public var unmatchedFiles: [String]?
        /// `impact`: the map's commit, the files changed since, how many suites were chosen (nil: the whole selection
        /// ran), suites that the map did not know, and why the whole selection ran.
        public var impact: Impact?
        public struct Impact: Codable, Sendable {
            public var commit: String
            public var changedFiles: [String]
            public var suites: Int?
            public var newSuites: [String]?
            public var fallbackReasons: [String]?
        }
    }

    public struct Acceptance: Codable, Sendable {
        public var killed: [String]
        public var stale: [String]
    }

    public struct Baseline: Codable, Sendable {
        public var durationSeconds: Double
        public var testCount: Int
        public var passedTests: Int?
        public var skippedTests: Int?
        public var reachedCount: Int
        public var timeoutSeconds: Double
    }

    public var counts: [String: Int] {
        var counts: [String: Int] = [:]
        for r in results { counts[r.status.rawValue, default: 0] += 1 }
        if !ignored.isEmpty { counts["Ignored"] = ignored.count }
        return counts
    }

    /// Overall detection rate: detected / (detected + Survived + NotReached). nil if there are no targets.
    public var score: Double? { Self.score(results, reachedOnly: false) }

    /// Detection rate among reached mutants: detected / (detected + Survived). How effective the asserts are for the code the tests execute.
    /// The difference from `score` is the share of "code the tests do not execute (NotReached)".
    public var reachedScore: Double? { Self.score(results, reachedOnly: true) }

    static func score(_ results: [MutantResult], reachedOnly: Bool) -> Double? {
        let detected = results.filter { $0.status.isDetected }.count
        let undetected = results.filter { reachedOnly ? $0.status == .survived : $0.status.isUndetected }.count
        return detected + undetected == 0 ? nil : Double(detected) / Double(detected + undetected)
    }

    public var fileScores: [FileScore] {
        var order: [String] = []
        var byFile: [String: [MutantResult]] = [:]
        for r in results {
            if byFile[r.mutant.file] == nil { order.append(r.mutant.file) }
            byFile[r.mutant.file, default: []].append(r)
        }
        return order.sorted().map { file in
            let rs = byFile[file] ?? []
            return FileScore(file: file, detected: rs.filter { $0.status.isDetected }.count,
                             survived: rs.filter { $0.status == .survived }.count,
                             notReached: rs.filter { $0.status == .notReached }.count,
                             score: Self.score(rs, reachedOnly: false), reachedScore: Self.score(rs, reachedOnly: true))
        }
    }

    /// Number of excluded candidates per reason.
    public var ignoredByReason: [String: Int] {
        var counts: [String: Int] = [:]
        for i in ignored { counts[i.reason.rawValue, default: 0] += 1 }
        return counts
    }

    /// Number of mutants that could not be evaluated (RunnerError, NotActivated).
    public var unevaluatedCount: Int { results.filter { $0.status == .runnerError || $0.status == .notActivated }.count }

    /// What every report says beside its score when mutants got no verdict: the score is made of the mutants that
    /// were judged, and a run in which the destination stopped working after a few mutants would otherwise show the
    /// score of those few (100 % has been seen, with a fifth of the mutants not run). nil if every mutant was judged.
    public var notRunNote: String? {
        let count = unevaluatedCount
        guard count > 0 else { return nil }
        let runnerErrors = results.filter { $0.status == .runnerError }.count
        let kinds = [runnerErrors > 0 ? "RunnerError \(runnerErrors)" : nil, count > runnerErrors ? "NotActivated \(count - runnerErrors)" : nil].compactMap { $0 }.joined(separator: ", ")
        let dropped = warnings.contains { $0.kind == "workerDropped" } ? "; see the workerDropped warning" : ""
        return "\(count) of \(results.count) mutants could not be run and are not in the score (\(kinds)\(dropped)). The score covers only the mutants that were judged"
    }

    /// Number of mutants removed with their whole declaration because the instrumented declaration did not compile.
    public var collateralCount: Int { results.filter { $0.status == .compileError && $0.collateral == true }.count }

    /// What was asked for and could not be examined, one line per kind; empty if everything was. A gate does not pass
    /// while this is not empty (exit status 7): the run says nothing about these.
    public var unexamined: [String] {
        var lines: [String] = []
        if unevaluatedCount > 0 { lines.append("\(unevaluatedCount) mutants could not be evaluated (RunnerError / NotActivated)") }
        if collateralCount > 0 {
            let declarations = Set(results.filter { $0.status == .compileError && $0.collateral == true }.map { "\($0.mutant.file): \($0.mutant.enclosingDecl)" }).sorted()
            lines.append("\(collateralCount) mutants were removed with their whole declaration because the instrumented declaration does not compile (\(declarations.prefix(3).joined(separator: "; "))\(declarations.count > 3 ? "; …" : ""))")
        }
        if !skippedFiles.isEmpty {
            let files = skippedFiles.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }
            lines.append("\(skippedFiles.count) files could not be mutated: \(files.prefix(5).joined(separator: ", "))\(files.count > 5 ? ", …" : "")")
        }
        if timeLimitReached == true, !pendingKeys.isEmpty { lines.append("\(pendingKeys.count) mutants were not run before the time limit (--time-limit)") }
        let unknownKeys = warnings.filter { $0.kind == "unknownKey" }.count
        if unknownKeys > 0 { lines.append("\(unknownKeys) keys given with --only name no mutant") }
        return lines
    }
}

/// `--max-mutants`: which mutants are examined when there are more than the limit.
public enum MutantSample {
    /// The `limit` keys whose SHA-256 is smallest. The choice depends on nothing but the keys: the same sources give
    /// the same sample on every machine and in every run, and adding or removing a mutant changes the sample by at
    /// most that one mutant and the one it displaces.
    public static func choose(_ keys: [String], limit: Int) -> Set<String> {
        guard limit < keys.count else { return Set(keys) }
        let ordered = keys.map { (hash: SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined(), key: $0) }
            .sorted { ($0.hash, $0.key) < ($1.hash, $1.key) }
        return Set(ordered.prefix(max(limit, 0)).map(\.key))
    }
}
