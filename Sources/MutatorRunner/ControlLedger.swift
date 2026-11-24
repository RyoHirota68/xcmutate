import Foundation

/// The tests that a run without mutants covers, or that a mutant's run needs.
enum ControlScope: Equatable, Sendable {
    /// The whole selection of the run.
    case all
    /// The suites with these `-only-testing` identifiers (sorted, without duplicates).
    case only([String])

    /// The scope of a mutant's run: its narrowed tests (`--select-tests reach`), or the whole selection.
    init(selected: [String]?) {
        if let selected { self = .only(Array(Set(selected)).sorted()) } else { self = .all }
    }

    var identifiers: [String]? {
        if case let .only(identifiers) = self { return identifiers }
        return nil
    }

    func covers(_ other: ControlScope) -> Bool {
        switch (self, other) {
        case (.all, _): true
        case (.only, .all): false
        case let (.only(mine), .only(theirs)): Set(theirs).isSubset(of: mine)
        }
    }
}

/// What is known, on one destination, about the tests passing without mutants (`--confirm-kills`).
///
/// A test can fail because of what an earlier run left on the destination (a file, a database row) instead of
/// because of the mutant that is on. A mutant's failing run is therefore taken as its doing only when **every test
/// of that run has passed without mutants on the destination since the last run there that did not pass**. The
/// ledger keeps track of which tests that holds for.
///
/// Running the whole selection without mutants after every run that did not pass is what this replaces. With a
/// large test suite and tests narrowed per mutant, that one run cost many times what the mutants themselves cost.
/// The ledger makes the same guarantee test by test: before a mutant, only those of its tests are run that have
/// not passed without mutants since the last run that did not pass.
///
/// What the narrower run does not show any more: that a test *outside* the next mutant's tests fails because of
/// what was left. That is found when a mutant with that test comes up (before its run), or at the latest by the
/// run of the whole selection after the last mutant; it never turns into a detection.
struct ControlLedger: Equatable, Sendable {
    /// Every test of the selection has passed without mutants since the last run that did not pass.
    private(set) var verifiedAll = true
    /// While `verifiedAll` is false: the suites that have.
    private(set) var verified: Set<String> = []
    /// The last run on the destination was a passing run without mutants, of these tests.
    private(set) var lastControl: ControlScope? = .all

    /// Nothing is known (a destination whose first run without mutants is still to come).
    static var unknown: ControlLedger {
        var ledger = ControlLedger()
        ledger.runDidNotPass()
        return ledger
    }

    /// The part of `scope` that has not passed without mutants since the last run that did not pass; nil if all of it has.
    func missing(for scope: ControlScope) -> ControlScope? {
        if verifiedAll { return nil }
        switch scope {
        case .all:
            return .all
        case let .only(identifiers):
            let rest = identifiers.filter { !verified.contains($0) }
            return rest.isEmpty ? nil : .only(rest)
        }
    }

    /// Whether a run of `scope` that starts now comes directly after a passing run of the same tests without mutants.
    func isDirectlyAfterControl(of scope: ControlScope) -> Bool {
        lastControl?.covers(scope) ?? false
    }

    /// A run with a mutant, or without, did not pass: whatever it left behind puts every test in doubt.
    mutating func runDidNotPass() {
        verifiedAll = false
        verified = []
        lastControl = nil
    }

    /// A run with a mutant passed.
    mutating func mutantRunPassed() {
        lastControl = nil
    }

    /// The tests of `scope` passed without mutants.
    mutating func controlPassed(_ scope: ControlScope) {
        switch scope {
        case .all:
            verifiedAll = true
            verified = []
        case let .only(identifiers):
            if !verifiedAll { verified.formUnion(identifiers) }
        }
        lastControl = scope
    }
}

