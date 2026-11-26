import Foundation
import MutatorCore

/// JSON report (all mutants and their results).
public struct JSONReport: Encodable {
    public var report: RunReport

    public init(report: RunReport) { self.report = report }

    enum CodingKeys: String, CodingKey {
        case version, keyVersion, tool, startedAt, finishedAt, commit, scope, score, reachedScore, unevaluatedCount, counts, fileScores, root, files, skippedFiles,
             excluded, baseline, durations, testSelection, acceptance, interrupted, timeLimitReached, sampling, pendingKeys, resumedCount, reuse,
             results, ignored, ignoredByReason, warnings
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(report.version, forKey: .version)
        try c.encode(MutantKeyScheme.version, forKey: .keyVersion)
        try c.encode(report.tool, forKey: .tool)
        try c.encode(report.startedAt, forKey: .startedAt)
        try c.encode(report.finishedAt, forKey: .finishedAt)
        try c.encode(report.commit, forKey: .commit)
        try c.encode(report.scope, forKey: .scope)
        try c.encode(report.score, forKey: .score)
        try c.encode(report.reachedScore, forKey: .reachedScore)
        // Mutants without a verdict (RunnerError, NotActivated): not in either score. Not 0: the scores are those of the rest
        try c.encode(report.unevaluatedCount, forKey: .unevaluatedCount)
        try c.encode(report.counts, forKey: .counts)
        try c.encode(report.fileScores, forKey: .fileScores)
        try c.encode(report.excluded, forKey: .excluded)
        try c.encode(report.interrupted, forKey: .interrupted)
        try c.encodeIfPresent(report.timeLimitReached, forKey: .timeLimitReached)
        try c.encodeIfPresent(report.sampling, forKey: .sampling)
        try c.encode(report.pendingKeys, forKey: .pendingKeys)
        try c.encode(report.resumedCount, forKey: .resumedCount)
        try c.encodeIfPresent(report.reuse, forKey: .reuse)
        try c.encode(report.ignoredByReason, forKey: .ignoredByReason)
        try c.encode(report.root, forKey: .root)
        try c.encode(report.files, forKey: .files)
        try c.encode(report.skippedFiles, forKey: .skippedFiles)
        try c.encode(report.baseline, forKey: .baseline)
        try c.encode(report.durations, forKey: .durations)
        try c.encodeIfPresent(report.testSelection, forKey: .testSelection)
        try c.encodeIfPresent(report.acceptance, forKey: .acceptance)
        try c.encode(report.results, forKey: .results)
        try c.encode(report.ignored, forKey: .ignored)
        try c.encode(report.warnings, forKey: .warnings)
    }
}

/// Report for AI (coding agents) (modeled on `--reporter agent` of mizchi/mutator).
///
/// Survivors (gaps) are grouped by enclosing function, and the function's source (with line numbers) is included only once per function.
/// Fix hints (`fixes`) are included only once per kind of gap.
public struct AgentReport: Encodable {
    /// 3: (added `reachedScore`, `obligations`, `interrupted`, `pendingCount`; `scopes` lists functions with many unreached mutants first)
    /// 4: (`originalExpression` / `mutatedExpression` only where they say more than `original` / `replacement`;
    /// one scope per function, also for mutants in its local `let`s; written without indentation)
    /// 5: `results` (key and status of every mutant, so that a run with --only can be read from this report alone),
    /// `ignored` and `ignoredCount`; `scope` is `only` for a run with --only (it was `diff`, with `selection: only`)
    public var version = 5
    /// `diff` (--since), `files`, `all`, or `only` (--only)
    public var scope: String
    /// Every mutant of the run with its verdict, in the order of the run.
    public var results: [Verdict]
    /// Candidates that were not made into mutants, with the reason (at most 50; `ignoredCount` is the number of all).
    /// Not listed for a run with --only.
    public var ignored: [IgnoredCandidate]
    public var ignoredCount: Int

    public struct Verdict: Encodable {
        public var key: String
        public var status: String
    }

    public struct IgnoredCandidate: Encodable {
        public var file: String
        public var line: Int
        public var column: Int
        public var mutator: String
        public var original: String
        public var replacement: String
        public var reason: String
    }
    public var score: Double?
    /// Detection rate among reached mutants (detected / (detected + notDetected)).
    public var reachedScore: Double?
    /// Mutants that could not be run (RunnerError, NotActivated). They are in neither score: when this is not 0,
    /// the scores describe only the rest, and the gaps are not complete.
    public var unevaluatedCount: Int
    public var counts: [String: Int]
    /// Whether the run was cut short by an interrupt. When true, the gaps cover only what finished running.
    public var interrupted: Bool
    public var pendingCount: Int
    /// Per operator, "what a test that detects this mutant must distinguish" (only for the operators that appear in gaps).
    public var obligations: [String: String]
    public var testSelection: RunReport.TestSelection?
    public var acceptance: RunReport.Acceptance?
    /// Fix hints per kind of gap (`notDetected` / `notReached`).
    public var fixes: [String: String]
    public var scopes: [Scope]
    public var warnings: [RunWarning]

    public struct Scope: Encodable {
        public var id: String
        public var file: String
        public var startLine: Int
        public var endLine: Int
        /// Source with line numbers (`  12| …`).
        public var source: String
        public var gaps: [Gap]
    }

    public struct Gap: Encodable {
        public var key: String
        /// `notReached` (the tests that ran do not execute this code) / `notDetected` (they execute it, but changing it does not make them fail)
        public var gap: String
        public var line: Int
        public var column: Int
        public var mutator: String
        public var original: String
        public var replacement: String
        /// The whole expression that holds the change, when that is more than `original` (`a > b` for `>`).
        public var originalExpression: String?
        /// The rewritten expression, when that is more than `replacement`. Absent for a removed statement.
        public var mutatedExpression: String?
        /// With `--select-tests reach`: the tests that execute this code (`suite/test`, display names as is; at most 10).
        /// For a `notDetected` gap, strengthen the asserts of the tests listed here or add a test to the same suite.
        public var coveredBy: [String]?
        /// true: the mutant passed the tests that reach it and was not run against the other tests
        /// (`--select-tests reach --no-recheck-survivors`). See `fixes.narrowedOnly`.
        public var narrowedOnly: Bool?
    }

