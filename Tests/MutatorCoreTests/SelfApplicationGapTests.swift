import Foundation
@testable import MutatorCore
@testable import MutatorRunner
import Testing

/// The gaps that running the tool on itself found in its own tests (13 items that bear on the
/// correctness of verdicts and 6 minor ones).
/// The numbers in the names are those of that list. Items 8, 13, 14, 15 and 18 are in `StableKeyTests` and `GateTests`.
@Suite struct SelfApplicationGapTests {
    private func summary(failed: Int, total: Int = 3, message: String = "XCTAssertEqual failed") -> TestSummary {
        DefectRegressionTests.summary(failed: failed, total: total, message: message)
    }

    private func observation(exit: Int32, summary: TestSummary?, activated: Bool = true, timedOut: Bool = false, shared: Bool? = nil) -> MutantObservation {
        var observation = MutantObservation(key: "k", id: 1, attempt: 1, exitStatus: exit, timedOut: timedOut, summary: summary, activated: activated,
                                            runnerErrorPattern: nil, durationSeconds: 1, timeoutSeconds: 60)
        observation.sharedProcess = shared
        return observation
    }

    static let baseline = BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0)

    // MARK: Judgement

    /// 1: xcodebuild failed although every test in the result bundle passed. That is not a pass of the mutant.
    @Test func item1_aFailedInvocationWithOnlyPassingTestsIsNotSurvived() {
        let result = Judgement.classify(observation(exit: 65, summary: summary(failed: 0)), baseline: Self.baseline)
        #expect(result.status == .runnerError)
        // Not NotActivated either, when the switch was not recorded
        #expect(Judgement.classify(observation(exit: 65, summary: summary(failed: 0), activated: false), baseline: Self.baseline).status == .runnerError)
    }

    /// 2: exit status 0 but a test failed: the failed test decides.
    @Test func item2_aFailedTestIsKilledWhateverTheExitStatus() {
        let result = Judgement.classify(observation(exit: 0, summary: summary(failed: 1)), baseline: Self.baseline)
        #expect(result.status == .killed)
        #expect(result.killedBy == ["T/test0()"])
    }

    /// 3: an observation from a shared process without a failed test is not Killed.
    @Test func item3_aSharedObservationWithoutFailuresIsNotKilled() {
        #expect(Judgement.classify(observation(exit: 0, summary: summary(failed: 0), shared: true), baseline: Self.baseline).status == .survived)
        #expect(Judgement.classify(observation(exit: 0, summary: summary(failed: 0), activated: false, shared: true), baseline: Self.baseline).status == .notActivated)
    }

    /// 4: an observation from a shared process that timed out is a Timeout, not Killed.
    @Test func item4_aSharedObservationThatTimedOutIsATimeout() {
        #expect(Judgement.classify(observation(exit: 65, summary: summary(failed: 1), timedOut: true, shared: true), baseline: Self.baseline).status == .timeout)
        #expect(Judgement.classify(observation(exit: 65, summary: summary(failed: 1), activated: false, timedOut: true, shared: true), baseline: Self.baseline).status == .runnerError)
    }

    /// 5: the shared branch and the general branch differ: a failure with a crash marker is Crash from a process of
    /// its own, and Killed from a shared process (a crash there ends the process and is decided by a run alone).
    @Test func item5_theSharedBranchDiffersFromTheGeneralOne() {
        let crash = summary(failed: 1, message: "Crash: App at f()")
        let alone = Judgement.classify(observation(exit: 65, summary: crash), baseline: Self.baseline)
        #expect(alone.status == .crash)
        #expect(alone.detail?.contains("Crash: App at f()") == true)
        let shared = Judgement.classify(observation(exit: 65, summary: crash, shared: true), baseline: Self.baseline)
        #expect(shared.status == .killed)
        #expect(shared.detail?.contains("failed in a shared process") == true)
        // `sharedProcess == false` (a survivor confirmed in a new process) takes the general branch
        #expect(Judgement.classify(observation(exit: 65, summary: crash, shared: false), baseline: Self.baseline).status == .crash)
        // A shared observation with another number of tests than the baseline is not judged by the shared branch
        let fewer = Judgement.classify(observation(exit: 65, summary: summary(failed: 1, total: 2), shared: true), baseline: Self.baseline)
        #expect(fewer.status == .runnerError)
        // Without a baseline to compare with, the count is not checked
        #expect(Judgement.classify(observation(exit: 65, summary: summary(failed: 1, total: 2), shared: true), baseline: nil).status == .killed)
    }

    // MARK: DiffFilter

    /// 6: a mutant that spans lines 2 to 4 is in the diff when only line 4 changed.
    @Test func item6_aMutantOverSeveralLinesIsKeptWhenItsLastLineChanged() {
        var mutant = ConfigJournalAndReportTests.mutant(0, line: 2)
        mutant.end = SourcePosition(line: 4, column: 3)
        #expect(DiffFilter.filter([mutant], changedLines: [4...4]).count == 1)
        #expect(DiffFilter.filter([mutant], changedLines: [2...2]).count == 1)
        #expect(DiffFilter.filter([mutant], changedLines: [3...3]).count == 1)
        #expect(DiffFilter.filter([mutant], changedLines: [5...5]).isEmpty)
        #expect(DiffFilter.filter([mutant], changedLines: [1...1]).isEmpty)
        // An end before the start (should not happen) does not turn the span inside out
        mutant.end = SourcePosition(line: 1, column: 1)
        #expect(DiffFilter.filter([mutant], changedLines: [2...2]).count == 1)
    }

    /// 7: only hunk headers give line numbers. An added line whose text looks like one does not.
    @Test func item7_onlyHunkHeadersAreReadAsLineNumbers() {
        let diff = """
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -1,0 +2,3 @@
        +42
        +@@ -7,3 +90,3 @@ x
        ++++ b/Other.swift
        @@ -20 +30,2 @@ func f()
        -old
        +new
        +7,3 x
        """
        #expect(DiffFilter.parseUnifiedDiff(diff) == ["A.swift": [2...4, 30...31]])
    }

    /// 16: a deleted file is not in the result under the name /dev/null; a header that cannot be read is skipped
    /// and the hunks after it still count.
    @Test func item16_deletedFilesAndBrokenHeaders() {
        let diff = """
        --- a/Gone.swift
        +++ /dev/null
        @@ -1,3 +0,0 @@
        -a
        -b
        -c
        --- a/B.swift
        +++ b/B.swift
        @@ garbage
        @@ -4 +5 @@
        -x
        +y
        @@ -9,2 +10,0 @@
        -p
        -q
        """
        // A hunk that only deletes marks the lines around the deletion
        #expect(DiffFilter.parseUnifiedDiff(diff) == ["B.swift": [5...5, 10...11]])
    }

    @Test func quotedPathsAreUnquoted() {
        #expect(DiffFilter.unquote("plain/path.swift") == "plain/path.swift")
        #expect(DiffFilter.unquote(#""b/Sources/\347\224\273\351\235\242/B.swift""#) == "b/Sources/画面/B.swift")
        #expect(DiffFilter.unquote(#""b/a\tb\\c\"d.swift""#) == "b/a\tb\\c\"d.swift")
        let diff = "+++ \"b/Sources/\\347\\224\\273\\351\\235\\242/B.swift\"\n@@ -1 +1 @@\n-a\n+b\n+++ w/Other.swift\t\n@@ -2 +2 @@\n-a\n+b\nBinary files a/Bin.swift and b/Bin.swift differ\n"
        #expect(DiffFilter.parseUnifiedDiff(diff) == ["Sources/画面/B.swift": [1...1], "Other.swift": [2...2], "Bin.swift": [1...Int.max]])
    }

    // MARK: Journal and the resume fingerprint

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let result = try #require(runProcess("/usr/bin/git", ["-C", directory.path, "-c", "user.email=test@example.com", "-c", "user.name=Test",
                                                               "-c", "commit.gpgsign=false"] + arguments))
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output
    }

    /// 9: in a git repository the fingerprint covers HEAD, uncommitted changes and untracked files, and not the paths to ignore.
    @Test func item9_theFingerprintFollowsTheStateOfAGitRepository() throws {
        try withTemporaryDirectory { directory in
            try git(["init", "-q", "."], in: directory)
            let file = directory.appendingPathComponent("A.swift")
            try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)
            try git(["add", "-A"], in: directory)
            try git(["commit", "-q", "-m", "one"], in: directory)
            func fingerprint(ignoring: Set<String> = []) -> String { RunFingerprint.compute(copyRoot: directory, parts: ["p"], ignoring: ignoring) }
            let committed = fingerprint()
            #expect(committed == fingerprint())
            // (b) an uncommitted edit
            try "let a = 2\n".write(to: file, atomically: true, encoding: .utf8)
            let edited = fingerprint()
            #expect(edited != committed)
            // (a) a new commit (the same text, now committed: HEAD is part of the state)
            try git(["commit", "-q", "-am", "two"], in: directory)
            let second = fingerprint()
            #expect(second != edited)
            #expect(second != committed)
            // (c) an untracked file, and its contents
            let untracked = directory.appendingPathComponent("New.swift")
            try "let n = 1\n".write(to: untracked, atomically: true, encoding: .utf8)
            let withNew = fingerprint()
            #expect(withNew != second)
            try "let n = 2\n".write(to: untracked, atomically: true, encoding: .utf8)
            #expect(fingerprint() != withNew)
            // (d) a path to ignore (a report that the tool itself wrote)
            #expect(fingerprint(ignoring: [untracked.standardizedFileURL.path]) == second)
            let report = directory.appendingPathComponent("report.json")
            try "{}".write(to: report, atomically: true, encoding: .utf8)
            #expect(fingerprint(ignoring: [untracked.standardizedFileURL.path, report.standardizedFileURL.path]) == second)
        }
    }

    /// 10 and 11: the parts are kept apart, and the version of the tool is one of them.
    @Test func item10and11_thePartsAreSeparatedAndTheToolVersionCounts() throws {
        try withTemporaryDirectory { directory in
            try "x".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            func fingerprint(_ parts: [String], version: String = "1.0.0") -> String {
                RunFingerprint.compute(copyRoot: directory, parts: parts, toolVersion: version)
            }
            #expect(fingerprint(["ab", "c"]) != fingerprint(["a", "bc"]))
            #expect(fingerprint(["ab", "c"]) != fingerprint(["abc"]))
            #expect(fingerprint(["ab", "c"]) == fingerprint(["ab", "c"]))
            #expect(fingerprint(["p"], version: "1.0.0") != fingerprint(["p"], version: "1.0.1"))
            // The default is the version of this build
            #expect(RunFingerprint.compute(copyRoot: directory, parts: ["p"]) == fingerprint(["p"], version: ToolInfo.version))
        }
    }

    /// 17: outside git the names of the files are part of the state, not only their contents.
    @Test func item17_outsideGitTheFileNamesCount() throws {
        try withTemporaryDirectory { base in
            // No repository above: the temporary directory is not under git
            let one = base.appendingPathComponent("one")
            let other = base.appendingPathComponent("other")
            for (directory, name) in [(one, "A.swift"), (other, "B.swift")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try "same".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            #expect(RunFingerprint.repositoryState(one) != RunFingerprint.repositoryState(other))
            try FileManager.default.moveItem(at: other.appendingPathComponent("B.swift"), to: other.appendingPathComponent("A.swift"))
            #expect(RunFingerprint.repositoryState(one) == RunFingerprint.repositoryState(other))
        }
    }

    /// 12: a damaged line in the middle: what comes before it is kept, the rest is cut off (and reading ends).
    @Test func item12_aDamagedLineInTheMiddleCutsTheJournalThere() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("observations.jsonl")
            let journal = Journal(url: url)
            try journal.start(fingerprint: "f")
            try journal.record(baseline: BaselineEvidence(testCount: 3, passedTests: 3, skippedTests: 0))
            journal.close()
            let good = try Data(contentsOf: url)
            // A damaged line that ends with a line break, and a good line after it
            let later = Journal(url: directory.appendingPathComponent("other.jsonl"))
            try later.start(fingerprint: "g")
            try later.record(compileError: "key", detail: "d")
            later.close()
            let tail = try Data(contentsOf: later.url)
            try (good + Data("{\"observation\": damaged\n".utf8) + tail).write(to: url)

            let reloaded = Journal(url: url)
            #expect(reloaded.load())
            #expect(reloaded.header?.fingerprint == "f")
            #expect(reloaded.baseline?.testCount == 3)
            #expect(reloaded.compileErrors.isEmpty)
            #expect(try Data(contentsOf: url) == good)
            // An empty file and a file without a header are not journals
            try Data().write(to: url)
            #expect(!Journal(url: url).load())
            #expect(!Journal(url: directory.appendingPathComponent("missing.jsonl")).load())
        }
    }

    // MARK: Config

    /// 19: `disabledOperators` of the config file does remove the operator; a name that does not exist is an error.
    @Test func item19_theConfigFileDisablesOperators() throws {
        var config = MutatorConfig()
        config.disabledOperators = ["boundary"]
        let options = try config.generatorOptions(extraArid: [], extraDisabled: ["ternary-swap"], maxSwitches: nil)
        #expect(!options.operators.contains(.boundary))
        #expect(!options.operators.contains(.ternarySwap))
        #expect(options.operators.contains(.equalityFlip))
        config.disabledOperators = ["boundry"]
        #expect(throws: MutatorConfig.ConfigError.self) { try config.generatorOptions(extraArid: [], extraDisabled: [], maxSwitches: nil) }
        config.disabledOperators = nil
        config.enabledOperators = ["arithmetic"]
        #expect(try config.generatorOptions(extraArid: [], extraDisabled: [], maxSwitches: 5).operators.contains(.arithmetic))
        #expect(try config.generatorOptions(extraArid: [], extraDisabled: [], maxSwitches: 5).maxSwitchesPerExpression == 5)
    }
}
