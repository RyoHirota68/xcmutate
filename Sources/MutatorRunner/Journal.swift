import CryptoKit
import Darwin
import Foundation
import MutatorCore

/// What was observed when one mutant was run (not the verdict).
///
/// The journal stores observations and the verdict is recomputed with `Judgement.classify` whenever they are read,
/// so a change to the judging rules applies to results recorded earlier.
public struct MutantObservation: Codable, Sendable, Equatable {
    public var key: String
    public var id: Int
    public var attempt: Int
    public var exitStatus: Int32
    public var timedOut: Bool
    public var summary: TestSummary?
    /// Whether the test process recorded that the switch was evaluated while active.
    public var activated: Bool
    /// A known infrastructure failure message found in the xcodebuild log, if any.
    public var runnerErrorPattern: String?
    public var durationSeconds: Double
    public var timeoutSeconds: Double
    /// True when the observation comes from a process that ran several mutants (`--shared-process`): the counts and
    /// the failing tests were reported by the driver in the test process, not read from a result bundle.
    public var sharedProcess: Bool?
    /// True when the observation comes from a process that the tool started itself with the mutant on from the start
    /// (a survivor of the shared processes confirmed in a new process): the driver reported the counts.
    public var directLaunch: Bool?
    /// With `--select-tests reach`: true when the run was against the whole selection (the mutant had survived its
    /// narrowed tests, or was not narrowed). `--resume` compares such an observation with the whole selection.
    public var wholeSelection: Bool?
    /// The suites the run was narrowed to (nil: the whole selection), and the number of tests that a passing run of
    /// them executes. `--resume` judges the observation against these, not against what a new run would plan: at
    /// the start of a run it is not yet known which mutants a shared process will let be narrowed.
    public var selectedTests: [String]?
    public var expectedTests: Int?
    /// True when the run was stopped because no test had started within the limit for starting the host
    /// (`TimeoutPolicy.watch`). Such a run is repeated once before it counts: a host can be slow to start for
    /// reasons that have nothing to do with the mutant.
    public var stoppedBeforeTests: Bool?
    /// True when the run was stopped because one test did not end within the time that a single test may take.
    /// Repeated once before it counts, like a run that was stopped before its first test.
    public var stoppedInTest: Bool?
    /// Set when the run was stopped because `xcodebuild` said that it restarts the host after an unexpected exit:
    /// the test that had started last (empty if the log does not name one). There is no result bundle for such a
    /// run; with the record that the mutant was active it is a Crash.
    public var crashedIn: String?
    /// For a run that was stopped by a limit: which limit, with its numbers, in words (the detail of a Timeout).
    public var limitNote: String?
    /// With `crashedIn`: true if that test had failed an assertion before the host ended. The mutant is then Killed
    /// (as a result bundle would have had it: the test's failure is the assertion), not a Crash.
    public var failedBeforeCrash: Bool?
    /// Set when a limit stopped the run and a crash report of the host was written during it: the report, and what
    /// it says. The host had crashed and `xcodebuild` had not said so yet (seen once, on a busy machine: a mutant
    /// that calls `fatalError` was a Timeout). With it the run is a crash (`crashedIn` is set too), not a Timeout.
    public var crashEvidence: String?
    /// True when the run was against all selected tests in a process with the tool's driver, stopped at its first
    /// failing test (`--shared-process`, unless `--no-stop-at-first-failure`). The summary then counts the tests that
    /// ran up to that test. The tests run in the order of the driver, which the first run without mutants of every
    /// shared process has shown to pass.
    public var stoppedAtFirstFailure: Bool?

    /// What the run is compared with when the observation is read again; nil if the observation does not say.
    var recordedEvidence: BaselineEvidence? {
        expectedTests.map { BaselineEvidence(testCount: $0, passedTests: $0, skippedTests: 0) }
    }
}

/// What the baseline run (all mutants off) showed. Mutant runs are compared against it.
public struct BaselineEvidence: Codable, Sendable, Equatable {
    public var testCount: Int
    public var passedTests: Int
    public var skippedTests: Int