/// How long a run may take before it counts as not ending.
///
/// The timeout of a run of the whole selection is the baseline's duration × factor + constant. A mutant whose
/// tests are narrowed runs a small part of that, and when it never ends, the whole of the timeout is waited for:
/// with a baseline of a minute and a half, three minutes per such mutant. The timeout of a narrowed run is
/// therefore taken from the time its own tests took in the baseline, plus what the baseline spent outside the
/// tests (starting `xcodebuild`, installing and launching the host), times the same factor, plus the same constant.
struct TimeoutPolicy: Sendable, Equatable {
    /// Timeout of a run of the whole selection.
    var full: Double
    /// Seconds of the baseline that were not spent in tests.
    var overheadSeconds: Double
    var factor: Double
    var constant: Double
    /// Seconds each suite took in the baseline, by `-only-testing` identifier.
    var suiteSeconds: [String: Double]
    /// Seconds the baseline's `xcodebuild` invocation took until the first test started (its log said so); nil if
    /// the log does not show when tests start (then only the limit of a whole run applies).
    var startupSeconds: Double?
    /// The longest time a single test took in the baseline (from its log); nil if the log does not say.
    var longestTestSeconds: Double?

    /// The limits inside one `xcodebuild` invocation that runs these suites (nil: the whole selection), on top of
    /// `timeout(for:)`. A process that has not started a test after `startupLimit` is stopped: the baseline needed
    /// `startupSeconds` to get there, and a mutant that is evaluated when the host starts (and makes it hang) would
    /// otherwise be waited for as long as a run of every test may take. Once the tests have started, the process
    /// gets the limit of the whole run less what that limit allowed for starting: a host that started in the usual
    /// time is not given the unused allowance on top of its tests.
    func watch(for identifiers: [String]?) -> LogWatch? {
        // Stopping at the first crash needs nothing from the baseline: the line that says so is in the mutant's own log
        guard let startupSeconds else { return LogWatch(stopAtCrash: true) }
        let whole = timeout(for: identifiers)
        let startup = min(whole, startupSeconds * factor + constant)
        let afterStart = max(whole - startupSeconds * factor, constant)
        // One test may take what the slowest test of the baseline took, times the factor, plus the constant: a mutant
        // that makes one test wait forever is then not waited for as long as all the tests together may take
        // A run that this limit stops is repeated once before it is a Timeout, so the limit is used only where two
        // such waits are no longer than the one wait there would be without it (a long selection); elsewhere the
        // limit after the start is the one that applies, as before
        let stall = longestTestSeconds.map { $0 * factor + constant }.flatMap { $0 * 2 <= afterStart ? $0 : nil }
        return LogWatch(startupLimit: startup, afterStart: afterStart, stallLimit: stall, stopAtCrash: true)
    }

    /// Seconds the tests of these suites took in the baseline; nil if one of them is not known.
    func testSeconds(of identifiers: [String]) -> Double? {
        var sum = 0.0
        for identifier in identifiers {
            guard let seconds = suiteSeconds[identifier] else { return nil }
            sum += seconds
        }
        return sum
    }

    /// Timeout of one `xcodebuild` invocation, or one process started by the tool, that runs these suites
    /// (nil: the whole selection).
    func timeout(for identifiers: [String]?) -> Double {
        guard let identifiers, let seconds = testSeconds(of: identifiers) else { return full }
        return min(full, (overheadSeconds + seconds) * factor + constant)
    }

    /// The part of the limit of one run inside a shared process that comes from the suites themselves; the shared
    /// process adds a share of the time of a run of the whole selection (`SharedProcess.runSession`).
    func sessionLimit(for identifiers: [String]?) -> Double? {
        guard let identifiers, let seconds = testSeconds(of: identifiers) else { return nil }
        return seconds * factor + min(constant, 10)
    }

    /// The policy for a run: `baselineSeconds` is the duration of the baseline's `xcodebuild` invocation, `testSeconds`
    /// the sum of the durations of its tests (nil if not known: nothing is narrowed then).
    /// Which of the limits inside a run under `xcodebuild` are not in use, and why; nil if all of them are. (A run
    /// must say so: without them a mutant that hangs the start of the host, or one test, is waited for as long as
    /// the whole run may take, and nothing else shows that.)
    var limitsNotInUse: String? {
        if startupSeconds == nil {
            return "The limit until the first test and the limit for one test are not in use: the baseline's output does not show when its tests start (no line of a suite or test that starts was found in the log of xcodebuild or in the trace of the test process). A mutant that hangs the start of the host, or a single test, is waited for with the limit of the whole run (\(Int(full)) s for a run of every test). Stopping at the first crash of the host is in use."
        }
        return nil
    }