    static let maxScopeLines = 80
    static let context = 40

    public init(report: RunReport) {
        scope = report.scope
        results = report.results.map { Verdict(key: $0.mutant.key, status: $0.status.rawValue) }
        ignoredCount = report.ignored.count
        ignored = report.ignored.prefix(50).map {
            IgnoredCandidate(file: $0.file, line: $0.start.line, column: $0.start.column, mutator: $0.operator.rawValue,
                             original: $0.original, replacement: $0.replacement, reason: $0.reason.rawValue)
        }
        score = report.score
        reachedScore = report.reachedScore
        unevaluatedCount = report.unevaluatedCount
        counts = report.counts
        interrupted = report.interrupted
        pendingCount = report.pendingKeys.count
        testSelection = report.testSelection
        acceptance = report.acceptance

        // When the tests were narrowed, say "among the selected tests" (other tests may reach or detect it)
        let selected: String? = report.testSelection.flatMap { selection in
            let skipped = selection.skipTesting ?? []
            if selection.onlyTesting.isEmpty, skipped.isEmpty { return nil }
            return (selection.onlyTesting.isEmpty ? "all tests" : selection.onlyTesting.joined(separator: ", "))
                + (skipped.isEmpty ? "" : " except " + skipped.joined(separator: ", "))
        }
        let among = selected.map { "Among the selected tests (\($0)), " } ?? ""
        fixes = [
            "notDetected": among + "tests run this code, but none fails when it changes: assert on the observable result that differs (return value, thrown error, state). `obligations[mutator]` says what a test must tell apart for each kind of change. If no input can tell the two versions apart, the mutant is equivalent.",
            "notReached": selected == nil
                ? "No test executes this code: add a test case that reaches it."
                : among + "no test executes this code (other tests were not run): add a test case that reaches it, or check whether another test already covers it.",
        ]

        var lineCache: [String: [Substring]] = [:]
        func lines(_ file: String) -> [Substring] {
            if let cached = lineCache[file] { return cached }
            let text = (try? String(contentsOf: URL(fileURLWithPath: report.root).appendingPathComponent(file), encoding: .utf8)) ?? ""
            let result = text.split(separator: "\n", omittingEmptySubsequences: false)
            lineCache[file] = result
            return result
        }

        var order: [String] = []
        var grouped: [String: Scope] = [:]
        obligations = [:]
        for r in report.results {
            let gap: String
            switch r.status {
            case .survived: gap = "notDetected"
            case .notReached: gap = "notReached"
            default: continue
            }
            let m = r.mutant
            let scopeKey = "\(m.file)|\(m.scope.id)|\(m.scope.lines.start)"
            if grouped[scopeKey] == nil {
                var start = m.scope.lines.start
                var end = m.scope.lines.end
                if end - start > Self.maxScopeLines {
                    start = max(start, m.start.line - Self.context)
                    end = min(end, m.start.line + Self.context)
                }
                let fileLines = lines(m.file)
                // If the file cannot be read or became shorter after the report, the source is not included
                let first = max(1, start)
                let last = min(fileLines.count, max(start, end))
                let numbered = first > last ? "" : (first...last).map { n in
                    "\(String(n).leftPadded(5))| \(fileLines[n - 1])"
                }.joined(separator: "\n")
                grouped[scopeKey] = Scope(id: m.scope.id, file: m.file, startLine: start, endLine: end, source: numbered, gaps: [])
                order.append(scopeKey)
            }
            let mutated = m.operator.removesStatement ? "" : m.mutatedExpression
            // The original text of a mutant that empties a body is the whole function body and overlaps `source`, so it is not included
            let original = m.operator == .emptyBody ? "" : m.originalExpression
            grouped[scopeKey]!.gaps.append(Gap(
                key: m.key, gap: gap, line: m.start.line, column: m.start.column, mutator: m.operator.rawValue,
                original: m.original, replacement: m.replacement,
                // Only where they add something: for most mutants they repeat `original` and `replacement`
                originalExpression: original.isEmpty || original == m.original ? nil : original,
                mutatedExpression: mutated.isEmpty || mutated == m.replacement ? nil : mutated,
                coveredBy: r.coveredBy.map { Array($0.prefix(10)) },
                narrowedOnly: r.narrowedOnly))
            if r.narrowedOnly == true {
                fixes["narrowedOnly"] = ReportText.narrowedOnlyHint
            }
            obligations[m.operator.rawValue] = m.operator.testObligation
        }
        // Functions with nothing reached (no tests) first, then the original order (file and position)
        let unreached = order.filter { grouped[$0]!.gaps.allSatisfy { $0.gap == "notReached" } }
        let rest = order.filter { !unreached.contains($0) }
        scopes = (unreached + rest).map { grouped[$0]! }
        // Hints only for the kinds of gap that the report holds (none when every mutant was detected)
        let kinds = Set(scopes.flatMap(\.gaps).map(\.gap))
        fixes = fixes.filter { kinds.contains($0.key) || $0.key == "narrowedOnly" }

        var warnings = report.warnings
        let errors = report.results.filter { $0.status == .runnerError || $0.status == .notActivated }
        if !errors.isEmpty {
            warnings.append(RunWarning(kind: "runnerError", message: "\(errors.count) mutants could not be evaluated (RunnerError / NotActivated); they are not counted in the score"))
        }
        // Files that could not be mutated are among `report.warnings` (kind `skippedFile`)
        self.warnings = warnings
    }

    /// All gaps (the per-function groups flattened).
    public var gaps: [Gap] { scopes.flatMap(\.gaps) }
}

extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}