    public init(testCount: Int, passedTests: Int, skippedTests: Int) {
        self.testCount = testCount
        self.passedTests = passedTests
        self.skippedTests = skippedTests
    }
}

/// One line of the journal (`<work-dir>/journal/observations.jsonl`).
struct JournalLine: Codable {
    struct Header: Codable {
        var tool: String
        var toolVersion: String
        var fingerprint: String
        var startedAt: String
        /// What the fingerprint is made of, part by part (`RunFingerprint.components`), so that a run that cannot be
        /// continued can say which part changed. Absent in a journal written before this was recorded.
        var components: [String: String]?
    }

    struct CompileFailure: Codable {
        var key: String
        var detail: String
    }

    var header: Header?
    var baseline: BaselineEvidence?
    var compileError: CompileFailure?
    var observation: MutantObservation?
    /// Written after the last mutant of a run that was not interrupted.
    var finished: Bool?
}

/// Append-only record of a run, written one mutant at a time so that an interrupted run keeps what it has.
///
/// - Each record is one JSON line, appended and fsync'ed.
/// - On load, a truncated last line (the process died while writing) is cut off; everything before it is kept.
/// - `--resume` continues from the journal only if its fingerprint (tool version, repository state, options and
///   the list of mutants) equals that of the new run.
final class Journal {
    let url: URL
    private var handle: FileHandle?

    /// 2: an observation is written when its run is the mutant's result, not
    /// before the checks that decide that; it names the suites it was narrowed to and their number of tests.
    static let formatVersion = 2

    private(set) var header: JournalLine.Header?
    private(set) var baseline: BaselineEvidence?
    private(set) var compileErrors: [String: String] = [:]
    private(set) var observations: [String: [MutantObservation]] = [:]
    /// The run that wrote the journal judged every mutant (it was not interrupted and did not die).
    private(set) var finished = false

    init(url: URL) {
        self.url = url
    }