    /// The limits inside a run of every test under `xcodebuild`, in one line.
    var limitsInUse: String? {
        guard let watch = watch(for: nil), let startup = watch.startupLimit else { return nil }
        let oneTest = watch.stallLimit.map { "\(Int($0.rounded())) s per test" }
            ?? "\(Int((watch.afterStart ?? full).rounded())) s for the tests together"
        return "timeouts: \(Int(startup.rounded())) s until the first test starts (baseline: \(String(format: "%.1f", startupSeconds ?? 0)) s); \(oneTest); a host crash stops the run"
    }

    /// The longest time of one test in a log of `xcodebuild` (`passed (0.253 seconds)`, `passed after 0.253 seconds`).
    static func longestTest(inLog log: String) -> Double? {
        var longest: Double?
        for line in log.split(whereSeparator: \.isNewline) {
            var text: Substring?
            if line.hasPrefix("Test Case '"), let range = line.range(of: "' passed (") { text = line[range.upperBound...] }
            if line.hasPrefix("\u{2714} Test "), !line.hasPrefix("\u{2714} Test run"), let range = line.range(of: " passed after ") { text = line[range.upperBound...] }
            guard let text, let seconds = Double(text.prefix { $0.isNumber || $0 == "." }) else { continue }
            longest = max(longest ?? 0, seconds)
        }
        return longest
    }

    static func make(baselineSeconds: Double, suiteSeconds: [String: Double]?, factor: Double, constant: Double, startupSeconds: Double? = nil,
                     longestTestSeconds: Double? = nil) -> TimeoutPolicy {
        let full = baselineSeconds * factor + constant
        // A start that took as long as the whole baseline says nothing
        let startup = startupSeconds.flatMap { $0 < baselineSeconds ? $0 : nil }
        guard let suiteSeconds, !suiteSeconds.isEmpty else {
            return TimeoutPolicy(full: full, overheadSeconds: baselineSeconds, factor: factor, constant: constant, suiteSeconds: [:], startupSeconds: startup,
                                 longestTestSeconds: longestTestSeconds)
        }
        let inTests = suiteSeconds.values.reduce(0, +)
        let overhead = max(baselineSeconds - inTests, 0)
        // If no output of the baseline showed when its tests start, the times come from its result bundle: the host
        // cannot have needed longer until the first test than the baseline spent outside its tests, and no test
        // took longer than the longest suite. (Both are upper bounds, so the limits are looser, never tighter.)
        let fromResults = startup == nil && overhead > 0 && overhead < baselineSeconds
        return TimeoutPolicy(full: full, overheadSeconds: overhead, factor: factor, constant: constant, suiteSeconds: suiteSeconds,
                             startupSeconds: startup ?? (fromResults ? overhead : nil),
                             longestTestSeconds: longestTestSeconds ?? (fromResults ? suiteSeconds.values.max() : nil))
    }
}

/// An estimate of the time a run still needs.
///
/// The simple estimate is "time so far ÷ mutants done × mutants left". With `--shared-process`
/// the mutants that are done first are the cheap ones (killed inside a shared process within a fraction of a second);
/// what is left at the end are the survivors, each of which needs a new process, and the mutants that crash or hang.
/// With a long test run the estimate said "7 minutes" more than an hour before the end.
///
/// This estimate counts what is left by the kind of run it still needs, and uses the average cost of the runs of
/// that kind seen so far. While a kind that is still to come has been seen fewer than three times, its cost is
/// taken from the baseline (a run under `xcodebuild` costs about one baseline run, a new process about what the
/// baseline spent outside the tests), and the estimate is printed as "roughly" instead of "about".
struct RemainingTime: Equatable, Sendable {
    /// Seconds per mutant of the kinds of work, measured in this run (wall-clock time on one worker, with the runs
    /// without mutants and the restarts that the work caused).
    struct Kind: Equatable, Sendable {
        var seconds = 0.0
        var count = 0
        var average: Double? { count > 0 ? seconds / Double(count) : nil }
        mutating func add(_ seconds: Double, count: Int = 1) {
            self.seconds += seconds
            self.count += count
        }
    }