/// Summary for humans.
public enum TextReport {
    public static func render(_ report: RunReport) -> String {
        var out: [String] = []
        let counts = report.counts
        let order = ["Killed", "Crash", "Timeout", "Survived", "NotReached", "Accepted", "CompileError", "NotActivated", "RunnerError", "Ignored"]
        out.append("\(ToolInfo.name) \(report.tool.version): \(report.results.count) mutant\(report.results.count == 1 ? "" : "s") (scope: \(report.scope))" + (report.interrupted ? " — \(report.timeLimitReached == true ? "TIME LIMIT REACHED" : "INTERRUPTED"), \(report.pendingKeys.count) not run" : ""))
        if let sampling = report.sampling {
            out.append("  sample: \(sampling.limit) of \(sampling.candidates) mutants, chosen by their stable keys (--max-mutants); the others were not examined")
        }
        let countText = order.compactMap { key in counts[key].map { "\(key) \($0)" } }.joined(separator: ", ")
        out.append("  " + (countText.isEmpty ? "(no mutants)" : countText))
        if let score = report.score {
            out.append(String(format: "  mutation score: %.1f%% (detected / (detected + survived + not reached))", score * 100))
        }
        if let reached = report.reachedScore {
            out.append(String(format: "  among reached:  %.1f%% (detected / (detected + survived))", reached * 100))
        }
        if let note = report.notRunNote { out.append("  INCOMPLETE: \(note)") }
        let d = report.durations
        var timing = String(format: "  time: total %.0fs, build %.0fs (%d build%@)", d.totalSeconds, d.buildSeconds, d.buildCount, d.buildCount == 1 ? "" : "s")
        timing += String(format: ", baseline %.1fs", d.baselineSeconds)
        if let avg = d.averageMutantSeconds { timing += String(format: ", %.1fs per mutant (%d run)", avg, d.executedMutants) }
        if let workers = d.workers, workers > 1 { timing += ", \(workers) workers" }
        out.append(timing)
        // One line per thing (they were all on the line of the times)
        if let choice = d.sharedProcessChoice { out.append("  --shared-process auto: \(choice.reason)") }
        if let shared = d.sharedProcess {
            var line = "  shared processes: \(shared.processes); \(shared.killed) mutant\(shared.killed == 1 ? "" : "s") killed there, \(shared.passed) passed there\(shared.trustedSurvivors ? " (not confirmed alone)" : ""), \(shared.alone) run\(shared.alone == 1 ? "" : "s") alone"
            if let confirmed = shared.confirmedDirectly, confirmed > 0 { line += ", \(confirmed) survivors confirmed in a new process started by the tool" }
            if let narrowed = shared.narrowedStartupRuns, narrowed > 0 { line += "; in \(narrowed) of the processes, the second run without mutants at the start ran only the suites that their mutants reach" }
            out.append(line)
        }
        if report.resumedCount > 0 { out.append("  resumed: \(report.resumedCount) results taken from the run that was continued") }
        if let reuse = report.reuse {
            out.append(reuse.reusedCount > 0 ? "  reused: \(reuse.reusedCount) Killed results from earlier runs" : "  reused: nothing (\(reuse.refusal ?? "no stored result applies"))")
        }
        if let selection = report.testSelection {
            var tests = selection.onlyTesting.isEmpty ? "all tests" : selection.onlyTesting.joined(separator: ", ")
            if let skipped = selection.skipTesting, !skipped.isEmpty { tests += " except " + skipped.joined(separator: ", ") }
            // "tests (all): all tests" said the same thing twice and left the parenthesis unexplained
            let how: String
            switch selection.mode {
            case "all": how = ""
            case "manual": how = " (--only-testing / --skip-testing)"
            case "reach": how = " (--select-tests reach: each mutant is run against the suites of these that reach it)"
            default: how = " (chosen by --select-tests \(selection.mode)\(selection.fallback ? ", which fell back to these" : ""))"
            }
            out.append("  tests run: \(tests)\(how)")
            if let detected = selection.detectedNarrowedOnly, detected > 0 {
                // Said as what the detections rest on, not as a defect of the run: with narrowed tests this is the
                // normal case (most detections of a run with shared processes are of this kind)
                let total = report.results.filter { $0.status.isDetected }.count
                let shared = selection.detectedNarrowedOnlyShared ?? 0
                var where_ = ""
                if shared > 0 {
                    where_ = shared == detected ? ", all inside shared processes (the other suites had run in the same process before)"
                        : ": \(shared) inside shared processes (the other suites had run in the same process before), \(detected - shared) in a process of their own"
                }
                out.append("  of the \(total) detected, \(detected) rest on the tests that reach the mutant\(where_); --confirm-kills full runs them against all tests as well")
            }
            if let narrowedOnly = selection.survivedNarrowedOnly, narrowedOnly > 0 {
                out.append("  \(narrowedOnly) of the Survived passed only the tests that reach them and were not run against all tests (--no-recheck-survivors)")
            }
        }
        // Test files are never mutated, and a change usually touches some: said only together with files that were
        // left out for another reason (a changed product file that is left out is also a warning)
        if !report.excluded.counts.isEmpty, report.excluded.counts.keys.contains(where: { $0 != "test-code" }) {
            let text = report.excluded.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            out.append("  files not mutated: \(text)")
            for file in report.excluded.files.prefix(20) {
                out.append("    \(file.file) (\(file.reason)\(file.detail.map { ": \($0)" } ?? ""))")
            }
            if report.excluded.files.count > 20 { out.append("    … \(report.excluded.files.count - 20) more (see the JSON report)") }
        }

        let scores = report.fileScores
        if scores.count > 1 {
            out.append("")
            out.append("Per file (score, among reached):")
            for f in scores {
                func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "-" }
                out.append("  \(percent(f.score).leftPadded(4)) \(percent(f.reachedScore).leftPadded(4))  \(f.file) (detected \(f.detected), survived \(f.survived), not reached \(f.notReached))")
            }
        }