    /// Reads an existing journal, cutting off a damaged tail. Returns false if there is no usable journal.
    @discardableResult
    func load() -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        var validEnd = 0
        var offset = 0
        let decoder = JSONDecoder()
        while offset < data.count {
            guard let newline = data[offset...].firstIndex(of: UInt8(ascii: "\n")) else { break }
            guard let line = try? decoder.decode(JournalLine.self, from: data[offset..<newline]) else { break }
            if let h = line.header { header = h }
            if let b = line.baseline { baseline = b }
            if let c = line.compileError { compileErrors[c.key] = c.detail }
            if let o = line.observation { observations[o.key, default: []].append(o) }
            if line.finished == true { finished = true }
            offset = newline + 1
            validEnd = offset
        }
        if validEnd < data.count, let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(validEnd))
            try? handle.close()
        }
        return header != nil
    }

    /// Starts a new journal (discarding an old one).
    func start(fingerprint: String, components: [String: String]? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        header = nil
        baseline = nil
        compileErrors = [:]
        observations = [:]
        finished = false
        let h = JournalLine.Header(tool: ToolInfo.name, toolVersion: ToolInfo.version, fingerprint: fingerprint,
                                   startedAt: ISO8601DateFormatter().string(from: Date()), components: components)
        try append(JournalLine(header: h))
        header = h
    }

    func record(baseline evidence: BaselineEvidence) throws {
        baseline = evidence
        try append(JournalLine(baseline: evidence))
    }

    func record(compileError key: String, detail: String) throws {
        compileErrors[key] = detail
        try append(JournalLine(compileError: .init(key: key, detail: detail)))
    }

    /// Marks the run as complete: every mutant has been judged.
    func recordFinished() throws {
        finished = true
        try append(JournalLine(finished: true))
    }

    func record(_ observation: MutantObservation) throws {
        observations[observation.key, default: []].append(observation)
        try append(JournalLine(observation: observation))
    }

    private func append(_ line: JournalLine) throws {
        if handle == nil {
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(line)
        data.append(UInt8(ascii: "\n"))
        try handle?.write(contentsOf: data)
        if let fd = handle?.fileDescriptor { fsync(fd) }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

/// Identifies "the same run": tool version, state of the repository, options and the list of mutants.
enum RunFingerprint {
    /// - Parameter parts: the options and the mutant list, already turned into text by the caller.
    /// - Parameter ignoring: absolute paths left out of the repository state (the reports this tool writes: an
    ///   interrupted run writes its report, and that must not make `--resume` refuse to continue).
    /// - Parameter toolVersion: the version of the tool (a parameter so that a test can show that it is part of the fingerprint).
    static func compute(copyRoot: URL, parts: [String], ignoring: Set<String> = [], toolVersion: String = ToolInfo.version) -> String {
        var hasher = SHA256()
        func add(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))
        }
        add(toolVersion)
        for part in parts { add(part) }
        add(repositoryState(copyRoot, ignoring: ignoring))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The parts of the fingerprint by name, each as a short hash (the list of mutants and the state of the sources
    /// are long): the options one by one, `mutants`, `sources`, `tool`.
    static func components(copyRoot: URL, parts: [String], ignoring: Set<String> = [], toolVersion: String = ToolInfo.version) -> [String: String] {
        func short(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
        var result = ["tool": toolVersion, "sources": short(repositoryState(copyRoot, ignoring: ignoring))]
        for (index, part) in parts.enumerated() {
            let name = part.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "option \(index)"
            result[result[name] == nil ? name : "\(name) \(index)"] = short(part)
        }
        return result
    }

    /// What differs between the components of the run to be continued and those of this run, in words.
    static func differences(earlier: [String: String]?, now: [String: String]) -> String? {
        guard let earlier else { return nil }
        let names = Set(earlier.keys).union(now.keys).filter { earlier[$0] != now[$0] }.sorted()
        guard !names.isEmpty else { return nil }
        let words: [String: String] = [
            "tool": "the version of the tool", "sources": "the sources (a commit, an uncommitted change or an untracked file in the tree that is copied)",
            "mutants": "the list of mutants (the files or lines selected, --only, --since, the operators, the config file)",
            "xcode": "the project, scheme, destination, test plan or the build and test arguments", "root": "--root", "prepare": "--prepare",
            "timeout": "--timeout-factor or --timeout-constant", "selectTests": "--select-tests", "confirmKills": "--confirm-kills",
            "recheckSurvivors": "--recheck-survivors", "sharedProcess": "--shared-process, --trust-shared-survivors or --no-direct-launch",
            "workers": "--workers or the destinations", "since": "--since", "files": "the files to mutate", "maxRebuilds": "--max-rebuilds", "copyRoot": "--copy-root", "reuse": "--reuse", "journal": "the form of the journal (another version of the tool)",
        ]
        return names.map { words[$0] ?? "the option recorded as \"\($0)\"" }.joined(separator: "; ")
    }

    /// HEAD, the diff against it and the contents of untracked files. Outside git: the contents of every file.
    static func repositoryState(_ root: URL, ignoring: Set<String> = []) -> String {
        func ignored(_ path: Substring) -> Bool {
            ignoring.contains(root.appendingPathComponent(String(path)).standardizedFileURL.path)
        }
        func git(_ arguments: [String]) -> String? {
            guard let result = try? Subprocess.capture(["git", "-C", root.path] + arguments, timeout: 300), result.status == 0 else { return nil }
            return result.output
        }
        var hasher = SHA256()
        if let head = git(["rev-parse", "HEAD"]), let diff = git(["diff", "HEAD", "--no-ext-diff", "--binary"]),
           let untracked = git(["ls-files", "-z", "--others", "--exclude-standard"]) {
            hasher.update(data: Data(head.utf8))
            hasher.update(data: Data(diff.utf8))
            for path in untracked.split(separator: "\0").sorted() where !ignored(path) {
                hasher.update(data: Data(path.utf8))
                if let data = try? Data(contentsOf: root.appendingPathComponent(String(path))) { hasher.update(data: data) }
            }
        } else if let files = try? WorkCopy.listFiles(root: root) {
            for path in files.sorted() where !ignored(Substring(path)) {
                hasher.update(data: Data(path.utf8))
                if let data = try? Data(contentsOf: root.appendingPathComponent(path)) { hasher.update(data: data) }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