    /// Mutants judged in shared processes (per mutant that went through one).
    var shared = Kind()
    /// Mutants run once more in a new process started by the tool.
    var confirm = Kind()
    /// Mutants run under `xcodebuild`.
    var alone = Kind()
    /// Mutants that had survived their narrowed tests, run against the whole selection.
    var recheck = Kind()
    /// Mutants that were queued for such a run, and mutants that got their verdict without one.
    var rechecksBegun = 0
    var firstVerdicts = 0
    /// Of the mutants that went through a shared process: how many then needed a new process, and how many a run under `xcodebuild`.
    var throughShared = 0
    var sharedThenConfirm = 0
    var sharedThenAlone = 0
    /// Of the mutants run in a new process: how many then needed a run under `xcodebuild`.
    var confirmed = 0
    var confirmThenAlone = 0

    /// What a run under `xcodebuild`, and a new process started by the tool, are taken to cost before any was seen.
    var alonePrior = 0.0
    var confirmPrior = 0.0
    var recheckPrior = 0.0

    /// Number of observations of a kind from which its average is taken as it is.
    static let enough = 3

    struct Estimate: Equatable, Sendable {
        var seconds: Double
        /// False: a kind of run that is still to come has not been seen often enough; its cost is partly a guess.
        var reliable: Bool
    }

    /// - Parameters:
    ///   - waitingShared: mutants that still wait for, or are in, a shared process.
    ///   - waitingConfirm: mutants that wait for a new process.
    ///   - waitingAlone: mutants that wait for a run under `xcodebuild`.
    ///   - waitingRecheck: mutants that survived their narrowed tests and wait for the run against the whole selection.
    ///   - workers: destinations at work.
    func estimate(waitingShared: Int, waitingConfirm: Int, waitingAlone: Int, waitingRecheck: Int = 0, workers: Int) -> Estimate {
        var reliable = true
        /// The average of what was seen; while that is little, the larger of it and the guess made before the run.
        func average(_ kind: Kind, needed: Double, prior: Double = 0) -> Double {
            guard kind.count < Self.enough else { return kind.average ?? 0 }
            if needed > 0 { reliable = false }
            return max(kind.average ?? 0, prior)
        }
        func share(_ part: Int, of whole: Int) -> Double { whole > 0 ? Double(part) / Double(whole) : 0 }
        let fromShared = Double(waitingShared)
        if waitingShared > 0, throughShared < Self.enough { reliable = false }
        let toConfirm = Double(waitingConfirm) + fromShared * share(sharedThenConfirm, of: throughShared)
        let toAlone = Double(waitingAlone) + fromShared * share(sharedThenAlone, of: throughShared) + toConfirm * share(confirmThenAlone, of: confirmed)
        // Of the mutants without a first verdict, the share that has survived its narrowed tests so far will too
        let toRecheck = Double(waitingRecheck)
            + (fromShared + Double(waitingConfirm) + Double(waitingAlone)) * share(rechecksBegun, of: rechecksBegun + firstVerdicts)
        let seconds = fromShared * average(shared, needed: fromShared) + toConfirm * average(confirm, needed: toConfirm, prior: confirmPrior)
            + toAlone * average(alone, needed: toAlone, prior: alonePrior) + toRecheck * average(recheck, needed: toRecheck, prior: recheckPrior)
        return Estimate(seconds: seconds / Double(max(workers, 1)), reliable: reliable)
    }

    static func format(_ estimate: Estimate, formatDuration: (Double) -> String) -> String {
        estimate.reliable ? "about \(formatDuration(estimate.seconds)) left" : "roughly \(formatDuration(estimate.seconds)) left"
    }
}