        let survivors = report.results.filter { $0.status.isUndetected }
        if !survivors.isEmpty {
            out.append("")
            let selected = report.testSelection.map { !$0.onlyTesting.isEmpty || !($0.skipTesting ?? []).isEmpty } ?? false
            out.append(selected ? "Survived / not reached (among the selected tests only):" : "Survived / not reached:")
            for r in survivors {
                let m = r.mutant
                out.append("  \(m.file):\(m.start.line):\(m.start.column) [\(r.status.rawValue)\(r.narrowedOnly == true ? ", not run against all tests" : "")] \(m.operator.rawValue) \(ReportText.change(m))  (\(m.enclosingDecl))")
                out.append("    key: \(m.key)")
            }
        }
        let problems = report.results.filter { [.compileError, .notActivated, .runnerError].contains($0.status) }
        if !problems.isEmpty {
            out.append("")
            out.append("Not evaluated:")
            for r in problems {
                out.append("  \(r.mutant.file):\(r.mutant.start.line) [\(r.status.rawValue)] \(r.mutant.operator.rawValue) \(r.detail ?? "")")
            }
        }
        if !report.warnings.isEmpty {
            out.append("")
            out.append("Warnings:")
            for w in report.warnings { out.append("  [\(w.kind)] \(ReportText.warning(w))") }
        }
        return out.joined(separator: "\n")
    }
}

enum ReportText {
    /// What a Survived that rests on narrowed tests alone means, for the reports that explain.
    static let narrowedOnlyHint = "This mutant passed the tests that reach it and was not run against the other tests (--no-recheck-survivors). A test that does not run this code but reads state that such a test leaves behind may already detect it: before writing a test, run again without --no-recheck-survivors (or run all tests with the change applied by hand)."

    /// A warning in one line, with the key or the file it is about when the message does not already name it.
    static func warning(_ warning: RunWarning) -> String {
        var text = warning.message
        if let key = warning.key, !text.contains(key) { text += " [\(key)]" }
        if let file = warning.file, !text.contains(file) { text += " (\(file))" }
        return text
    }

    /// The rewrite in one line.
    static func change(_ m: Mutant) -> String {
        switch m.operator {
        case .sideEffectRemoval, .closureStatementRemoval: "remove `\(oneLine(m.original))`"
        case .emptyBody: "empty the \(m.original)"
        case .switchCaseRemoval: "remove `\(oneLine(m.original))` (falls to default)"
        default: "`\(oneLine(m.original))` -> `\(oneLine(m.replacement))`"
        }
    }

    static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return collapsed.count > 120 ? String(collapsed.prefix(117)) + "..." : collapsed
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
    }
}

/// A format that Xcode can show as warnings (`<absolute path>:<line>:<column>: warning: …`).
/// Calling `xcmutate run … --reporter xcode` from an Xcode Run Script build phase shows the survivors on the corresponding lines.
public enum XcodeReport {
    public static func render(_ report: RunReport) -> String {
        var lines: [String] = []
        let root = URL(fileURLWithPath: report.root)
        for r in report.results where r.status.isUndetected {
            let m = r.mutant
            let what = r.status == .notReached ? "no test executes this code"
                : (r.narrowedOnly == true ? "no test that reaches this code fails (not run against all tests: --no-recheck-survivors)" : "no test fails")
            lines.append("\(root.appendingPathComponent(m.file).path):\(m.start.line):\(m.start.column): warning: mutant \(r.status == .notReached ? "not reached" : "survived"): \(m.operator.rawValue) \(ReportText.change(m)) — \(what) [\(m.key)]")
        }
        for r in report.results where r.status == .runnerError || r.status == .notActivated {
            let m = r.mutant
            lines.append("\(root.appendingPathComponent(m.file).path):\(m.start.line):\(m.start.column): warning: mutant not evaluated (\(r.status.rawValue)): \(ReportText.oneLine(r.detail ?? ""))")
        }
        if let note = report.notRunNote { lines.append("warning: \(ToolInfo.name): \(note)") }
        return lines.joined(separator: "\n")
    }
}

/// Annotations for GitHub Actions: one workflow command per undetected mutant, which GitHub shows on the line of the
/// file in the pull request (`::warning file=…,line=…,col=…,title=…::message`).
///
/// GitHub shows at most ten warnings per step, so no more are written; a notice says how many were left out.
/// Survived comes before NotReached: a test that runs the code and checks nothing is the more specific finding.
public enum GitHubReport {
    public static let maxAnnotations = 10

    /// - Parameter workspace: the directory that GitHub's paths are relative to (`GITHUB_WORKSPACE`); nil: the root of the run.
    public static func render(_ report: RunReport, workspace: String?) -> String {
        var lines: [String] = []
        let root = URL(fileURLWithPath: report.root).resolvingSymlinksInPath().path
        let base = workspace.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        func path(_ file: String) -> String {
            let absolute = root + "/" + file
            if let base, absolute.hasPrefix(base + "/") { return String(absolute.dropFirst(base.count + 1)) }
            return file
        }
        let undetected = report.results.filter { $0.status == .survived } + report.results.filter { $0.status == .notReached }
        // First, and within the ten that GitHub shows: an annotation list without it would read as "nothing found"
        var maxAnnotations = maxAnnotations
        if let note = report.notRunNote {
            lines.append("::warning title=\(property("\(ToolInfo.name): incomplete"))::" + data(note + "."))
            maxAnnotations -= 1
        }
        for r in undetected.prefix(maxAnnotations) {
            let m = r.mutant
            let what: String
            switch (r.status, r.narrowedOnly == true) {
            case (.notReached, _): what = "no test executes this code"
            case (_, true): what = "no test that reaches this code fails with this change (not run against all tests: --no-recheck-survivors)"
            default: what = "no test fails with this change"
            }
            let title = "Mutant \(r.status == .notReached ? "not reached" : "survived"): \(m.operator.rawValue)"
            lines.append("::warning file=\(property(path(m.file))),line=\(m.start.line),col=\(m.start.column),title=\(property(title))::"
                + data("\(ReportText.change(m)): \(what). Key: \(m.key)"))
        }
        if undetected.count > maxAnnotations {
            lines.append("::notice title=\(property(ToolInfo.name))::" + data("\(undetected.count - maxAnnotations) more undetected mutants are not shown as annotations (GitHub shows \(maxAnnotations) per step). The Markdown and JSON reports list all \(undetected.count)."))
        }
        if undetected.isEmpty, !report.interrupted {
            // Without it the output is empty, which does not tell a run that found nothing from one that did not write
            let detected = report.results.filter { $0.status.isDetected }.count
            lines.append("::notice title=\(property(ToolInfo.name))::" + data(report.results.isEmpty
                ? "No mutants were run."
                : "No undetected mutants: \(detected) of \(report.results.count) mutants were detected" + (detected < report.results.count ? "; the others have no verdict or were accepted (see the text or JSON report)." : ".")))
        }
        if report.interrupted {
            lines.append("::notice title=\(property(ToolInfo.name))::" + data("\(report.timeLimitReached == true ? "The time limit was reached" : "The run was interrupted"): \(report.pendingKeys.count) mutants were not run."))
        }
        return lines.joined(separator: "\n")
    }

    /// The value of a property of a workflow command (`file=`, `title=`).
    static func property(_ text: String) -> String {
        data(text).replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: ",", with: "%2C")
    }

    /// The message of a workflow command.
    static func data(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
    }
}

/// Markdown summary (for the GitHub job summary `$GITHUB_STEP_SUMMARY` or PR comments).
public enum MarkdownReport {
    static let maxListed = 100

    public static func render(_ report: RunReport) -> String {
        var out: [String] = []
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
        out.append("## Mutation testing (\(ToolInfo.name) \(report.tool.version))")
        out.append("")
        if report.interrupted {
            out.append("> **\(report.timeLimitReached == true ? "Time limit reached" : "Interrupted")**: \(report.pendingKeys.count) mutants were not run. The numbers below cover only the mutants that finished.")
            out.append("")
        }
        if let sampling = report.sampling {
            out.append("> **Sample**: \(sampling.limit) of \(sampling.candidates) mutants were examined, chosen by their stable keys (`--max-mutants`). The numbers below are those of the sample.")
            out.append("")
        }
        if let note = report.notRunNote {
            out.append("> **Incomplete**: \(note); they are listed under \"Not evaluated\" below.")
            out.append("")
        }
        let counts = report.counts
        let commit = report.commit.map { " at `\($0.sha.prefix(10))`\($0.dirty ? " (with uncommitted changes)" : "")" } ?? ""
        out.append("\(report.results.count) mutants (scope: \(report.scope))\(commit), \(report.startedAt) – \(report.finishedAt)")
        out.append("")
        out.append("| Score (all) | Score (among reached) | Killed | Crash | Timeout | Survived | Not reached | Accepted | Compile error | Not evaluated |")
        out.append("|---|---|---|---|---|---|---|---|---|---|")
        out.append("| **\(ReportText.percent(report.score))** | \(ReportText.percent(report.reachedScore)) | \(counts["Killed"] ?? 0) | \(counts["Crash"] ?? 0) | \(counts["Timeout"] ?? 0) | \(counts["Survived"] ?? 0) | \(counts["NotReached"] ?? 0) | \(counts["Accepted"] ?? 0) | \(counts["CompileError"] ?? 0) | \(report.unevaluatedCount) |")
        out.append("")
        out.append("Score (all) = detected / (detected + survived + not reached). Score (among reached) = detected / (detected + survived).")

        let scores = report.fileScores
        if !scores.isEmpty {
            out.append("")
            out.append("### Per file")
            out.append("")
            out.append("| File | Score (all) | Score (among reached) | Detected | Survived | Not reached |")
            out.append("|---|---|---|---|---|---|")
            for f in scores {
                out.append("| `\(cell(f.file))` | \(ReportText.percent(f.score)) | \(ReportText.percent(f.reachedScore)) | \(f.detected) | \(f.survived) | \(f.notReached) |")
            }
        }

        let survivors = report.results.filter { $0.status.isUndetected }
        if !survivors.isEmpty {
            out.append("")
            out.append("### Survived / not reached (\(survivors.count))")
            out.append("")
            out.append("| Location | Result | Operator | Change | Key |")
            out.append("|---|---|---|---|---|")
            for r in survivors.prefix(maxListed) {
                let m = r.mutant
                out.append("| `\(cell(m.file)):\(m.start.line):\(m.start.column)` | \(r.status.rawValue)\(r.narrowedOnly == true ? " (not run against all tests)" : "") | \(m.operator.rawValue) | \(cell(ReportText.change(m))) | `\(cell(m.key))` |")
            }
            if survivors.count > maxListed { out.append("\n… \(survivors.count - maxListed) more (see the JSON report)") }
            let narrowedOnly = survivors.filter { $0.narrowedOnly == true }.count
            if narrowedOnly > 0 {
                out.append("")
                out.append("\(narrowedOnly) of the Survived are marked \"not run against all tests\": they passed the tests that reach them, and the other tests were not run (`--no-recheck-survivors`). A test that reads state left by another test could still detect them.")
            }
        }
        let notEvaluated = report.results.filter { $0.status == .runnerError || $0.status == .notActivated }
        if !notEvaluated.isEmpty {
            out.append("")
            out.append("### Not evaluated")
            out.append("")
            out.append("These mutants got no verdict and are in neither score.")
            out.append("")
            out.append("| Location | Status | Operator | Why |")
            out.append("|---|---|---|---|")
            for r in notEvaluated.prefix(maxListed) {
                out.append("| `\(cell(r.mutant.file)):\(r.mutant.start.line):\(r.mutant.start.column)` | \(r.status.rawValue) | \(r.mutant.operator.rawValue) | \(cell(ReportText.oneLine(r.detail ?? ""))) |")
            }
            if notEvaluated.count > maxListed { out.append("\n… \(notEvaluated.count - maxListed) more (see the JSON report)") }
        }
        if !report.warnings.isEmpty {
            out.append("")
            out.append("### Warnings")
            out.append("")
            for w in report.warnings { out.append("- `\(w.kind)`: \(w.message)") }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// Output in the JSON schema of mutation-testing-elements (Stryker) (mutation-testing-report-schema 2).
/// This JSON can be passed as is to the display component (HTML) that reads the same schema, or to the Stryker Dashboard.
///
/// Status mapping: Killed, Crash → `Killed` (Crash is noted in `statusReason`), Timeout → `Timeout`, Survived → `Survived`,
/// NotReached → `NoCoverage`, CompileError → `CompileError`, RunnerError and NotActivated → `RuntimeError` (mutants that could
/// not be run), Accepted and excluded candidates → `Ignored`
/// (not counted in the score; the reason is in `statusReason`), those not run because of an interrupt → `Pending`.
public struct StrykerReport: Encodable {
    public struct Position: Encodable { public var line: Int; public var column: Int }
    public struct Location: Encodable { public var start: Position; public var end: Position }
    public struct MutantEntry: Encodable {
        public var id: String
        public var mutatorName: String
        public var replacement: String
        public var description: String
        public var location: Location
        public var status: String
        public var statusReason: String?
        public var killedBy: [String]?
        public var duration: Int?
    }
    public struct FileEntry: Encodable {
        public var language = "swift"
        public var source: String
        public var mutants: [MutantEntry]
    }
    public struct TestEntry: Encodable { public var id: String; public var name: String }
    public struct TestFile: Encodable { public var tests: [TestEntry] }
    public struct Framework: Encodable { public var name: String; public var version: String }
    public struct Thresholds: Encodable { public var high = 80; public var low = 60 }

    public var schemaVersion = "2"
    public var thresholds = Thresholds()
    public var projectRoot: String
    public var files: [String: FileEntry]
    public var testFiles: [String: TestFile]
    public var framework = Framework(name: ToolInfo.name, version: ToolInfo.version)

    public init(report: RunReport, readSource: (String) -> String? = { _ in nil }) {
        projectRoot = report.root
        var files: [String: FileEntry] = [:]
        var tests: Set<String> = []
        let root = URL(fileURLWithPath: report.root)
        var sources: [String: String] = [:]
        func source(_ file: String) -> String {
            if let cached = sources[file] { return cached }
            let text = readSource(file) ?? (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
            sources[file] = text
            return text
        }
        var lineCache: [String: [Substring]] = [:]
        func lines(_ file: String) -> [Substring] {
            if let cached = lineCache[file] { return cached }
            let result = source(file).split(separator: "\n", omittingEmptySubsequences: false)
            lineCache[file] = result
            return result
        }
        /// Report columns are in UTF-8 bytes. Schema columns are in characters (UTF-16), so convert them.
        func position(_ file: String, _ p: SourcePosition) -> Position {
            let fileLines = lines(file)
            guard p.line >= 1, p.line <= fileLines.count else { return Position(line: max(1, p.line), column: max(1, p.column)) }
            let prefix = fileLines[p.line - 1].utf8.prefix(max(0, p.column - 1))
            return Position(line: p.line, column: String(decoding: prefix, as: UTF8.self).utf16.count + 1)
        }
        func add(_ file: String, _ entry: MutantEntry) {
            if files[file] == nil { files[file] = FileEntry(source: source(file), mutants: []) }
            files[file]!.mutants.append(entry)
        }
        for r in report.results {
            let m = r.mutant
            var status: String
            var reason = r.detail
            switch r.status {
            case .killed: status = "Killed"
            case .crash: status = "Killed"; reason = "crash: " + (r.detail ?? "")
            case .timeout: status = "Timeout"
            case .survived:
                status = "Survived"
                if r.narrowedOnly == true { reason = "passed the tests that reach it; not run against all tests (--no-recheck-survivors)" }
            case .notReached: status = "NoCoverage"
            case .compileError: status = "CompileError"
            case .accepted: status = "Ignored"; reason = "accepted as equivalent (\(AcceptedFile.defaultName))"
            // RuntimeError, not Ignored: the display lists these apart from what was left out on purpose
            case .notActivated, .runnerError: status = "RuntimeError"; reason = "\(r.status.rawValue) (not run; not in the score): " + (r.detail ?? "")
            }
            tests.formUnion(r.killedBy)
            add(m.file, MutantEntry(
                id: m.key, mutatorName: m.operator.rawValue,
                replacement: m.operator.removesStatement ? "" : m.mutatedExpression,
                description: ReportText.change(m),
                location: Location(start: position(m.file, m.start), end: position(m.file, m.end)),
                status: status, statusReason: reason, killedBy: r.killedBy.isEmpty ? nil : r.killedBy,
                duration: r.durationSeconds.map { Int($0 * 1000) }))
        }
        let done = Set(report.results.map(\.mutant.key))
        for key in report.pendingKeys where !done.contains(key) {
            // Not run because of an interrupt: the position cannot be known from the key, so place it at the top of the file
            let file = key.components(separatedBy: "::").first ?? ""
            add(file, MutantEntry(id: key, mutatorName: key.components(separatedBy: "::").dropFirst(2).first ?? "", replacement: "",
                                  description: "not run (interrupted)",
                                  location: Location(start: Position(line: 1, column: 1), end: Position(line: 1, column: 1)),
                                  status: "Pending", statusReason: "the run was interrupted", killedBy: nil, duration: nil))
        }
        for (index, i) in report.ignored.enumerated() {
            let start = position(i.file, i.start)
            add(i.file, MutantEntry(id: "ignored-\(index)", mutatorName: i.operator.rawValue, replacement: i.replacement,
                                    description: "`\(ReportText.oneLine(i.original))` -> `\(ReportText.oneLine(i.replacement))`",
                                    location: Location(start: start, end: Position(line: start.line, column: start.column + max(1, i.original.utf16.count))),
                                    status: "Ignored", statusReason: "not generated: \(i.reason.rawValue)", killedBy: nil, duration: nil))
        }
        self.files = files
        testFiles = tests.isEmpty ? [:] : ["tests": TestFile(tests: tests.sorted().map { TestEntry(id: $0, name: $0) })]
    }

    public func json(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// A report in a single HTML file. The JSON of `StrykerReport` is passed to the display component (web component) of
/// mutation-testing-elements. The component is loaded from a CDN (network access is needed when opening the file).
public enum HTMLReport {
    /// The version of the display component that the report loads. Fixed, and checked by the browser against
    /// `elementsIntegrity`: the page holds the source code of the project, and a script that the CDN served in place
    /// of this file could read it.
    public static let elementsVersion = "3.9.0"
    /// Where the display component is distributed from.
    public static let elementsURL = "https://www.unpkg.com/mutation-testing-elements@\(elementsVersion)/dist/mutation-test-elements.js"
    /// Subresource Integrity value of that file (SHA-384 of the bytes that unpkg served for the version on 2026-11-22).
    /// When the version is raised: `curl -sL <elementsURL> | openssl dgst -sha384 -binary | openssl base64 -A`.
    public static let elementsIntegrity = "sha384-/dXYuoYRvO6rJ0FNtdKR+Hmq5iGrkkSDpc/TGgbSoReog26ZqhLhpSt4l+0Wwew2"

    public static func render(_ report: RunReport) throws -> String {
        // Escape `<` so that a `</script>` or the start of an HTML comment appearing inside the JSON does not break the page
        let json = String(decoding: try StrykerReport(report: report).json(pretty: false), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
        var title = "\(ToolInfo.name) \(report.tool.version) — \(report.startedAt)"
        // In the title of the page, which the display shows above its score
        if report.unevaluatedCount > 0 { title += " — INCOMPLETE: \(report.unevaluatedCount) of \(report.results.count) mutants could not be run and are not in the score" }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <script src="\(elementsURL)" integrity="\(elementsIntegrity)" crossorigin="anonymous"></script>
        </head>
        <body>
        <mutation-test-report-app title-postfix="\(title)">
        This report needs JavaScript and network access to \(elementsURL).
        </mutation-test-report-app>
        <script>
        document.querySelector('mutation-test-report-app').report = \(json);
        </script>
        </body>
        </html>

        """
    }
}

/// The gate that decides the exit code (threshold, survivors, comparison with an earlier report).
public struct Gate: Sendable {
    /// Fails if the overall detection rate (percentage) is below this.
    public var failUnder: Double?
    /// Fails if there is even one undetected mutant (Survived, NotReached; accepted ones are excluded).
    public var failOnSurvived = false
    /// Stable keys of the mutants that were undetected in an earlier report. Fails if there is an "undetected mutant" not among them.
    public var earlierUndetected: Set<String>?
    /// The files that the earlier report examined; nil: not known, every file counts as examined.
    public var earlierFiles: Set<String>?
    /// Files that the earlier run did not examine **although they existed then** (its run was limited to other
    /// files). What is undetected in them is not known to the earlier report and is not counted as new. A file that
    /// is not in this set and not in `earlierFiles` is new, or cannot be shown to have existed: its undetected
    /// mutants are new gaps. (When in doubt the gate fails; a gate that passes for code that nobody examined
    /// would be the worse mistake.)
    public var filesLeftOutThen: Set<String> = []
    /// Files outside the earlier report of which it cannot be found out whether they existed then (the earlier
    /// report's commit is not in this clone), and why. Their undetected mutants are neither counted as new nor
    /// passed over: when nothing else fails, the gate cannot be confirmed (exit code 7).
    public var undeterminedFiles: Set<String> = []
    public var undeterminedReason: String?

    /// Undetected mutants that are not counted as new because the earlier run left their file out.
    public func outsideEarlierFiles(_ report: RunReport) -> [MutantResult] {
        guard earlierUndetected != nil, let earlierFiles else { return [] }
        return report.results.filter { $0.status.isUndetected && !earlierFiles.contains($0.mutant.file) && filesLeftOutThen.contains($0.mutant.file) }
    }

    /// The files of this report that the earlier report did not examine: the caller finds out which of them existed then.
    public func filesOutsideEarlier(_ report: RunReport) -> [String] {
        guard earlierUndetected != nil, let earlierFiles else { return [] }
        return Array(Set(report.results.filter { $0.status.isUndetected }.map(\.mutant.file)).subtracting(earlierFiles)).sorted()
    }

    public init(failUnder: Double? = nil, failOnSurvived: Bool = false, earlierUndetected: Set<String>? = nil) {
        self.failUnder = failUnder
        self.failOnSurvived = failOnSurvived
        self.earlierUndetected = earlierUndetected
    }

    public var isRequested: Bool { failUnder != nil || failOnSurvived || earlierUndetected != nil }

    public struct Failure: Sendable, Equatable {
        public var exitCode: Int32
        public var message: String
    }

    /// The failed gates (in ascending order of exit code). Empty means passed.
    public func evaluate(_ report: RunReport) -> [Failure] {
        var failures: [Failure] = []
        let undetected = report.results.filter { $0.status.isUndetected }
        if failOnSurvived, !undetected.isEmpty {
            failures.append(Failure(exitCode: ExitCodes.survived, message: "--fail-on-survived: \(undetected.count) mutants were not detected"))
        }
        if let failUnder, let score = report.score, score * 100 < failUnder {
            failures.append(Failure(exitCode: ExitCodes.belowThreshold,
                                    message: String(format: "--fail-under: the mutation score is %.1f%%, below %.1f%%", score * 100, failUnder)))
        }
        if let earlier = earlierUndetected {
            let new = undetected.filter { !earlier.contains($0.mutant.key) }
                .filter { result in
                    guard let earlierFiles, !earlierFiles.contains(result.mutant.file) else { return true }
                    return !filesLeftOutThen.contains(result.mutant.file) && !undeterminedFiles.contains(result.mutant.file)
                }
            if !new.isEmpty {
                let list = new.prefix(10).map { "\n    \($0.mutant.file):\($0.mutant.start.line) \($0.mutant.operator.rawValue) \(ReportText.change($0.mutant)) [\($0.mutant.key)]" }.joined()
                failures.append(Failure(exitCode: ExitCodes.newSurvivors,
                                        message: "--baseline-report: \(new.count) mutants are not detected and were not among the undetected mutants of the earlier report:\(list)\(new.count > 10 ? "\n    …" : "")"))
            }
        }
        // When a gate was requested but something could not be examined, do not pass (gaps would be overlooked):
        // mutants without a verdict, declarations whose instrumented form does not compile, files that could not
        // be parsed, --only keys that name nothing
        var unexamined = report.unexamined
        if earlierUndetected != nil, let undeterminedReason, undetected.contains(where: { undeterminedFiles.contains($0.mutant.file) }) { unexamined.append(undeterminedReason) }
        if isRequested, failures.isEmpty, !unexamined.isEmpty {
            failures.append(Failure(exitCode: ExitCodes.incomplete,
                                    message: "the gate cannot be confirmed, because not everything could be examined: " + unexamined.joined(separator: "; ")))
        }
        // Without a gate too, a run in which mutants could not be run does not end with 0: its score is that of
        // the mutants that were judged, and a script that reads only the exit code would take it for a result.
        // (Not so for what --time-limit left out: that limit is a budget the caller set, and a run that keeps to it
        // has done what was asked. Nor for a mutant that does not compile, which is a property of the mutant.)
        if !isRequested, failures.isEmpty, let note = report.notRunNote {
            failures.append(Failure(exitCode: ExitCodes.incomplete, message: "the report is incomplete: " + note))
        }
        return failures
    }

    /// What an earlier JSON report says about its mutants.
    public struct EarlierReport: Sendable, Equatable {
        /// Stable keys of the mutants that were undetected (Survived, NotReached, Accepted).
        public var undetected: Set<String> = []
        /// Stable keys of the mutants whose state that report does not know: not run because the run was interrupted
        /// (`pendingKeys`), or without a verdict (RunnerError, NotActivated). They are not counted as new gaps.
        public var unknown: Set<String> = []
        public var interrupted = false
        /// The files that the earlier run mutated; nil if the report does not say. A mutant in another file is not
        /// known to that report.
        public var files: Set<String>?
        /// The commit the earlier run was made at, if the report says.
        public var commit: String?
    }

    public static func earlierReport(_ data: Data) throws -> EarlierReport {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = json["results"] as? [[String: Any]] else {
            throw GateError.notAReport
        }
        // A report that names no key scheme was not written by this tool in its current form
        guard let keyVersion = json["keyVersion"] as? Int else { throw GateError.notAReport }
        guard keyVersion == MutantKeyScheme.version else {
            throw GateError.keyVersion(found: keyVersion, tool: (json["tool"] as? [String: Any])?["version"] as? String)
        }
        var earlier = EarlierReport()
        earlier.interrupted = json["interrupted"] as? Bool ?? false
        earlier.unknown.formUnion(json["pendingKeys"] as? [String] ?? [])
        // A run of changed lines, or of named mutants, knows nothing about any other mutant: every gap outside it
        // would look new
        if let scope = json["scope"] as? String, scope == "diff" || scope == "only" { throw GateError.partialScope(scope) }
        // A sample: the mutants that were left out are not known (their keys are in the report since 0.13.0)
        if let sampling = json["sampling"] as? [String: Any] {
            guard let omitted = sampling["omittedKeys"] as? [String] else { throw GateError.sampleWithoutKeys }
            earlier.unknown.formUnion(omitted)
        }
        earlier.files = (json["files"] as? [String]).map(Set.init)
        earlier.commit = (json["commit"] as? [String: Any])?["sha"] as? String
        for result in results {
            guard let status = result["status"] as? String, let mutant = result["mutant"] as? [String: Any], let key = mutant["key"] as? String else { continue }
            if status == MutantStatus.survived.rawValue || status == MutantStatus.notReached.rawValue || status == MutantStatus.accepted.rawValue {
                earlier.undetected.insert(key)
            } else if status == MutantStatus.runnerError.rawValue || status == MutantStatus.notActivated.rawValue {
                earlier.unknown.insert(key)
            }
        }
        return earlier
    }

    /// Reads the stable keys of the undetected mutants from an earlier JSON report.
    public static func undetectedKeys(inReport data: Data) throws -> Set<String> {
        try earlierReport(data).undetected
    }

    public enum GateError: Error, CustomStringConvertible {
        case notAReport
        case keyVersion(found: Int, tool: String?)
        case partialScope(String)
        case sampleWithoutKeys

        public var description: String {
            switch self {
            case .notAReport:
                "not a \(ToolInfo.name) JSON report (no `results` array, or no `keyVersion`)"
            case let .partialScope(scope):
                "the report is of a run \(scope == "diff" ? "with --since" : "with --only") (scope `\(scope)`): it holds only the mutants \(scope == "diff" ? "on the lines that had changed then" : "that were named"), so every other undetected mutant would count as new. A baseline has to be a run of whole files (without --since and --only)"
            case .sampleWithoutKeys:
                "the report is of a sample (--max-mutants) and does not list the mutants that were left out, so they would all count as new. Make it again with this version"
            case let .keyVersion(found, tool):
                "the report was written\(tool.map { " by \(ToolInfo.name) \($0)" } ?? "") with stable keys of scheme \(found); this version uses scheme \(MutantKeyScheme.version), and keys of different schemes never match (every undetected mutant would count as new). Make the earlier report again with this version"
            }
        }
    }
}

/// Exit codes of `run`.
public enum ExitCodes {
    /// Completed (if gates were specified, all of them passed)
    public static let success: Int32 = 0
    /// Stopped by an execution infrastructure or tool error (cannot build, static verification failure, canary failure, cannot --resume, etc.)
    public static let infrastructure: Int32 = 2
    /// `--fail-on-survived`: there are undetected mutants
    public static let survived: Int32 = 3
    /// `--fail-under`: the score is below the threshold
    public static let belowThreshold: Int32 = 4
    /// `--baseline-report`: there are undetected mutants that are not in the earlier report
    public static let newSurvivors: Int32 = 5
    /// Tests fail without any mutant, or no test runs at all (fix the project side)
    public static let baselineFailed: Int32 = 6
    /// Not everything could be examined: mutants could not be run (with or without a gate), or a gate was
    /// specified and something else that it needs was not examined
    public static let incomplete: Int32 = 7
    /// Interrupted (Ctrl-C, SIGTERM). The report of the results so far has been written
    public static let interrupted: Int32 = 130
}
